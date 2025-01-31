// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";

/// @title EntryPoint
/// @notice Contract for ERC7702 delegations.
contract EntryPoint is EIP712, UUPSUpgradeable, Ownable, ReentrancyGuard {
    using LibERC7579 for bytes32[];
    using EfficientHashLib for bytes32[];
    using LibBitmap for LibBitmap.Bitmap;

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    /// @dev This has the same layout as the ERC7579's execution struct.
    struct Call {
        /// @dev The call target.
        address target;
        /// @dev Amount of native value to send to the target.
        uint256 value;
        /// @dev The calldata bytes.
        bytes data;
    }

    /// @dev A struct to hold the user operation fields.
    /// Since L2s already include calldata compression with savings forwarded to users,
    /// we don't need to be too concerned about calldata overhead.
    struct UserOp {
        /// @dev The user's address.
        address eoa;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is an array of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData;
        /// @dev Per delegated EOA.
        uint256 nonce;
        /// @dev The ERC20 or native token used to pay for gas.
        address paymentToken;
        /// @dev The payment recipient for the ERC20 token.
        /// Excluded from signature. The filler can replace this with their own address.
        /// This enables multiple fillers, allowing for competitive filling, better uptime.
        /// If `address(0)`, the payment will be accrued by the entry point.
        address paymentRecipient;
        /// @dev The amount of the token to pay.
        /// Excluded from signature. This will be required to be less than `paymentMaxAmount`.
        uint256 paymentAmount;
        /// @dev The maximum amount of the token to pay.
        uint256 paymentMaxAmount;
        /// @dev The combined gas limit for payment, verification, and calling the EOA.
        uint256 combinedGas;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Unable to perform the payment.
    error PaymentError();

    /// @dev Unable to verify the user op. The user op may be invalid.
    error VerificationError();

    /// @dev Unable to perform the call.
    error CallError();

    /// @dev The payment, verification, and call has failed. Unable to determine exact reason.
    error CombinedError();

    /// @dev The function selector is not recognized.
    error FnSelectorNotRecognized();

    /// @dev Out of gas to perform the call operation.
    error InsufficientGas();

    /// @dev The order has already been filled.
    error OrderAlreadyFilled();

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant USER_OP_TYPEHASH = keccak256(
        "UserOp(bool multichain,address eoa,Call[] calls,uint256 nonce,uint256 nonceSalt,address paymentToken,uint256 paymentMaxAmount,uint256 combinedGas)Call(address target,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");

    /// @dev For EIP712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    /// @dev For gas estimation.
    uint256 internal constant _INNER_GAS_OVERHEAD = 100000;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Holds the storage.
    struct EntryPointStorage {
        LibBitmap.Bitmap filledOrderIds;
    }

    /// @dev Returns the storage pointer.
    function _getEntryPointStorage() internal pure returns (EntryPointStorage storage $) {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("PORTO_ENTRY_POINT_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Main
    ////////////////////////////////////////////////////////////////////////

    /// @dev Executes a single encoded user operation.
    /// `encodedUserOp` is given by `abi.encode(userOp)`, where `userOp` is a struct of type `UserOp`.
    /// If sufficient gas is provided, returns an error selector that is non-zero
    /// if there is an error during the payment, verification, and call execution.
    function execute(bytes calldata encodedUserOp) public payable virtual returns (bytes4 err) {
        UserOp calldata u;
        assembly ("memory-safe") {
            let t := calldataload(encodedUserOp.offset)
            u := add(t, encodedUserOp.offset)
            if or(shr(64, t), lt(encodedUserOp.length, 0x20)) { revert(0x00, 0x00) }
        }
        uint256 g = u.combinedGas;
        assembly ("memory-safe") {
            // Check if there's sufficient gas left for the gas-limited self call
            // via the 63/64 rule. This is for gas estimation. If the total amount of gas
            // for the whole transaction is insufficient, revert.
            if or(lt(shr(6, mul(gas(), 63)), add(g, _INNER_GAS_OVERHEAD)), shr(64, g)) {
                mstore(0x00, 0x1c26714c) // `InsufficientGas()`.
                revert(0x1c, 0x04)
            }
            let m := mload(0x40) // Grab the free memory pointer.
            mstore(0x00, 0) // Zeroize the return slot.
            // Copy the encoded user op to the memory to be ready to pass to the self call.
            calldatacopy(m, encodedUserOp.offset, encodedUserOp.length)
            // Perform a gas-limited self call and check for success.
            if iszero(call(g, address(), 0, m, encodedUserOp.length, 0x00, 0x20)) {
                err := mload(0x00)
                if iszero(returndatasize()) { err := shl(224, 0xbff2584f) } // `CombinedError()`.
            }
        }
    }

    /// @dev Executes the array of encoded user operations.
    /// Each element in `encodedUserOps` is given by `abi.encode(userOp)`,
    /// where `userOp` is a struct of type `UserOp`.
    function execute(bytes[] calldata encodedUserOps)
        public
        payable
        virtual
        returns (bytes4[] memory errs)
    {
        // Allocate memory for `errs` without zeroizing it.
        assembly ("memory-safe") {
            errs := mload(0x40)
            mstore(errs, encodedUserOps.length)
            mstore(0x40, add(add(0x20, errs), shl(5, encodedUserOps.length)))
        }
        for (uint256 i; i != encodedUserOps.length;) {
            bytes4 err = execute(encodedUserOps[i]);
            // Set `errs[i]` without bounds checks.
            assembly ("memory-safe") {
                i := add(i, 1)
                mstore(add(errs, shl(5, i)), err)
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7683
    ////////////////////////////////////////////////////////////////////////

    /// @dev ERC7683 fill.
    /// If you don't need to ensure that the `orderId` can only be used once,
    /// pass in `bytes32(0)` for the `orderId`. The `originData` will
    /// already include the nonce for the delegated `eoa`.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4)
    {
        if (orderId != bytes32(0)) {
            if (!_getEntryPointStorage().filledOrderIds.toggle(uint256(orderId))) {
                revert OrderAlreadyFilled();
            }
        }
        // `originData` is encoded as:
        // `abi.encode(bytes(encodedUserOp), address(fundingToken), uint256(fundingAmount))`.
        bytes calldata encodedUserOp;
        address fundingToken;
        uint256 fundingAmount;
        address eoa;
        assembly ("memory-safe") {
            fundingToken := calldataload(add(originData.offset, 0x20))
            fundingAmount := calldataload(add(originData.offset, 0x40))
            let s := calldataload(originData.offset)
            let t := add(originData.offset, s)
            encodedUserOp.length := calldataload(t)
            encodedUserOp.offset := add(t, 0x20)
            let e := add(originData.offset, originData.length)
            if or(
                or(shr(64, or(s, t)), or(lt(originData.length, 0x60), lt(s, 0x60))),
                gt(add(encodedUserOp.length, encodedUserOp.offset), e)
            ) { revert(0x00, 0x00) }
            eoa := calldataload(add(encodedUserOp.offset, calldataload(encodedUserOp.offset)))
        }
        TokenTransferLib.safeTransferFrom(fundingToken, msg.sender, eoa, fundingAmount);
        return execute(encodedUserOp);
    }

    /// @dev Returns true if the order ID has been filled.
    function orderIdIsFilled(bytes32 orderId) public view virtual returns (bool) {
        if (orderId == bytes32(0)) return false;
        return _getEntryPointStorage().filledOrderIds.get(uint256(orderId));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    // Self call functions
    // -------------------
    // For these self call functions, we shall use the `fallback`.
    // This is so that they can be hidden from the public api,
    // and for facilitating unit testing via a mock.
    //
    // All write self call functions must be guarded with a
    // `require(msg.sender == address(this))` in the fallback.

    /// @dev Makes the `eoa` perform a payment to the `entryPoint`.
    /// This reverts if the payment is insufficient or fails. Otherwise returns nothing.
    function _pay(UserOp calldata userOp) internal virtual {
        uint256 paymentAmount = userOp.paymentAmount;
        if (paymentAmount == uint256(0)) return; // If no payment is needed, early return.
        address paymentToken = userOp.paymentToken;
        address paymentRecipient = userOp.paymentRecipient;
        if (paymentRecipient == address(0)) paymentRecipient = address(this);
        uint256 requiredBalanceAfter =
            TokenTransferLib.balanceOf(paymentToken, paymentRecipient) + paymentAmount;
        address eoa = userOp.eoa;
        if (paymentAmount > userOp.paymentMaxAmount) {
            revert PaymentError();
        }
        bool success;
        assembly ("memory-safe") {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x00, 0x0fdb506d) // `compensate(address,address,uint256)`.
            mstore(0x20, shr(96, shl(96, paymentToken)))
            mstore(0x40, shr(96, shl(96, paymentRecipient)))
            mstore(0x60, paymentAmount)
            success := and(eq(mload(0x00), 1), call(gas(), eoa, 0, 0x1c, 0x64, 0x00, 0x20))
            mstore(0x40, m) // Restore the free memory pointer.
            mstore(0x60, 0) // Restore the zero pointer.
        }
        uint256 actualBalanceAfter = TokenTransferLib.balanceOf(paymentToken, paymentRecipient);
        if (!LibBit.and(success, actualBalanceAfter >= requiredBalanceAfter)) {
            revert PaymentError();
        }
    }

    /// @dev Calls `unwrapAndValidateSignature` on the `eoa`.
    function _verify(UserOp calldata userOp)
        internal
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        bytes32 digest = _computeDigest(userOp);
        bytes calldata sig = userOp.signature;
        address eoa = userOp.eoa;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x0cef73b4) // `unwrapAndValidateSignature(bytes32,bytes)`.
            mstore(add(m, 0x20), digest)
            mstore(add(m, 0x40), 0x40)
            mstore(add(m, 0x60), sig.length)
            calldatacopy(add(m, 0x80), sig.offset, sig.length)
            isValid := staticcall(gas(), eoa, add(m, 0x1c), add(sig.length, 0x84), 0x00, 0x40)
            isValid := and(eq(mload(0x00), 1), and(gt(returndatasize(), 0x3f), isValid))
            keyHash := mload(0x20)
        }
    }

    /// @dev Sends the `executionData` to the `eoa`.
    /// This bubbles up the revert if any. Otherwise, returns nothing.
    function _execute(UserOp calldata userOp, bytes32 keyHash) internal virtual {
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            0x0100000000007821000100000000000000000000000000000000000000000000,
            userOp.executionData,
            abi.encode(userOp.nonce, keyHash)
        );
        address eoa = userOp.eoa;
        assembly ("memory-safe") {
            if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x00)) {
                mstore(0x00, 0x6c9d47e8) // `CallError()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Computes the EIP712 digest for `userOp`.
    /// If the nonce is odd, the digest will be computed without the chain ID.
    /// Otherwise, the digest will be computed with the chain ID.
    function _computeDigest(UserOp calldata userOp) internal view virtual returns (bytes32) {
        bytes32[] calldata pointers = LibERC7579.decodeBatch(userOp.executionData);
        bytes32[] memory a = EfficientHashLib.malloc(pointers.length);
        unchecked {
            for (uint256 i; i != pointers.length; ++i) {
                (address target, uint256 value, bytes calldata data) = pointers.getExecution(i);
                a.set(
                    i,
                    EfficientHashLib.hash(
                        CALL_TYPEHASH,
                        bytes32(uint256(uint160(target))),
                        bytes32(value),
                        EfficientHashLib.hashCalldata(data)
                    )
                );
            }
        }
        bytes32 structHash = EfficientHashLib.hash(
            uint256(USER_OP_TYPEHASH),
            userOp.nonce & 1,
            uint160(userOp.eoa),
            uint256(a.hash()),
            userOp.nonce,
            _nonceSalt(userOp.eoa),
            uint160(userOp.paymentToken),
            userOp.paymentMaxAmount,
            userOp.combinedGas
        );
        return userOp.nonce & 1 > 0
            ? _hashTypedDataSansChainId(structHash)
            : _hashTypedData(structHash);
    }

    /// @dev Returns the nonce salt on the `eoa`.
    function _nonceSalt(address eoa) internal view virtual returns (uint256 result) {
        assembly ("memory-safe") {
            mstore(0x00, 0x6ae269cc) // `nonceSalt()`.
            if iszero(
                and(gt(returndatasize(), 0x1f), staticcall(gas(), eoa, 0x1c, 0x04, 0x00, 0x20))
            ) { revert(0x00, 0x00) }
            result := mload(0x00)
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Fallback
    ////////////////////////////////////////////////////////////////////////

    receive() external payable virtual {}

    /// @dev Use the fallback function to implement gas limited verification and execution.
    /// Helps avoid unnecessary calldata decoding.
    fallback() external payable virtual {
        if (msg.sig == 0) {
            UserOp calldata userOp;
            assembly ("memory-safe") {
                userOp := calldataload(0x00)
                if iszero(eq(caller(), address())) { revert(0x00, 0x00) }
            }
            _pay(userOp);
            (bool isValid, bytes32 keyHash) = _verify(userOp);
            if (!isValid) revert VerificationError();
            _execute(userOp, keyHash);
        } else {
            revert FnSelectorNotRecognized();
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Only Owner Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows the entry point owner to withdraw tokens.
    /// If `token` is `address(0)`, withdraws the native gas token.
    function withdrawTokens(address token, address recipient, uint256 amount)
        public
        virtual
        onlyOwner
    {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    ////////////////////////////////////////////////////////////////////////
    // EIP712
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "EntryPoint";
        version = "0.0.1";
    }

    ////////////////////////////////////////////////////////////////////////
    // UUPS
    ////////////////////////////////////////////////////////////////////////

    /// @dev For UUPSUpgradeable.
    function _authorizeUpgrade(address) internal view override onlyOwner {}
}
