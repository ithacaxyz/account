// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EntryPoint} from "../../../src/EntryPoint.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockEntryPoint is EntryPoint, Brutalizer {
    /// @dev No revert has been encountered.
    error NoRevertEncountered();

    constructor() payable EntryPoint(msg.sender) {
        UserOp memory uTest;
        uTest.paymentAmount = 0x112233;
        uTest.paymentMaxAmount = 0x223344;
        uTest.paymentPerGas = 0x334455;
        bytes memory encoded = abi.encode(uTest);
        assembly ("memory-safe") {
            let o := add(encoded, 0x20)
            let u := add(o, mload(o))
            if iszero(eq(mload(add(u, _USER_OP_PAYMENT_AMOUNT_OFFSET)), 0x112233)) { invalid() }
            if iszero(eq(mload(add(u, _USER_OP_PAYMENT_MAX_AMOUNT_OFFSET)), 0x223344)) { invalid() }
            if iszero(eq(mload(add(u, _USER_OP_PAYMENT_PER_GAS_OFFSET)), 0x334455)) { invalid() }
        }
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
