// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/// @title IDelegation
/// @notice Interface for the Delegation contract
interface IDelegation is ICommon {
    /// @dev Pays `paymentAmount` of `paymentToken` to the `paymentRecipient`.
    /// @param keyHash The hash of the key used to authorize the operation
    /// @param userOp The user operation data
    function pay(uint256 paymentAmount, bytes32 keyHash, UserOp calldata userOp) external;

    /// @dev Returns if the signature is valid, along with its `keyHash`.
    /// The `signature` is a wrapped signature, given by
    /// `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
    function unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool isValid, bytes32 keyHash);

    /// @dev Initializes the PREP.
    /// @param initData The initialization data
    function initializePREP(bytes calldata initData) external returns (bool);
}
