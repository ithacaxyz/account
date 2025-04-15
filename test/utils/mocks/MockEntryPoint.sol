// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EntryPoint} from "../../../src/EntryPoint.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockEntryPoint is EntryPoint, Brutalizer {
    error NoRevertEncountered();

    constructor() payable EntryPoint(msg.sender) {}

    function computeDigest(PreOp calldata preOp) public view returns (bytes32) {
        return _computeDigest(preOp);
    }

    function computeDigest(UserOp calldata userOp) public view returns (bytes32) {
        return _computeDigest(userOp);
    }

    /// @dev This function is provided for debugging purposes.
    /// This function bubbles up the full revert for the calls
    /// to `initializePREP` (if any) and `execute` on the eoa.
    function simulateFailed(bytes calldata encodedUserOp) public payable virtual {
        _execute(encodedUserOp, _FLAG_BUBBLE_FULL_REVERT);
        revert NoRevertEncountered();
    }
}
