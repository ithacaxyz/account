// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";

/// @title EntryPoint
/// @notice Contract for ERC7702 delegations.
contract EntryPoint is EIP712, UUPSUpgradeable, Ownable, ReentrancyGuard {
    using LibERC7579 for bytes32[];
    using EfficientHashLib for bytes32[];
    using LibBitmap for LibBitmap.Bitmap;

    ////////////////////////////////////////////////////////////////////////
    // Enumerations
    ////////////////////////////////////////////////////////////////////////

    enum UserOpStatus {
        Success,
        CallFailure,
        VerificationFailure,
        PaymentFailure
    }

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
        /// @dev The amount of the token to pay.
        uint256 paymentAmount;
        /// @dev The maximum amount of the token to pay.
        uint256 paymentMaxAmount;
        /// @dev The gas limit for the payment.
        uint256 paymentGas;
        /// @dev The gas limit for the verification.
        uint256 verificationGas;
        /// @dev The gas limit for calling the EOA.
        uint256 callGas;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Position of payment amount in the `userOp` struct.
    uint256 internal constant _USER_OP_PAYMENT_AMOUNT_POS = 0x80;

    /// @dev Position of payment max amount in the `userOp` struct.
    uint256 internal constant _USER_OP_PAYMENT_MAX_AMOUNT_POS = 0xa0;

    /// @dev Position of payment gas in the `userOp` struct.
    uint256 internal constant _USER_OP_PAYMENT_GAS_POS = 0xc0;

    /// @dev Position of verification gas in the `userOp` struct.
    uint256 internal constant _USER_OP_VERIFICATION_GAS_POS = 0xe0;

    /// @dev Position of call gas in the `userOp` struct.
    uint256 internal constant _USER_OP_CALL_GAS_POS = 0x100;

    /// @dev Position of the execution data bytes in the `userOp` struct.
    uint256 internal constant _USER_OP_EXECUTION_DATA_POS = 0x20;

    /// @dev Position of the signature bytes in the `userOp` struct.
    uint256 internal constant _USER_OP_SIGNATURE_POS = 0x120;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev The encoded user op is improperly encoded.
    error UserOpDecodeError();

    /// @dev Insufficient payment or failed to pay the entry point.
    error EntryPointPaymentFailed();

    /// @dev The function selector is not recognized.
    error FnSelectorNotRecognized();

    /// @dev Only the entry point itself can make a self-call.
    error SelfCallUnauthorized();

    /// @dev Out of gas to perform the call operation.
    error InsufficientGas();

    /// @dev The order has already been filled.
    error OrderAlreadyFilled();

    /// @dev The origin data is improperly encoded.
    error OriginDataDecodeError();

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant USER_OP_TYPEHASH = keccak256(
        "UserOp(address eoa,Call[] calls,uint256 nonce,uint256 nonceSalt,address paymentToken,uint256 paymentMaxAmount,uint256 paymentGas,uint256 verificationGas,uint256 callGas)Call(address target,uint256 value,bytes data)"
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

    /// @dev Executes the array of encoded user operations.
    /// Each element in `encodedUserOps` is given by `abi.encode(userOp)`,
    /// where `userOp` is a struct of type `UserOp`.
    function execute(bytes[] calldata encodedUserOps)
        public
        payable
        virtual
        returns (UserOpStatus[] memory statuses)
    {
        assembly ("memory-safe") {
            statuses := mload(0x40)
            mstore(statuses, encodedUserOps.length) // Store length of `statuses`.
            mstore(0x40, add(add(0x20, statuses), shl(5, encodedUserOps.length))) // Allocate memory.
            calldatacopy(add(0x20, statuses), calldatasize(), shl(5, encodedUserOps.length)) // Zeroize memory.

            for { let i := 0 } iszero(eq(i, encodedUserOps.length)) { i := add(i, 1) } {
                let m := mload(0x40) // The free memory pointer.
                let u // Pointer to the `userOp` in calldata.
                let s := add(m, 0x1c) // Start of the calldata in memory to pass to the self call.
                let n // Length of the calldata in memory to pass to the self call.

                // This chunk of code prepares the variables and also
                // carefully verifies that `encodedUserOps` has been properly encoded,
                // such that no nested dynamic types (i.e. UserOp, bytes) are out of bounds.
                {
                    let t :=
                        add(encodedUserOps.offset, calldataload(add(encodedUserOps.offset, shl(5, i))))
                    let o := add(t, 0x20) // Offset of `encodedUserOps[i]`.
                    let l := calldataload(t) // Length of `encodedUserOps[i]`.
                    n := add(0x44, l)
                    // Copy the encoded user op to the memory to be ready to pass to the self call.
                    calldatacopy(add(m, 0x40), o, l)
                    let w := sub(add(o, l), 0x20) // Last word offset of the `encodedUserOps[i]`.
                    let a := calldataload(o)
                    u := add(o, a)
                    let b := calldataload(add(u, _USER_OP_EXECUTION_DATA_POS)) // Offset of `executionData`.
                    let y := add(u, b)
                    let c := calldataload(add(u, _USER_OP_SIGNATURE_POS)) // Offset of `signature`.
                    let z := add(u, c)
                    if or(
                        shr(64, or(or(a, or(b, c)), or(calldataload(y), calldataload(z)))),
                        or(
                            or(gt(add(y, calldataload(y)), w), gt(add(z, calldataload(z)), w)),
                            or(gt(add(u, 0x100), w), lt(l, 0x20))
                        )
                    ) {
                        mstore(0x00, 0x2b64b01d) // `UserOpDecodeError()`.
                        revert(0x1c, 0x04)
                    }
                }

                for {} 1 {} {
                    mstore(m, 0xcc1d5274) // `_payEntryPoint()`.
                    mstore(0x00, 0) // Zeroize the return slot.
                    if gt(
                        calldataload(add(u, _USER_OP_PAYMENT_AMOUNT_POS)),
                        calldataload(add(u, _USER_OP_PAYMENT_MAX_AMOUNT_POS))
                    ) {
                        mstore(add(add(0x20, statuses), shl(5, i)), 3) // `PaymentFailure`.
                        break
                    }
                    let g := calldataload(add(u, _USER_OP_PAYMENT_GAS_POS)) // `paymentGas`.
                    // This returns `(bool success)`.
                    if iszero(and(eq(1, mload(0x00)), call(g, address(), 0, s, n, 0x00, 0x20))) {
                        mstore(add(add(0x20, statuses), shl(5, i)), 3) // `PaymentFailure`.
                        break
                    }
                    mstore(m, 0xbaf2bed9) // `_verify()`.
                    mstore(0x00, 0) // Zeroize the return slot.
                    g := calldataload(add(u, _USER_OP_VERIFICATION_GAS_POS)) // `verificationGas`.
                    // This returns `(bool isValid, bytes32 keyHash)`.
                    if iszero(and(eq(1, mload(0x00)), call(g, address(), 0, s, n, 0x00, 0x40))) {
                        mstore(add(add(0x20, statuses), shl(5, i)), 2) // `VerificationFailure`.
                        break
                    }
                    mstore(m, 0x420aadb8) // `_execute()`.
                    mstore(add(m, 0x20), mload(0x20)) // Copy the `keyHash` over.
                    mstore(0x00, 0) // Zeroize the return slot.
                    g := calldataload(add(u, _USER_OP_CALL_GAS_POS)) // `callGas`.
                    // Check if there's sufficient gas to be forwarded to the eoa.
                    if or(lt(shr(6, mul(gas(), 63)), add(g, _INNER_GAS_OVERHEAD)), shr(64, g)) {
                        mstore(0x00, 0x1c26714c) // `InsufficientGas()`.
                        revert(0x1c, 0x04)
                    }
                    // This returns `(bool success)`.
                    if iszero(and(eq(1, mload(0x00)), call(g, address(), 0, s, n, 0x00, 0x20))) {
                        mstore(add(add(0x20, statuses), shl(5, i)), 1) // `CallFailure`.
                        break
                    }
                    break
                }
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
        returns (UserOpStatus)
    {
        if (orderId != bytes32(0)) {
            if (!_getEntryPointStorage().filledOrderIds.toggle(uint256(orderId))) {
                revert OrderAlreadyFilled();
            }
        }

        // `originData` is encoded as:
        // `abi.encode(bytes(encodedUserOp), address(fundingToken), uint256(fundingAmount))`.
        bytes[] calldata encodedUserOps;
        address fundingToken;
        uint256 fundingAmount;
        address eoa;
        assembly ("memory-safe") {
            fundingToken := calldataload(add(originData.offset, 0x20))
            fundingAmount := calldataload(add(originData.offset, 0x40))
            let s := calldataload(originData.offset) // Parent offset of `encodedUserOp`.
            let t := add(originData.offset, s) // `encodedUserOp`.
            let l := calldataload(t) // Length of `encodedUserOp`.
            let o := add(t, 0x20) // Offset of `encodedUserOp`.
            if or(
                or(shr(64, or(s, t)), or(lt(originData.length, 0x60), lt(s, 0x60))),
                gt(add(l, o), add(originData.offset, originData.length))
            ) {
                mstore(0x00, 0x2b3592ae) // `OriginDataDecodeError()`.
                revert(0x1c, 0x04)
            }
            encodedUserOps.length := 1
            encodedUserOps.offset := originData.offset
            eoa := calldataload(add(o, calldataload(o)))
        }
        TokenTransferLib.safeTransferFrom(fundingToken, msg.sender, eoa, fundingAmount);
        return execute(encodedUserOps)[0];
    }

    /// @dev Returns true if the order ID has been filled.
    function orderIdIsFilled(bytes32 orderId) public view virtual returns (bool) {
        if (orderId == bytes32(0)) return false;
        return _getEntryPointStorage().filledOrderIds.get(uint256(orderId));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the `executionData` in `userOp`, without a bounds check.
    /// We don't need the bounds check as it has already been done in `execute`.
    function _userOpExecutionData(UserOp calldata userOp)
        internal
        pure
        virtual
        returns (bytes calldata result)
    {
        assembly ("memory-safe") {
            let o := add(userOp, calldataload(add(userOp, 0x20)))
            result.offset := add(o, 0x20)
            result.length := calldataload(o)
        }
    }

    /// @dev Returns the `signature` in `userOp`, without a bounds check.
    /// We don't need the bounds check as it has already been done in `execute`.
    function _userOpSignature(UserOp calldata userOp)
        internal
        pure
        virtual
        returns (bytes calldata result)
    {
        assembly ("memory-safe") {
            let o := add(userOp, calldataload(add(userOp, _USER_OP_SIGNATURE_POS)))
            result.offset := add(o, 0x20)
            result.length := calldataload(o)
        }
    }

    /// @dev Returns the `userOp` struct in calldata passed into a self call.
    function _calldataUserOp() internal pure virtual returns (UserOp calldata result) {
        assembly ("memory-safe") {
            result := add(0x24, calldataload(0x24))
        }
    }

    /// @dev Returns the `keyHash` in calldata passed into a self call.
    function _calldataKeyHash() internal pure virtual returns (bytes32 result) {
        assembly ("memory-safe") {
            result := calldataload(0x04)
        }
    }

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
    function _payEntryPoint(UserOp calldata userOp) internal virtual {
        uint256 paymentAmount = userOp.paymentAmount;
        address paymentToken = userOp.paymentToken;
        uint256 requiredBalanceAfter =
            TokenTransferLib.balanceOf(paymentToken, address(this)) + paymentAmount;
        address eoa = userOp.eoa;
        assembly ("memory-safe") {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x00, 0x9c42fb59) // `payEntryPoint(address,uint256)`.
            mstore(0x20, shr(96, shl(96, paymentToken)))
            mstore(0x40, paymentAmount)
            if iszero(and(eq(mload(0x00), 1), call(gas(), eoa, 0, 0x1c, 0x44, 0x00, 0x20))) {
                mstore(0x00, 0x2708dbcf) // `EntryPointPaymentFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x40, m) // Restore the free memory pointer.
        }
        if (requiredBalanceAfter > TokenTransferLib.balanceOf(paymentToken, address(this))) {
            revert EntryPointPaymentFailed();
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
        bytes calldata sig = _userOpSignature(userOp);
        address eoa = userOp.eoa;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x0cef73b4) // `unwrapAndValidateSignature(bytes32,bytes)`.
            mstore(add(m, 0x20), digest)
            mstore(add(m, 0x40), 0x40)
            mstore(add(m, 0x60), sig.length)
            calldatacopy(add(m, 0x80), sig.offset, sig.length)
            let n := add(sig.length, 0x84)
            if iszero(
                and(gt(returndatasize(), 0x3f), staticcall(gas(), eoa, add(m, 0x1c), n, 0x00, 0x40))
            ) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            isValid := iszero(iszero(mload(0x00)))
            keyHash := mload(0x20)
        }
    }

    /// @dev Sends the `executionData` to the `eoa`.
    /// This bubbles up the revert if any. Otherwise, returns nothing.
    function _execute(UserOp calldata userOp, bytes32 keyHash) internal virtual {
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            0x0100000000007821000100000000000000000000000000000000000000000000,
            _userOpExecutionData(userOp),
            abi.encode(userOp.nonce, keyHash)
        );
        address eoa = userOp.eoa;
        assembly ("memory-safe") {
            if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x00)) {
                returndatacopy(data, 0x00, returndatasize())
                revert(data, returndatasize())
            }
        }
    }

    /// @dev Computes the EIP712 digest for `userOp`.
    function _computeDigest(UserOp calldata userOp) internal view virtual returns (bytes32) {
        bytes32[] calldata pointers = LibERC7579.decodeBatch(_userOpExecutionData(userOp));
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
        return _hashTypedData(
            EfficientHashLib.hash(
                uint256(USER_OP_TYPEHASH),
                uint160(userOp.eoa),
                uint256(a.hash()),
                userOp.nonce,
                _nonceSalt(userOp.eoa),
                uint160(userOp.paymentToken),
                userOp.paymentMaxAmount,
                userOp.paymentGas,
                userOp.verificationGas,
                userOp.callGas
            )
        );
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
        uint256 s = uint32(bytes4(msg.sig));
        // `_payEntryPoint()`.
        if (s == 0xcc1d5274) {
            require(msg.sender == address(this));
            _payEntryPoint(_calldataUserOp());
            assembly ("memory-safe") {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
        }
        // `_verify()`.
        if (s == 0xbaf2bed9) {
            require(msg.sender == address(this));
            (bool isValid, bytes32 keyHash) = _verify(_calldataUserOp());
            assembly ("memory-safe") {
                mstore(0x00, iszero(iszero(isValid)))
                mstore(0x20, keyHash)
                return(0x00, 0x40)
            }
        }
        // `_execute()`.
        if (s == 0x420aadb8) {
            require(msg.sender == address(this));
            _execute(_calldataUserOp(), _calldataKeyHash());
            assembly ("memory-safe") {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
        }
        // `_computeDigest()`.
        if (s == 0x693e53c3) {
            bytes32 digest = _computeDigest(_calldataUserOp());
            assembly ("memory-safe") {
                mstore(0x00, digest)
                return(0x00, 0x20)
            }
        }
        revert FnSelectorNotRecognized();
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
