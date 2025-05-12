// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IDelegation} from "./interfaces/IDelegation.sol";
import {ISigner} from "./interfaces/ISigner.sol";

contract MultiSigSigner is ISigner {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The magic value returned by `isValidSignatureWithKeyHash` when the signature is valid.
    /// - Calcualated as: bytes4(keccak256("isValidSignatureWithKeyHash(bytes32,bytes32,bytes)")
    bytes4 internal constant MAGIC_VALUE = 0x8afc93b4;

    /// @dev The magic value returned by `isValidSignatureWithKeyHash` when the signature is invalid.
    bytes4 internal constant FAIL_VALUE = 0xffffffff;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev The threshold can't be zero.
    error InvalidThreshold();

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    struct Config {
        uint256 threshold;
        bytes32[] ownerKeyHashes;
    }

    /// @dev A config is mapped to a tuple of (address, keyhash)
    /// This allows a single account, to register multiple multi-sig configs.
    mapping(address => mapping(bytes32 => Config)) public configs;

    ////////////////////////////////////////////////////////////////////////
    // Config Functions
    ////////////////////////////////////////////////////////////////////////

    function setConfig(bytes32 keyHash, uint256 threshold, bytes32[] memory ownerKeyHashes)
        public
    {
        // Threshold can't be zero
        if (threshold == 0) revert InvalidThreshold();

        configs[msg.sender][keyHash] =
            Config({threshold: threshold, ownerKeyHashes: ownerKeyHashes});
    }

    function addOwner(bytes32 keyHash, bytes32 ownerKeyHash) public {
        Config storage config = configs[msg.sender][keyHash];
        config.ownerKeyHashes.push(ownerKeyHash);
    }

    function removeOwner(bytes32 keyHash, bytes32 ownerKeyHash) public {
        Config storage config = configs[msg.sender][keyHash];
        bytes32[] storage ownerKeyHashes_ = config.ownerKeyHashes;
        uint256 ownerKeyCount = ownerKeyHashes_.length;

        for (uint256 i = 0; i < ownerKeyCount; i++) {
            if (ownerKeyHashes_[i] == ownerKeyHash) {
                // Replace the owner to remove with the last owner
                ownerKeyHashes_[i] = ownerKeyHashes_[ownerKeyCount - 1];
                // Remove the last element
                ownerKeyHashes_.pop();
                break;
            }
        }
    }

    function setThreshold(bytes32 keyHash, uint256 threshold) public {
        // Threshold can't be zero
        if (threshold == 0) revert InvalidThreshold();

        Config storage config = configs[msg.sender][keyHash];
        config.threshold = threshold;
    }

    ////////////////////////////////////////////////////////////////////////
    // Signature Validation
    ////////////////////////////////////////////////////////////////////////

    /// @dev This function SHOULD only be called by valid Delegation porto accounts.
    /// - This will iteratively make a call to the address(msg.sender).unwrapAndValidateSignature
    ///   for each owner key hash in the config.
    /// - Signature of a multi-sig should be encoded as abi.encode(bytes[] memory ownerSignatures)
    /// - For efficiency, place the signatures in the same order as the ownerKeyHashes in the config.
    function isValidSignatureWithKeyHash(bytes32 digest, bytes32 keyHash, bytes memory signature)
        public
        view
        returns (bytes4 magicValue)
    {
        bytes[] memory signatures = abi.decode(signature, (bytes[]));
        Config memory config = configs[msg.sender][keyHash];

        uint256 validKeyNum;

        for (uint256 i; i < signatures.length; ++i) {
            (bool v, bytes32 k) =
                IDelegation(msg.sender).unwrapAndValidateSignature(digest, signatures[i]);

            if (!v) {
                return FAIL_VALUE;
            }

            uint256 j;
            while (j < config.ownerKeyHashes.length) {
                if (config.ownerKeyHashes[j] == k) {
                    // Incrementing validKeyNum
                    validKeyNum++;
                    config.ownerKeyHashes[j] = bytes32(0);

                    if (validKeyNum == config.threshold) {
                        return MAGIC_VALUE;
                    }

                    break;
                }

                unchecked {
                    j++;
                }
            }

            // This means that the keyHash was not found
            if (j == config.ownerKeyHashes.length) {
                return FAIL_VALUE;
            }
        }

        // If we reach here, then the required threshold was not met.
        return FAIL_VALUE;
    }
}
