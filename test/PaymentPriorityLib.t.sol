// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {PaymentPriorityLib} from "../src/PaymentPriorityLib.sol";

contract EntryPointTest is SoladyTest {
    using PaymentPriorityLib for bytes32;

    function testPackAndUnpack(
        address priorityRecipient,
        uint40 startTimestamp,
        uint16 gatedDuration,
        uint16 reverseDutchAuctionDuration,
        uint16 futureUse,
        uint8 version
    ) public pure {
        bytes32 paymentPriority = PaymentPriorityLib.pack(
            priorityRecipient,
            startTimestamp,
            gatedDuration,
            reverseDutchAuctionDuration,
            futureUse,
            version
        );
        assertEq(paymentPriority.priorityRecipient(), priorityRecipient);
        assertEq(paymentPriority.startTimestamp(), startTimestamp);
        assertEq(paymentPriority.gatedDuration(), gatedDuration);
        assertEq(paymentPriority.reverseDutchAuctionDuration(), reverseDutchAuctionDuration);
        assertEq(paymentPriority.futureUse(), futureUse);
        assertEq(paymentPriority.version(), version);
    }

    function testFinalPaymentMaxAmount(
        uint256 paymentMaxAmount,
        uint40 startTimestamp,
        uint16 reverseDutchAuctionDuration
    ) public {
        uint256 currentTimestamp = _bound(_random(), 0, 2 ** 41 - 1);
        vm.warp(currentTimestamp);

        bytes32 paymentPriority = PaymentPriorityLib.pack(
            address(0), startTimestamp, 0, reverseDutchAuctionDuration, 0, 0
        );

        if (currentTimestamp <= startTimestamp) {
            assertEq(paymentPriority.finalPaymentMaxAmount(paymentMaxAmount), 0);
        } else if (currentTimestamp >= uint256(startTimestamp) + reverseDutchAuctionDuration) {
            assertEq(paymentPriority.finalPaymentMaxAmount(paymentMaxAmount), paymentMaxAmount);
        } else {
            uint256 expected = Math.fullMulDiv(
                paymentMaxAmount, currentTimestamp - startTimestamp, reverseDutchAuctionDuration
            );
            assertEq(paymentPriority.finalPaymentMaxAmount(paymentMaxAmount), expected);
        }
    }

    function finalPaymentRecipient(
        address priorityRecipient,
        address paymentRecipient,
        uint40 startTimestamp,
        uint16 gatedDuration
    ) public {
        uint256 currentTimestamp = _bound(_random(), 0, 2 ** 41 - 1);
        vm.warp(currentTimestamp);

        bytes32 paymentPriority =
            PaymentPriorityLib.pack(priorityRecipient, startTimestamp, gatedDuration, 0, 0, 0);

        if (currentTimestamp <= startTimestamp && priorityRecipient != address(0)) {
            assertEq(paymentPriority.finalPaymentRecipient(paymentRecipient), priorityRecipient);
        } else {
            assertEq(
                paymentPriority.finalPaymentRecipient(paymentRecipient),
                paymentRecipient == address(0) ? address(this) : paymentRecipient
            );
        }
    }
}
