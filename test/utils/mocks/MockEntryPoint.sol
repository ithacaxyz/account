// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {EntryPoint} from "../../../src/EntryPoint.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockEntryPoint is EntryPoint, Brutalizer {
    constructor() {
        UserOp memory userOp;
        userOp.paymentAmount = 987987;
        userOp.paymentMaxAmount = 789789;
        userOp.executionData = hex"112233";
        userOp.combinedGas = 111;
        userOp.signature = hex"8899aa";
        uint256 paymentAmount;
        uint256 paymentMaxAmount;
        uint256 combinedGas;
        bytes memory executionData;
        bytes memory signature;
        assembly ("memory-safe") {
            paymentAmount := mload(add(userOp, _USER_OP_PAYMENT_AMOUNT_POS))
            paymentMaxAmount := mload(add(userOp, _USER_OP_PAYMENT_MAX_AMOUNT_POS))
            combinedGas := mload(add(userOp, _USER_OP_COMBINED_GAS_POS))
            executionData := mload(add(userOp, _USER_OP_EXECUTION_DATA_POS))
            signature := mload(add(userOp, _USER_OP_SIGNATURE_POS))
        }
        assert(paymentAmount == userOp.paymentAmount);
        assert(paymentMaxAmount == userOp.paymentMaxAmount);
        assert(combinedGas == userOp.combinedGas);
        assert(keccak256(executionData) == keccak256(userOp.executionData));
        assert(keccak256(signature) == keccak256(userOp.signature));
    }

    function computeDigest(UserOp calldata userOp) public view returns (bytes32) {
        return _computeDigest(userOp);
    }
}
