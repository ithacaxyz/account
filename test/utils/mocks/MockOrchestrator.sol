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
}
