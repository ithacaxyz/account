// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EntryPoint} from "../../../src/EntryPoint.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockEntryPoint is EntryPoint, Brutalizer {
    constructor() payable EntryPoint(msg.sender) {
        UserOp memory uTest;
        uTest.paymentAmount = 0x112233;
        uTest.paymentMaxAmount = 0x223344;
        uTest.paymentPerGas = 0x334455;
        bytes memory encoded = abi.encode(uTest);
        assembly ("memory-safe") {
            let o := add(encoded, 0x20)
            let u := add(o, mload(o))
            if iszero(eq(mload(add(u, _PAYMENT_AMOUNT_OFFSET)), 0x112233)) { invalid() }
            if iszero(eq(mload(add(u, _PAYMENT_MAX_AMOUNT_OFFSET)), 0x223344)) { invalid() }
            if iszero(eq(mload(add(u, _PAYMENT_PER_GAS_OFFSET)), 0x334455)) { invalid() }
        }
    }

    function computeDigest(UserOp calldata userOp) public view returns (bytes32) {
        return _computeDigest(userOp);
    }
}
