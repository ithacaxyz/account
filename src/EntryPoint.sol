// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";

import "./Delegation.sol";

/// @title EntryPoint
/// @notice Contract for ERC7702 delegations.
contract EntryPoint is EIP712, UUPSUpgradeable, Ownable, ReentrancyGuardTransient {
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
        /// @dev The account paying the payment token.
        /// If this is `address(0)`, it defaults to the `eoa`.
        address payer;
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
        /// @dev The amount of ERC20 to pay per gas spent. For calculation of refunds.
        /// If this is left at zero, it will be treated as infinity (i.e. no refunds).
        uint256 paymentPerGas;
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

    /// @dev Unable to perform the verification and the call.
    error VerifiedCallError();

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
        "UserOp(bool multichain,address eoa,Call[] calls,uint256 nonce,uint256 nonceSalt,address payer,address paymentToken,uint256 paymentMaxAmount,uint256 paymentPerGas,uint256 combinedGas)Call(address target,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");

    /// @dev For EIP712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    /// @dev For gas estimation.
    uint256 internal constant _INNER_GAS_OVERHEAD = 100000;

    /// @dev Caps the gas stipend for the payment.
    uint256 internal constant _PAYMENT_GAS_CAP = 100000;

    /// @dev The amount of expected gas for refunds.
    uint256 internal constant _REFUND_GAS = 50000;

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
    function execute(UserOp calldata u)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4 err)
    {
        uint256 g = u.combinedGas;
        uint256 gStart = gasleft();
        (bool isValid, bytes32 keyHash) = _verify(u);
        if (!isValid) revert VerificationError();
        _execute(u, keyHash);

        uint256 gasUsed = gStart - gasleft();
        uint256 paymentAmount = (gasUsed + 100_000) * u.paymentPerGas;
        require(paymentAmount <= u.paymentMaxAmount, "fee too high");
        Delegation(payable(u.eoa)).compensate(u.paymentToken, paymentAmount, u.paymentRecipient);
    }

    /// @dev Executes the array of encoded user operations.
    /// Each element in `encodedUserOps` is given by `abi.encode(userOp)`,
    /// where `userOp` is a struct of type `UserOp`.
    function execute(UserOp[] calldata uOps)
        public
        payable
        virtual
        returns (bytes4[] memory errs)
    {
        for (uint256 i; i != uOps.length;) {
            bytes4 err = execute(uOps[i]);
            // Set `errs[i]` without bounds checks.
            assembly ("memory-safe") {
                i := add(i, 1) // Increment `i` here so we don't need `add(errs, 0x20)`.
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
        // We have to do this cuz Solidity does not have a `abi.validateEncoding`.
        // `abi.decode` is very inefficient, allocating and copying memory needlessly.
        // Also, `execute` takes in a `bytes calldata`, so we can't use `abi.decode` here.
        assembly ("memory-safe") {
            fundingToken := calldataload(add(originData.offset, 0x20))
            fundingAmount := calldataload(add(originData.offset, 0x40))
            let s := calldataload(originData.offset)
            let t := add(originData.offset, s)
            encodedUserOp.length := calldataload(t)
            encodedUserOp.offset := add(t, 0x20)
            let e := add(originData.offset, originData.length)
            // Bounds checks.
            if or(
                or(shr(64, or(s, t)), or(lt(originData.length, 0x60), lt(s, 0x60))),
                gt(add(encodedUserOp.length, encodedUserOp.offset), e)
            ) { revert(0x00, 0x00) }
            eoa := calldataload(add(encodedUserOp.offset, calldataload(encodedUserOp.offset)))
        }
        TokenTransferLib.safeTransferFrom(fundingToken, msg.sender, eoa, fundingAmount);
        revert("tmp");
        // return execute(encodedUserOp);
    }

    /// @dev Returns true if the order ID has been filled.
    function orderIdIsFilled(bytes32 orderId) public view virtual returns (bool) {
        if (orderId == bytes32(0)) return false;
        return _getEntryPointStorage().filledOrderIds.get(uint256(orderId));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Calls `unwrapAndValidateSignature` on the `eoa`.
    function _verify(UserOp calldata u)
        internal
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        bytes32 digest = _computeDigest(u);
        bytes calldata sig = u.signature;
        address eoa = u.eoa;
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
    function _execute(UserOp calldata u, bytes32 keyHash) internal virtual {
        // This re-encodes the ERC7579 `executionData` with the optional `opData`.
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            0x0100000000007821000100000000000000000000000000000000000000000000,
            u.executionData,
            abi.encode(u.nonce, keyHash) // `opData`.
        );
        address eoa = u.eoa;
        assembly ("memory-safe") {
            if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x00)) {
                mstore(0x00, 0x6c9d47e8) // `CallError()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Computes the EIP712 digest for the UserOp.
    /// If the nonce is odd, the digest will be computed without the chain ID.
    /// Otherwise, the digest will be computed with the chain ID.
    function _computeDigest(UserOp calldata u) internal view virtual returns (bytes32) {
        bytes32[] calldata pointers = LibERC7579.decodeBatch(u.executionData);
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
        // To avoid stack-too-deep. Faster than a regular Solidity array anyways.
        bytes32[] memory f = EfficientHashLib.malloc(11);
        f.set(0, USER_OP_TYPEHASH);
        f.set(1, u.nonce & 1);
        f.set(2, uint160(u.eoa));
        f.set(3, a.hash());
        f.set(4, u.nonce);
        f.set(5, _nonceSalt(u.eoa));
        f.set(6, uint160(u.payer));
        f.set(7, uint160(u.paymentToken));
        f.set(8, u.paymentMaxAmount);
        f.set(9, u.paymentPerGas);
        f.set(10, u.combinedGas);

        return u.nonce & 1 > 0 ? _hashTypedDataSansChainId(f.hash()) : _hashTypedData(f.hash());
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
        UserOp calldata u;
        assembly ("memory-safe") {
            u := add(0x04, calldataload(0x04))
        }
        uint256 s = uint32(bytes4(msg.sig));
        // `_verifyAndCall()`.
        if (s == 0xe235a92a) {
            require(msg.sender == address(this));
            (bool isValid, bytes32 keyHash) = _verify(u);
            if (!isValid) revert VerificationError();
            _execute(u, keyHash);
            return;
        }
        revert FnSelectorNotRecognized();
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

    ////////////////////////////////////////////////////////////////////////
    // Reentrancy Guard Transient
    ////////////////////////////////////////////////////////////////////////

    /// @dev There won't be chains that have 7702 and without TSTORE.
    function _useTransientReentrancyGuardOnlyOnMainnet()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return false;
    }
}
