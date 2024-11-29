// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {P256} from "solady/utils/P256.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Delegation} from "./Delegation.sol";
import {LibOp} from "./LibOp.sol";

// NOTE: Try to keep this contract as stateless as possible.
contract EntryPoint is EIP712, UUPSUpgradeable, Ownable {
    using LibERC7579 for uint256[];

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    struct CallResult {
        bool success;
        bytes errorData;
        bytes[] results;
    }

    struct UserOp {
        /// @dev The user's address.
        address eoa;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is an array of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData;
        /// @dev Per delegated EOA.
        uint256 nonce;
        /// @dev The ERC20 token used to pay for gas.
        address paymentERC20;
        /// @dev The maximum amount of ERC20 token to pay.
        uint256 paymentMaxAmount;
        /// @dev The amount of ERC20 token to pay.
        uint256 paymentAmount;
        /// @dev The gas limit for the verification.
        uint256 verificationGas;
        /// @dev The gas limit for calling the EOA.
        uint256 callGas;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error UserOpDecodeError();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event LogUserOp(UserOp userOp);
    event LogBytes(bytes value);

    ////////////////////////////////////////////////////////////////////////
    // Main
    ////////////////////////////////////////////////////////////////////////

    /// @dev Executes the array of encoded user operations.
    /// Each element in `encodedUserOps` is given by `abi.encode(userOp)`,
    /// where `userOp` is a struct of type `UserOp`.
    function executeUserOps(bytes[] calldata encodedUserOps) public payable virtual returns (bytes[] memory encodedCallResults) {
        for (uint256 i; i < encodedUserOps.length; ++i) {
            bytes calldata encodedUserOp = _get(encodedUserOps, i);
            UserOp calldata userOp = _decodeUserOp(encodedUserOp);
            emit LogUserOp(userOp);
            emit LogBytes(_userOpSignature(userOp));
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    function _computeDigest() internal view virtual {
        // UserOp calldata userOp = _calldataUserOp();
    }

    function _execute() internal view virtual {
        // UserOp calldata userOp = _calldataUserOp();
    }

    function _selfCall(uint256 gasLimit, uint32 internalSelector, bytes calldata encodedUserOp) internal virtual returns (bool success, bytes memory result) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, internalSelector)
            calldatacopy(add(m, 0x20), encodedUserOp.offset, encodedUserOp.length)
            success := call(gasLimit, address(), 0, add(m, 0x1c), add(0x04, encodedUserOp.length), 0x00, 0x00)
            if returndatasize() {
                result := mload(0x40)
                mstore(result, returndatasize())
                returndatacopy(add(result, 0x20), 0x00, returndatasize())
                mstore(0x40, add(add(result, 0x20), returndatasize()))
            }
        }
    }

    function _userOpExecutionData(UserOp calldata userOp) internal pure virtual returns (bytes calldata result) {
        assembly ("memory-safe") {
            let o := add(userOp, calldataload(add(userOp, 0x20)))
            result.offset := add(o, 0x20)
            result.length := calldataload(o)
        }
    }

    function _userOpSignature(UserOp calldata userOp) internal pure virtual returns (bytes calldata result) {
        assembly ("memory-safe") {
            let o := add(userOp, calldataload(add(userOp, 0x100)))
            result.offset := add(o, 0x20)
            result.length := calldataload(o)
        }
    }

    function _decodeUserOp(bytes calldata encodedUserOp)
        internal
        pure
        virtual
        returns (UserOp calldata userOp)
    {
        assembly ("memory-safe") {
            let end := sub(add(encodedUserOp.offset, encodedUserOp.length), 0x20)
            let o := calldataload(encodedUserOp.offset)
            userOp := add(encodedUserOp.offset, o)
            let p := calldataload(add(userOp, 0x20))
            let i := add(userOp, p)
            let q := calldataload(add(userOp, 0x100))
            let j := add(userOp, q)
            if or(
                shr(64, or(or(o, or(p, q)), or(calldataload(i), calldataload(j)))),
                or(
                    or(gt(add(i, calldataload(i)), end), gt(add(j, calldataload(j)), end)),
                    or(gt(add(userOp, 0x100), end), lt(encodedUserOp.length, 0x20))
                )
            ) {
                mstore(0x00, 0x2b64b01d) // `UserOpDecodeError()`.
                revert(0x1c, 0x04)
            }
        }
    }

    function _calldataUserOp() internal pure virtual returns (UserOp calldata userOp) {
        assembly ("memory-safe") {
            userOp := add(0x04, calldataload(0x04))
        }
    }

    function _get(bytes[] calldata a, uint256 i)
        internal
        pure
        virtual
        returns (bytes calldata result)
    {
        assembly ("memory-safe") {
            let o := add(a.offset, calldataload(add(a.offset, shl(5, i))))
            result.offset := add(o, 0x20)
            result.length := calldataload(o)
        }
    }

    // function _execute(UserOp calldata userOp) internal virtual returns (bool success) {
    //     // TODO: Implement checks for the ERC20 payment.

    //     require(msg.sender == address(this));
    //     bytes32 keyHash = LibOp.wrappedSignatureKeyHash(userOp.signature);

    //     // All these encoding feel expensive. Optimize later if possible.
    //     bytes memory opData = LibOp.encodeOpDataFromEntryPoint(
    //         userOp.nonce, keyHash, userOp.paymentERC20, userOp.paymentAmount
    //     );
    //     bytes memory executionData = abi.encode(userOp.calls, opData);

    //     // TODO: limit the gas to `callGas` here.
    //     try Delegation(payable(userOp.eoa)).execute(bytes1(0x01), executionData) {
    //         success = true;
    //     } catch {
    //         success = false;
    //     }
    // }

    ////////////////////////////////////////////////////////////////////////
    // Fallback
    ////////////////////////////////////////////////////////////////////////

    receive() external payable virtual {}

    /// @dev Use the fallback function to implement gas limited verification and execution.
    /// Helps avoid unnecessary calldata decoding.
    fallback() external payable virtual {
        uint256 s = uint32(bytes4(msg.sig));
        if (s == uint32(bytes4(keccak256("_computeDigest()")))) {}
        if (s == uint32(bytes4(keccak256("_execute()")))) {}
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
