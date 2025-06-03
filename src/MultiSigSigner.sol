// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IIthacaAccount} from "./interfaces/IIthacaAccount.sol";
import {ISigner} from "./interfaces/ISigner.sol";

/// @notice A Signer contract, that extends multi-sig functionality to the Porto Account.
contract MultiSigSigner is ISigner {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The magic value returned by `isValidSignatureWithKeyHash` when the signature is valid.
    /// - Calcualated as: bytes4(keccak256("isValidSignatureWithKeyHash(bytes32,bytes32,bytes)")
    bytes4 internal constant _MAGIC_VALUE = 0x8afc93b4;

    /// @dev The magic value returned by `isValidSignatureWithKeyHash` when the signature is invalid.
    bytes4 internal constant _FAIL_VALUE = 0xffffffff;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev The threshold can't be zero.
    error InvalidThreshold();

    /// @dev The owner key hash was not found in the config.
    error OwnerNotFound();

    /// @dev The key hash is invalid.
    error InvalidKeyHash();

    /// @dev Multisigs cannot be re-initialized.
    error ConfigAlreadySet();

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Threshold is the minimum number of owner signatures required for a verification.
    /// @dev ownerKeyHashes is a list of keyHashes (refer the Porto Account) that own the multi-sig
    struct Config {
        uint256 threshold;
        bytes32[] ownerKeyHashes;
    }

    /// @dev A config is mapped to a tuple of (address, keyhash)
    /// This allows a single account, to register multiple multi-sig configs.
    mapping(address => mapping(bytes32 => Config)) internal _configs;

    /// @dev Returns the threshold and ownerKeyHashes for a given keyHash and account.
    function getConfig(address account, bytes32 keyHash)
        public
        view
        returns (uint256 threshold, bytes32[] memory ownerKeyHashes)
    {
        Config memory config = _configs[account][keyHash];
        return (config.threshold, config.ownerKeyHashes);
    }

    ////////////////////////////////////////////////////////////////////////
    // Config Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Checks the current context keyhash in the Account, against the requested keyHash.
    function _checkKeyHash(bytes32 expectedKeyHash) internal view {
        bytes32 keyHash = IIthacaAccount(msg.sender).getContextKeyHash();
        if (keyHash != expectedKeyHash) revert InvalidKeyHash();
    }

    /// @dev Initialize a new multi-sig config.
    /// - This can only be called once per [keyHash][sender] tuple.
    ///   enforced by making sure threshold for an initialized key is never returned to 0.
    function initConfig(bytes32 keyHash, uint256 threshold, bytes32[] memory ownerKeyHashes)
        public
    {
        // Threshold can't be zero
        if (threshold == 0) revert InvalidThreshold();

        Config storage config = _configs[msg.sender][keyHash];

        if (config.threshold > 0) {
            revert ConfigAlreadySet();
        }

        _configs[msg.sender][keyHash] =
            Config({threshold: threshold, ownerKeyHashes: ownerKeyHashes});
    }

    /// @dev Adds a new owner keyhash to an existing multi-sig config.
    /// - Allows duplicates to be added.
    function addOwner(bytes32 keyHash, bytes32 ownerKeyHash) public {
        _checkKeyHash(keyHash);

        Config storage config = _configs[msg.sender][keyHash];
        config.ownerKeyHashes.push(ownerKeyHash);
    }

    /// @dev Removes an owner keyhash from an existing multi-sig config.
    /// - Throws `OwnerNotFound` if the requested keyhash is not found.
    /// - Throws `InvalidThreshold` if the number of owners goes below the threshold after removal.
    function removeOwner(bytes32 keyHash, bytes32 ownerKeyHash) public {
        _checkKeyHash(keyHash);

        Config storage config = _configs[msg.sender][keyHash];
        bytes32[] storage ownerKeyHashes_ = config.ownerKeyHashes;
        uint256 ownerKeyCount = ownerKeyHashes_.length;

        bool found = false;

        for (uint256 i = 0; i < ownerKeyCount; i++) {
            if (ownerKeyHashes_[i] == ownerKeyHash) {
                // Replace the owner to remove with the last owner
                ownerKeyHashes_[i] = ownerKeyHashes_[ownerKeyCount - 1];
                // Remove the last element
                ownerKeyHashes_.pop();
                found = true;
                break;
            }
        }

        if (!found) revert OwnerNotFound();
        if (ownerKeyCount - 1 < config.threshold) revert InvalidThreshold();
    }

    /// @dev Sets the threshold for an existing multi-sig config.
    /// - Throws `InvalidThreshold` if the threshold is 0 or greater than the number of owners.
    function setThreshold(bytes32 keyHash, uint256 threshold) public {
        _checkKeyHash(keyHash);

        Config storage config = _configs[msg.sender][keyHash];

        if (threshold == 0 || threshold > config.ownerKeyHashes.length) revert InvalidThreshold();

        config.threshold = threshold;
    }

    ////////////////////////////////////////////////////////////////////////
    // Signature Validation
    ////////////////////////////////////////////////////////////////////////

    /// @dev This function SHOULD only be called by valid IthacaAccounts.
    /// - This will iteratively make a call to the address(msg.sender).unwrapAndValidateSignature
    ///   for each owner key hash in the config.
    /// - Signature of a multi-sig should be encoded as abi.encode(bytes[] memory ownerSignatures)
    /// - For efficiency, place the signatures in the same order as the ownerKeyHashes in the config.
    /// - Failing owner signatures are ignored, as long as valid signaturs > threshold.
    function isValidSignatureWithKeyHash(bytes32 digest, bytes32 keyHash, bytes memory signature)
        public
        view
        returns (bytes4 magicValue)
    {
        bytes[] memory signatures = abi.decode(signature, (bytes[]));
        Config memory config = _configs[msg.sender][keyHash];

        uint256 validKeyNum;

        // Iterate over signatures, until threshold is met.
        for (uint256 i; i < signatures.length; ++i) {
            // Unwrap and validate the signature.
            (bool isValid, bytes32 ownerKeyHash) =
                IIthacaAccount(msg.sender).unwrapAndValidateSignature(digest, signatures[i]);

            if (!isValid) {
                continue;
            }

            uint256 j;
            while (j < config.ownerKeyHashes.length) {
                if (config.ownerKeyHashes[j] == ownerKeyHash) {
                    // Incrementing validKeyNum
                    validKeyNum++;
                    // Mark the ownerKeyHash as used.
                    config.ownerKeyHashes[j] = bytes32(0);

                    // If threshold is met, return success.
                    if (validKeyNum == config.threshold) {
                        return _MAGIC_VALUE;
                    }

                    break;
                }

                unchecked {
                    j++;
                }
            }

            // This means that the keyHash was not found
            if (j == config.ownerKeyHashes.length) {
                return _FAIL_VALUE;
            }
        }

        // If we reach here, then the required threshold was not met.
        return _FAIL_VALUE;
    }
}
