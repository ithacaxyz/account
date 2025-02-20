// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {PaymentPriorityLib} from "../src/PaymentPriorityLib.sol";

contract EntryPointTest is SoladyTest {
    function testPackAndUnpack(
        address priorityRecipient, 
        uint40 startTimestamp, 
        uint16 gatedDuration,
        uint16 reverseDutchAuctionDuration,
        uint16 futureUse,
        uint8 version
    ) public {
        bytes memory encoded = abi.encodePacked(
            priorityRecipient,
            startTimestamp,
            gatedDuration,
            reverseDutchAuctionDuration,
            futureUse,
            version
        );
        bytes32 paymentPriority = abi.decode(encoded, (bytes32));
        assertEq(PaymentPriorityLib.getPriorityRecipient(paymentPriority), priorityRecipient);
        assertEq(PaymentPriorityLib.getStartTimestamp(paymentPriority), startTimestamp);
    }
    
}
