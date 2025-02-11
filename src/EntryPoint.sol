// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {CallContextChecker} from "solady/utils/CallContextChecker.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";

/// @title EntryPoint
/// @notice Contract for ERC7702 delegations.
contract EntryPoint is EIP712, Ownable, CallContextChecker, ReentrancyGuardTransient {
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
    function execute(bytes calldata encodedUserOp)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4 err)
    {
        // This function does NOT allocate memory to avoid quadratic memory expansion costs.
        // Otherwise, it will be unfair to the UserOps at the back of the batch.
        UserOp calldata u;
        assembly ("memory-safe") {
            let t := calldataload(encodedUserOp.offset)
            u := add(t, encodedUserOp.offset)
            // Bounds check. We don't need to explicitly check the fields here.
            // In the self call functions, we will use regular Solidity to access the fields,
            // which generate the implicit bounds checks.
            if or(shr(64, t), lt(encodedUserOp.length, 0x20)) { revert(0x00, 0x00) }
        }
        uint256 g = u.combinedGas;
        uint256 gStart = gasleft();
        uint256 paymentAmount;
        assembly ("memory-safe") {
            // Check if there's sufficient gas left for the gas-limited self calls
            // via the 63/64 rule. This is for gas estimation. If the total amount of gas
            // for the whole transaction is insufficient, revert.
            if or(lt(shr(6, mul(gas(), 63)), add(g, _INNER_GAS_OVERHEAD)), shr(64, g)) {
                mstore(0x00, 0x1c26714c) // `InsufficientGas()`.
                revert(0x1c, 0x04)
            }

            let m := mload(0x40) // Grab the free memory pointer.
            // Copy the encoded user op to the memory to be ready to pass to the self call.
            calldatacopy(add(m, 0x20), encodedUserOp.offset, encodedUserOp.length)
            let s := add(m, 0x1c) // Start of the calldata in memory to pass to the self call.
            let n := add(encodedUserOp.length, 0x24) // Length of the calldata to the self call.

            // To prevent griefing, we need to do two non-reverting gas-limited calls.
            // Even if the verify and call fails, which the gas will be burned,
            // the payment has already been made and can't be reverted.

            // 1. Pay.
            mstore(m, 0x1a3de5c3) // `_pay()`.
            mstore(0x00, 0) // Zeroize the return slot.
            let gCapped := xor(g, mul(xor(g, _PAYMENT_GAS_CAP), lt(_PAYMENT_GAS_CAP, g))) // `min`.
            // Perform the gas-limited self call.
            switch call(gCapped, address(), 0, s, n, 0x00, 0x20)
            case 0 {
                err := mload(0x00)
                if iszero(returndatasize()) { err := shl(224, 0xbff2584f) } // `PaymentError()`.
            }
            default {
                // Since the payment is a success, load the returned `paymentAmount`.
                paymentAmount := mload(0x00)
                let gUsed := sub(gStart, gas())
                let gLeft := mul(sub(g, gUsed), gt(g, gUsed))
                // 2. Verify and call.
                mstore(m, 0xe235a92a) // `_verifyAndCall()`.
                mstore(0x00, 0) // Zeroize the return slot.
                // Perform the gas-limited self call.
                if iszero(call(gLeft, address(), 0, s, n, 0x00, 0x20)) {
                    err := mload(0x00)
                    if iszero(returndatasize()) { err := shl(224, 0xad4db224) } // `VerifiedCallError()`.
                }
            }
        }

        // Refund strategy:
        // `totalAmountOfGasToPayFor = gasUsedThusFar + _REFUND_GAS`.
        // `paymentAmountForGas = paymentPerGas * totalAmountOfGasToPayFor`.
        // If we have overpaid, then refund `paymentAmount - paymentAmountForGas`.

        uint256 gUsed = Math.rawSub(gStart, gasleft());
        uint256 paymentPerGas = u.paymentPerGas;
        if (paymentPerGas == uint256(0)) paymentPerGas = type(uint256).max;
        uint256 finalPaymentAmount = Math.min(
            paymentAmount, Math.saturatingMul(paymentPerGas, Math.saturatingAdd(gUsed, _REFUND_GAS))
        );
        address paymentRecipient = u.paymentRecipient;
        if (paymentRecipient == address(0)) paymentRecipient = address(this);
        if (LibBit.and(finalPaymentAmount != 0, paymentRecipient != address(this))) {
            TokenTransferLib.safeTransfer(u.paymentToken, paymentRecipient, finalPaymentAmount);
        }
        if (paymentAmount > finalPaymentAmount) {
            TokenTransferLib.safeTransfer(
                u.paymentToken,
                u.payer == address(0) ? u.eoa : u.payer,
                Math.rawSub(paymentAmount, finalPaymentAmount)
            );
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
            errs := mload(0x40) // Grab the free memory pointer.
            mstore(errs, encodedUserOps.length) // Store the length.
            mstore(0x40, add(add(0x20, errs), shl(5, encodedUserOps.length))) // Allocate.
        }
        for (uint256 i; i != encodedUserOps.length;) {
            // We reluctantly use regular Solidity to access `encodedUserOps[i]`.
            // This generates an unnecessary check for `i < encodedUserOps.length`, but helps
            // generate all the implicit calldata bound checks on `encodedUserOps[i]`.
            bytes4 err = execute(encodedUserOps[i]);
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
    function _pay(UserOp calldata u) internal virtual returns (uint256 paymentAmount) {
        paymentAmount = u.paymentAmount;
        if (paymentAmount == uint256(0)) return paymentAmount;
        address paymentToken = u.paymentToken;
        uint256 requiredBalanceAfter = Math.saturatingAdd(
            TokenTransferLib.balanceOf(paymentToken, address(this)), paymentAmount
        );
        address eoa = u.eoa;
        address payer = u.payer == address(0) ? eoa : u.payer;
        if (paymentAmount > u.paymentMaxAmount) {
            revert PaymentError();
        }
        assembly ("memory-safe") {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x00, 0x887f7d7c) // `payEntryPoint(address,uint256,address)`.
            mstore(0x20, shr(96, shl(96, paymentToken)))
            mstore(0x40, paymentAmount)
            mstore(0x60, shr(96, shl(96, eoa)))
            pop(call(gas(), payer, 0, 0x1c, 0x64, 0x00, 0x00))
            mstore(0x40, m) // Restore the free memory pointer.
            mstore(0x60, 0) // Restore the zero pointer.
        }
        if (TokenTransferLib.balanceOf(paymentToken, address(this)) < requiredBalanceAfter) {
            revert PaymentError();
        }
    }

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
    /// If the nonce is odd, the digest will be computed without the chain ID and with a zero nonce salt.
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
        f.set(5, u.nonce & 1 > 0 ? 0 : _nonceSalt(u.eoa));
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
        // `_pay()`.
        if (s == 0x1a3de5c3) {
            require(msg.sender == address(this));
            uint256 paymentAmount = _pay(u);
            assembly ("memory-safe") {
                mstore(0x00, paymentAmount)
                return(0x00, 0x20)
            }
        }
        // `_verifyAndCall()`.
        if (s == 0xe235a92a) {
            require(msg.sender == address(this));
            (bool isValid, bytes32 keyHash) = _verify(u);
            if (!isValid) revert VerificationError();
            _execute(u, keyHash);
            return;
        }
        // `_initializeOwner()`.
        if (s == 0xfc90218d) {
            _checkOnlyProxy();
            address newOwner;
            assembly ("memory-safe") {
                newOwner := calldataload(0x04)
            }
            _initializeOwner(newOwner);
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
    // Other Overrides
    ////////////////////////////////////////////////////////////////////////

    /// @dev Prevent reinitialization of owner.
    function _guardInitializeOwner() internal pure virtual override returns (bool) {
        return true;
    }

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
