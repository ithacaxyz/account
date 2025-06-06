// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/// @title IIthacaAccount
/// @notice Interface for the Account contract
interface IIthacaAccount is ICommon {
    /// @dev Pays `paymentAmount` of `paymentToken` to the `paymentRecipient`.
    /// @param keyHash The hash of the key used to authorize the operation
    /// @param encodedIntent The encoded user operation
    /// @param intentDigest The digest of the user operation
    function pay(
        uint256 paymentAmount,
        bytes32 keyHash,
        bytes32 intentDigest,
        bytes calldata encodedIntent
    ) external;

    /// @dev Returns if the signature is valid, along with its `keyHash`.
    /// The `signature` is a wrapped signature, given by
    /// `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
    function unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool isValid, bytes32 keyHash);

    /// @dev Return current nonce with sequence key.
    function getNonce(uint192 seqKey) external view returns (uint256 nonce);

    /// @dev Return the key hash that signed the latest execution context.
    /// @dev Returns bytes32(0) if the EOA key was used.
    function getContextKeyHash() external view returns (bytes32);
}
