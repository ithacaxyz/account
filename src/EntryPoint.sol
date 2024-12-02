// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {P256} from "solady/utils/P256.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {Delegation} from "./Delegation.sol";
import {LibOps} from "./LibOps.sol";

/// @title EntryPoint
/// @notice Contract for ERC7702 delegations.
contract EntryPoint is EIP712, UUPSUpgradeable, Ownable {
    using LibERC7579 for bytes32[];
    using EfficientHashLib for bytes32[];

    ////////////////////////////////////////////////////////////////////////
    // Enumerations
    ////////////////////////////////////////////////////////////////////////

    enum UserOpStatus {
        CallSuccess,
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
        address eoa; // 0x00.
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is an array of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData; // 0x20.
        /// @dev Per delegated EOA.
        uint256 nonce; // 0x40.
        /// @dev The ERC20 or native token used to pay for gas.
        address paymentToken; // 0x60.
        /// @dev The amount of the token to pay.
        uint256 paymentAmount; // 0x80.
        /// @dev The maximum amount of the token to pay.
        uint256 paymentMaxAmount; // 0xa0.
        /// @dev The gas limit for the payment.
        uint256 paymentGas; // 0xc0.
        /// @dev The gas limit for the verification.
        uint256 verificationGas; // 0xe0.
        /// @dev The gas limit for calling the EOA.
        uint256 callGas; // 0x100.
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature; // 0x120.
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error UserOpDecodeError();

    error EntryPointPaymentFailed();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event LogUserOp(UserOp userOp);
    event LogBytes(bytes value);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP-712 signature digest calculation for the `execute` function.
    bytes32 public constant USER_OP_TYPEHASH = keccak256(
        "UserOp(address eoa,Call[] calls,uint256 nonce,uint256 nonceSalt,address paymentToken,uint256 paymentMaxAmount,uint256 paymentGas,uint256 verificationGas,uint256 callGas)Call(address target,uint256 value,bytes data)"
    );

    /// @dev For EIP-712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");

    /// @dev For EIP-712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

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
            mstore(statuses, encodedUserOps.length)
            mstore(0x40, add(add(0x20, statuses), shl(5, encodedUserOps.length)))

            for { let i := 0 } lt(i, encodedUserOps.length) { i := add(i, 1) } {
                let userOp := 0
                let u :=
                    add(encodedUserOps.offset, calldataload(add(encodedUserOps.offset, shl(5, i))))
                let eOffset := add(u, 0x20)
                let eLength := calldataload(u)
                calldatacopy(add(mload(0x40), 0x40), eOffset, eLength)
                // This chunk of code carefully verifies that `encodedUserOps`
                // has been properly encoded.
                {
                    let end := sub(add(eOffset, eLength), 0x20)
                    let o := calldataload(eOffset)
                    userOp := add(eOffset, o)
                    let p := calldataload(add(userOp, 0x20)) // Position of `executionData`.
                    let y := add(userOp, p)
                    let q := calldataload(add(userOp, 0x100)) // Position of `signature`.
                    let z := add(userOp, q)
                    if or(
                        shr(64, or(or(o, or(p, q)), or(calldataload(y), calldataload(z)))),
                        or(
                            or(gt(add(y, calldataload(y)), end), gt(add(z, calldataload(z)), end)),
                            or(gt(add(userOp, 0x100), end), lt(eLength, 0x20))
                        )
                    ) {
                        mstore(0x00, 0x2b64b01d) // `UserOpDecodeError()`.
                        revert(0x1c, 0x04)
                    }
                }
                let m := mload(0x40) // Grab the free memory pointer.

                for { let n := add(0x44, eLength) } 1 {} {
                    let s := add(m, 0x1c)
                    let o := add(add(0x20, statuses), shl(5, i))
                    mstore(m, 0xcc1d5274) // `_payEntryPoint()`.
                    mstore(0x00, 0)
                    if iszero(
                        and(
                            eq(1, mload(0x00)),
                            call(add(userOp, 0xc0), address(), 0, s, n, 0x00, 0x20) // `paymentGas`.
                        )
                    ) {
                        mstore(o, 3) // `PaymentFailure`.
                        break
                    }
                    mstore(m, 0xbaf2bed9) // `_verify()`.
                    mstore(0x00, 0)
                    if iszero(
                        and(
                            eq(1, mload(0x00)),
                            call(add(userOp, 0xe0), address(), 0, s, n, 0x00, 0x40) // `verificationGas`.
                        )
                    ) {
                        mstore(o, 2) // `VerificationFailure`.
                        break
                    }
                    mstore(m, 0x420aadb8) // `_execute()`.
                    mstore(add(m, 0x20), mload(0x20))
                    mstore(0x00, 0)
                    if iszero(
                        and(
                            eq(1, mload(0x00)),
                            call(add(userOp, 0x100), address(), 0, s, n, 0x00, 0x20) // `callGas`.
                        )
                    ) {
                        mstore(o, 1) // `CallFailure`.
                        break
                    }
                    mstore(o, 0) // `CallSuccess`.
                    break
                }
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

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

    function _userOpSignature(UserOp calldata userOp)
        internal
        pure
        virtual
        returns (bytes calldata result)
    {
        assembly ("memory-safe") {
            let o := add(userOp, calldataload(add(userOp, 0x100)))
            result.offset := add(o, 0x20)
            result.length := calldataload(o)
        }
    }

    function _calldataUserOp() internal pure virtual returns (UserOp calldata result) {
        assembly ("memory-safe") {
            result := add(0x24, calldataload(0x24))
        }
    }

    function _calldataKeyHash() internal pure virtual returns (bytes32 result) {
        assembly ("memory-safe") {
            result := calldataload(0x04)
        }
    }

    function _payEntryPoint(UserOp calldata userOp) internal virtual {
        address paymentToken = userOp.paymentToken;
        uint256 paymentAmount = userOp.paymentAmount;
        uint256 requiredBalanceAfter = LibOps.balanceOf(paymentToken, address(this)) + paymentAmount;
        address eoa = userOp.eoa;
        assembly ("memory-safe") {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x00, 0x9c42fb59) // `payEntryPoint(address,uint256)`.
            mstore(0x20, shr(96, shl(96, paymentToken)))
            mstore(0x40, paymentAmount)
            if iszero(
                and(
                    and(eq(0x20, returndatasize()), eq(1, mload(0x00))),
                    call(gas(), eoa, 0, 0x1c, 0x44, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0x2708dbcf) // `EntryPointPaymentFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x40, m) // Restore the free memory pointer.
        }
        uint256 balanceAfter = LibOps.balanceOf(paymentToken, address(this));
        // Of course, we cannot let the transaction pass if
        if (requiredBalanceAfter > balanceAfter) revert EntryPointPaymentFailed();
    }

    function _verify(UserOp calldata userOp) internal view virtual returns (bool isValid, bytes32 keyHash) {
        // bytes32 digest = _computeDigest(userOp);
        // if (LibBit.or(signature.length == 64, signature.length == 65)) {
        //     return ECDSA.recoverCalldata(digest, signature) == userOp.eoa;
        // }

        // bytes32 keyHash = LibOps.wrappedSignatureKeyHash(userOpSignature(userOp));
        // Delegation.Key memory key = Delegation(payable(userOp.eoa)).getKey(keyHash);


    }

    function _execute(UserOp calldata userOp, bytes32 keyHash) internal virtual {
        bytes memory opData = LibOps.encodeOpDataFromEntryPoint(userOp.nonce, keyHash);
        bytes memory executionData = LibERC7579.reencodeBatch(_userOpExecutionData(userOp), opData);
        address eoa = userOp.eoa;
        bool success;
        bytes memory results;
        assembly ("memory-safe") {
            let mode := 0x0100000000007821000100000000000000000000000000000000000000000000
            let n := mload(executionData)
            mstore(sub(executionData, 0x60), 0xe9ae5c53) // `execute(bytes32,bytes)`.
            mstore(sub(executionData, 0x40), mode)
            mstore(sub(executionData, 0x20), 0x40)
            if iszero(call(gas(), eoa, 0, sub(executionData, 0x9c), add(n, 0x84), 0x00, 0x00)) {
                returndatacopy(mload(0x40), 0x00, returndatasize())
                revert(mload(0x40), returndatasize())
            }
        }
    }

    function _computeDigest(UserOp calldata userOp) internal view virtual returns (bytes32) {
        bytes32[] calldata pointers = LibERC7579.decodeBatchUnchecked(_userOpExecutionData(userOp));
        bytes32[] memory a = EfficientHashLib.malloc(pointers.length);
        for (uint256 i; i < pointers.length; ++i) {
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
        bytes32[] memory buffer = EfficientHashLib.malloc(10);
        buffer.set(0, USER_OP_TYPEHASH);
        buffer.set(1, uint160(userOp.eoa));
        buffer.set(2, a.hash());
        buffer.set(3, userOp.nonce);
        buffer.set(4, Delegation(payable(userOp.eoa)).nonceSalt());
        buffer.set(5, uint160(userOp.paymentToken));
        buffer.set(6, userOp.paymentMaxAmount);
        buffer.set(7, userOp.paymentGas);
        buffer.set(8, userOp.verificationGas);
        buffer.set(9, userOp.callGas);
        return _hashTypedData(buffer.hash());
    }

    function _return(uint256 value) internal pure virtual {
        assembly ("memory-safe") {
            mstore(0x00, value)
            return(0x00, 0x20)
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
                mstore(0x00, isValid)
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
        if (s == 0x01010101) {
            emit LogUserOp(_calldataUserOp());
            assembly ("memory-safe") {
                mstore(0x00, 1)
                return(0x00, 0x20)
            }
        }
        revert();
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
