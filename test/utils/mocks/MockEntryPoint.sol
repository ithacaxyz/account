// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../../src/EntryPoint.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockEntryPoint is EntryPoint, Brutalizer {
    uint256 internal constant _SIMPLE_EXECUTE_GAS_OVERHEAD = 100000;

    function execute(UserOp calldata u) public payable virtual {
        uint256 gasBudget = u.combinedGas;
        uint256 gasStart = gasleft();
        (bool isValid, bytes32 keyHash) = _verify(u);
        if (!isValid) revert VerificationError();

        // This re-encodes the ERC7579 `executionData` with the optional `opData`.
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            0x0100000000007821000100000000000000000000000000000000000000000000,
            u.executionData,
            abi.encode(u.nonce, keyHash) // `opData`.
        );
        address eoa = u.eoa;
        assembly ("memory-safe") {
            if iszero(call(gasBudget, eoa, 0, add(0x20, data), mload(data), 0x00, 0x00)) {
                mstore(0x00, 0x6c9d47e8) // `CallError()`.
                revert(0x1c, 0x04)
            }
        }

        uint256 gasUsed = Math.rawSub(gasStart, gasleft());
        uint256 billed = Math.saturatingAdd(gasUsed, _SIMPLE_EXECUTE_GAS_OVERHEAD);
        uint256 finalPaymentAmount = Math.saturatingMul(billed, u.paymentPerGas);
        if (finalPaymentAmount > u.paymentMaxAmount) revert PaymentError();

        address paymentToken = u.paymentToken;
        address paymentRecipient = u.paymentRecipient;
        uint256 requiredBalanceAfter = Math.saturatingAdd(
            TokenTransferLib.balanceOf(paymentToken, paymentRecipient), finalPaymentAmount
        );
        assembly ("memory-safe") {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x00, 0x07dfd24c) // `compensate(address,uint256,address)`.
            mstore(0x20, shr(96, shl(96, paymentToken)))
            mstore(0x40, finalPaymentAmount)
            mstore(0x60, shr(96, shl(96, paymentRecipient)))
            pop(call(gas(), eoa, 0, 0x1c, 0x64, 0x00, 0x00))
            mstore(0x40, m) // Restore the free memory pointer.
            mstore(0x60, 0) // Restore the zero pointer.
        }
        if (TokenTransferLib.balanceOf(paymentToken, paymentRecipient) < requiredBalanceAfter) {
            revert PaymentError();
        }
    }

    function computeDigest(UserOp calldata userOp) public view returns (bytes32) {
        return _computeDigest(userOp);
    }
}
