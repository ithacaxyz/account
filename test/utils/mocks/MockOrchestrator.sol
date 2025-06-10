// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Orchestrator} from "../../../src/Orchestrator.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockOrchestrator is Orchestrator, Brutalizer {
    error NoRevertEncountered();

    constructor(address pauseAuthority) Orchestrator(pauseAuthority) {}

    function computeDigest(SignedCall calldata preCall) public view returns (bytes32) {
        return _computeDigest(preCall);
    }

    function computeDigest(Intent calldata intent) public view returns (bytes32) {
        return _computeDigest(intent);
    }

    function simulateFailed(bytes calldata encodedIntent) public payable virtual {
        _execute(encodedIntent, type(uint256).max, 1);
        revert NoRevertEncountered();
    }
}
