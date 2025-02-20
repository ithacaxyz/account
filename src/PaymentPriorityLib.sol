// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title PaymentPriorityLib
/// @notice A library to manage gated payment and payment auctions.
///
/// @dev Leaving `paymentPrority` as `bytes32(0)` will simply turn off the gating and payment auction.
///
/// `paymentPriority` bytes Layout:
/// - [0..19]  (20 bytes)  `priorityRecipient`.
/// - [20..24] ( 5 bytes)  `startTimestamp`. Up to about year 36811.
/// - [25..26] ( 2 bytes)  `gatedDuration`. Up to about 18 hours.
/// - [27..28] ( 2 bytes)  `reverseDutchAuctionDuration`. Up to about 18 hours.
/// - [29..30] ( 2 bytes)  `futureUse` (hook IDs maybe?).
/// - [31]     ( 1 byte )  `mode` (currently 0, so ignored).
/// In the future, `mode` might be used for conditional features.
library PaymentPriorityLib {
    /// @dev Returns the final payment max amount.
    /// Linearly interpolated from 0 to `paymentMaxAmount`
    /// as `block.timestamp` goes from
    /// `startTimestamp` to `startTimestamp + reverseDutchAuctionDuration`.
    function finalPaymentMaxAmount(bytes32 paymentPriority, uint256 paymentMaxAmount)
        internal
        view
        returns (uint256)
    {
        uint256 begin = startTimestamp(paymentPriority);
        uint256 end = Math.rawAdd(begin, reverseDutchAuctionDuration(paymentPriority));
        return Math.lerp(0, paymentMaxAmount, block.timestamp, begin, end);
    }

    /// @dev Returns the final payment recipient.
    /// If `priorityRecipient != address(0) && block.timestamp <= startTimestamp + gatedDuration`,
    /// returns `priorityRecipient`.
    /// Otherwise, returns `paymentRecipient == address(0) ? address(this) : paymentRecipient`.
    function finalPaymentRecipient(bytes32 paymentPriority, address paymentRecipient)
        internal
        view
        returns (address result)
    {
        result = priorityRecipient(paymentPriority);
        if (result != address(0)) {
            uint256 begin = startTimestamp(paymentPriority);
            uint256 end = Math.rawAdd(begin, gatedDuration(paymentPriority));
            if (block.timestamp <= end) return result;
        }
        result = Math.coalesce(paymentRecipient, address(this));
    }

    /// @dev Returns the priority recipient.
    function priorityRecipient(bytes32 paymentPriority) internal pure returns (address) {
        return address(bytes20(paymentPriority));
    }

    /// @dev Returns the start timestamp.
    function startTimestamp(bytes32 paymentPriority) internal pure returns (uint40) {
        return uint40(uint256(paymentPriority) >> (256 - (20 + 5) * 8));
    }

    /// @dev Returns the gated duration.
    function gatedDuration(bytes32 paymentPriority) internal pure returns (uint16) {
        return uint16(uint256(paymentPriority) >> (256 - (20 + 5 + 2) * 8));
    }

    /// @dev Returns the reverse dutch auction duration.
    function reverseDutchAuctionDuration(bytes32 paymentPriority) internal pure returns (uint256) {
        return uint16(uint256(paymentPriority) >> (256 - (20 + 5 + 2 + 2) * 8));
    }

    /// @dev Returns the future use.
    function futureUse(bytes32 paymentPriority) internal pure returns (uint256) {
        return uint16(uint256(paymentPriority) >> (256 - (20 + 5 + 2 + 2 + 2) * 8));
    }

    /// @dev Returns the mode.
    function mode(bytes32 paymentPriority) internal pure returns (uint8) {
        return uint8(uint256(paymentPriority));
    }

    /// @dev Packs the parameters into a single word.
    /// Provided mainly for testing and reference purposes.
    function pack(
        address priorityRecipient_,
        uint40 startTimestamp_,
        uint16 gatedDuration_,
        uint16 reverseDutchAuctionDuration_,
        uint16 futureUse_,
        uint8 mode_
    ) internal pure returns (bytes32) {
        bytes memory encoded = abi.encodePacked(
            priorityRecipient_,
            startTimestamp_,
            gatedDuration_,
            reverseDutchAuctionDuration_,
            futureUse_,
            mode_
        );
        assert(encoded.length == 32);
        return abi.decode(encoded, (bytes32));
    }
}
