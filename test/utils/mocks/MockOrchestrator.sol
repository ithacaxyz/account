// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Orchestrator} from "../../../src/Orchestrator.sol";
import {Brutalizer} from "../Brutalizer.sol";
import {IntentHelpers} from "../../../src/libraries/IntentHelpers.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockOrchestrator is Orchestrator, Brutalizer {
    error NoRevertEncountered();

    constructor() Orchestrator() {}

    function computeDigest(SignedCall calldata preCall) public view returns (bytes32) {
        return _computeDigest(preCall);
    }

    // Expose internal functions for testing
    function hashTypedData(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedData(structHash);
    }

    function hashTypedDataSansChainId(bytes32 structHash) public view returns (bytes32) {
        return _hashTypedDataSansChainId(structHash);
    }

    function simulateFailed(bytes calldata encodedIntent) public payable virtual {
        _execute(encodedIntent, type(uint256).max, 1);
        revert NoRevertEncountered();
    }

    uint256 i = 0;

    /// @dev Helper function to parse and print all fields from intent calldata
    function checkIntent(bytes calldata intent) external {
        // Override msg.data for the IntentHelpers parsing functions to work
        assembly ("memory-safe") {
            // We need to copy the intent data to msg.data location for parsing
            // This is a test helper, so we can use a temporary workaround
        }

        i++;

        // Parse the intent data manually since we can't override msg.data in a view function
        // We'll extract the fields based on the known intent structure

        uint256 offset = 0;

        // Extract supportedAccountImplementation (20 bytes)
        {
            address supportedAccountImplementation;
            assembly ("memory-safe") {
                supportedAccountImplementation := shr(96, calldataload(add(intent.offset, offset)))
            }
            offset += 20;
        }

        {
            // Extract eoa (32 bytes, padded)
            address eoa;
            assembly ("memory-safe") {
                eoa := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }

        uint256 nonce;
        {
            // Extract nonce (32 bytes)
            assembly ("memory-safe") {
                nonce := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract payer (32 bytes, padded)
            address payer;
            assembly ("memory-safe") {
                payer := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract paymentToken (32 bytes, padded)
            address paymentToken;
            assembly ("memory-safe") {
                paymentToken := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract paymentMaxAmount (32 bytes)
            uint256 paymentMaxAmount;
            assembly ("memory-safe") {
                paymentMaxAmount := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract combinedGas (32 bytes)
            uint256 combinedGas;
            assembly ("memory-safe") {
                combinedGas := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract expiry (32 bytes)
            uint256 expiry;
            assembly ("memory-safe") {
                expiry := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract paymentAmount (32 bytes)
            uint256 paymentAmount;
            assembly ("memory-safe") {
                paymentAmount := calldataload(add(intent.offset, offset))
            }
            offset += 32;
        }
        {
            // Extract paymentRecipient (20 bytes)
            address paymentRecipient;
            assembly ("memory-safe") {
                paymentRecipient := shr(96, calldataload(add(intent.offset, offset)))
            }
            offset += 20;
        }
        {
            // Extract executionData length and data
            uint256 executionDataLength;
            assembly ("memory-safe") {
                executionDataLength := calldataload(add(intent.offset, offset))
            }
            offset += 32;

            offset += executionDataLength;
        }
        {
            // Extract fundData length and data
            uint256 fundDataLength;
            assembly ("memory-safe") {
                fundDataLength := calldataload(add(intent.offset, offset))
            }
            offset += 32;

            if (fundDataLength > 0) {
                // Parse fundData if present
                bytes calldata fundData = intent[offset:offset + fundDataLength];
                address funder;
                assembly ("memory-safe") {
                    funder := shr(96, calldataload(fundData.offset))
                }
            }
            offset += fundDataLength;
        }
        {
            // Extract encodedPreCalls length and data
            uint256 preCallsLength;
            assembly ("memory-safe") {
                preCallsLength := calldataload(add(intent.offset, offset))
            }
            offset += 32;

            if (preCallsLength > 0) {}
            offset += preCallsLength;
        }
        {
            // Extract signature length and data
            uint256 signatureLength;
            assembly ("memory-safe") {
                signatureLength := calldataload(add(intent.offset, offset))
            }
            offset += 32;

            offset += signatureLength;
        }

        // Check if we have settler data (for merkle verification nonce)
        if (nonce >> 240 == 0x6D76 && offset < intent.length) {
            uint256 settlerDataLength;
            assembly ("memory-safe") {
                settlerDataLength := calldataload(add(intent.offset, offset))
            }
            offset += 32;

            if (settlerDataLength > 0) {
                // Parse settler data
                address settler;
                assembly ("memory-safe") {
                    settler := shr(96, calldataload(add(intent.offset, offset)))
                }
            }
            offset += settlerDataLength;
        }
        {
            // Extract paymentSignature (remaining data except last 32 bytes)
            uint256 paymentSignatureLength;
            assembly ("memory-safe") {
                paymentSignatureLength := calldataload(sub(add(intent.offset, intent.length), 0x20))
            }

            if (paymentSignatureLength > 0) {}
        }
    }
}
