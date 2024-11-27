// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

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
    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    struct UserOp {
        /// @dev The user's address.
        address eoa;
        /// @dev An array of calls to be executed.
        Delegation.Call[] calls;
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
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    function _computeDigest(UserOp calldata userOp) internal virtual view returns (bytes32 digest) {
        // TODO: Fix this.
        return _hashTypedData(
            keccak256(
                abi.encode(
                    keccak256("UserOp(address eoa,Call[] calls,uint256 nonce,address paymentERC20,uint256 paymentMaxAmount,uint256 paymentAmount,uint256 verificationGas,uint256 callGas)"),
                    userOp.eoa,
                    userOp.calls,
                    userOp.nonce,
                    userOp.paymentERC20,
                    userOp.paymentMaxAmount,
                    userOp.paymentAmount,
                    userOp.verificationGas,
                    userOp.callGas
                )
            )
        );
    }

    function _execute(UserOp calldata userOp) internal virtual returns (bool success) {
        // TODO: Implement checks for the ERC20 payment.

        require(msg.sender == address(this));
        bytes32 keyHash = LibOp.wrappedSignatureKeyHash(userOp.signature);

        // All these encoding feel expensive. Optimize later if possible.
        bytes memory opData = LibOp.encodeOpDataFromEntryPoint(
            userOp.nonce, keyHash, userOp.paymentERC20, userOp.paymentAmount
        );
        bytes memory executionData = abi.encode(userOp.calls, opData);

        // TODO: limit the gas to `callGas` here.
        try Delegation(payable(userOp.eoa)).execute(bytes1(0x01), executionData) {
            success = true;
        } catch {
            success = false;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Fallback
    ////////////////////////////////////////////////////////////////////////

    receive() external payable virtual {}

    /// @dev Use the fallback function to implement gas limited verification and execution.
    /// Helps avoid unnecessary calldata decoding.
    fallback() external payable virtual {
        
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
