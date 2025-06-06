// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Interface that MUST be implemented by all contracts, that want to verify signatures
/// using the `External` keytype in a IthacaAccount account.
interface ISigner {
    /// @dev MUST return the magic value `0x8afc93b4` if the signature is valid.
    function isValidSignatureWithKeyHash(bytes32 digest, bytes32 keyHash, bytes memory signature)
        external
        view
        returns (bytes4 magicValue);
}
