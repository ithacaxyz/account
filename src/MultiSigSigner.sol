// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IDelegation} from "./interfaces/IDelegation.sol";

contract MultiSigSigner {
    // bytes4(keccak256("isValidSignatureWithKeyHash(bytes32,bytes32,bytes)")
    bytes4 internal constant MAGIC_VALUE = 0x8afc93b4;

    bytes4 internal constant FAIL_VALUE = 0xffffffff;

    /// @dev The threshold can't be zero.
    error InvalidThreshold();

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    struct Config {
        uint256 threshold;
        bytes32[] keyHashes;
    }

    mapping(address => mapping(bytes32 => Config)) public configs;

    function setConfig(bytes32 keyHash, uint256 threshold, bytes32[] memory keyHashes) public {
        // Threshold can't be zero
        if (threshold == 0) revert InvalidThreshold();

        configs[msg.sender][keyHash] = Config({threshold: threshold, keyHashes: keyHashes});
    }

    function addOwner(bytes32 keyHash, bytes32 ownerKeyHash) public {
        Config storage config = configs[msg.sender][keyHash];
        config.keyHashes.push(ownerKeyHash);
    }

    function removeOwner(bytes32 keyHash, bytes32 ownerKeyHash) public {}

    function setThreshold(bytes32 keyHash, uint256 threshold) public {
        // Threshold can't be zero
        if (threshold == 0) revert InvalidThreshold();

        Config storage config = configs[msg.sender][keyHash];
        config.threshold = threshold;
    }

    /// @dev This function should only be called by valid Delegation porto accounts.
    /// This will iteratively make a call to the `unwrapAndValidateSignature` function of the msg.sender
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
            while (j < config.keyHashes.length) {
                if (config.keyHashes[j] == k) {
                    // Incrementing validKeyNum
                    validKeyNum++;
                    config.keyHashes[j] = bytes32(0);

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
            if (j == config.keyHashes.length) {
                return FAIL_VALUE;
            }
        }

        // If we reach here, then the required threshold was not met.
        return FAIL_VALUE;
    }
}
