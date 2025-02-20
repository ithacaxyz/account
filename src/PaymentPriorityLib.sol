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
/// - [20..24] ( 5 bytes)  `startTimestamp`. Upto year 36811.
/// - [25..26] ( 2 bytes)  `gatedDuration`. Upto ~18 hours.
/// - [27..28] ( 2 bytes)  `reverseDutchAuctionDuration`. Upto ~18 hours.
/// - [29..30] ( 2 bytes)  `futureUse` (hook IDs maybe?).
/// - [31]     ( 1 byte )  `priorityVersion` (currently 0).
///
/// When `block.timestamp <= startTimestamp + gatedDuration`, only the `priorityRecipient`
/// can get paid. If the `paymentRecipient` is non-zero and is someone else, payment is skipped.
///
/// The `finalPaymentMaxAmount` will be linearly interpolated from
/// 0 -> `paymentMaxAmount` as `block.timestamp` goes from
/// `startTimestamp` -> `startTimestamp + reverseDutchAuctionDuration`.
library PaymentPriorityLib {
    error UnsupportedPaymentPriorityVersion();

    function checkVersion(bytes32 paymentPriority) internal pure {
        if (getVersion(paymentPriority) != 0) revert UnsupportedPaymentPriorityVersion();
    }

    function finalPaymentMaxAmount(bytes32 paymentPriority, uint256 paymentMaxAmount)
        internal
        view
        returns (uint256 result)
    {
        uint256 begin = getStartTimestamp(paymentPriority);
        if (block.timestamp <= begin) return 0;
        uint256 dur = getReverseDutchAuctionDuration(paymentPriority);
        unchecked {
            if (block.timestamp >= begin + dur) return paymentMaxAmount;
            return paymentMaxAmount - Math.rawDiv(paymentMaxAmount * (block.timestamp - begin), dur);
        }
    }

    function finalPaymentRecipient(bytes32 paymentPriority, address paymentRecipient)
        internal
        view
        returns (address)
    {
        address priorityRecipient = getPriorityRecipient(paymentPriority);
        unchecked {
            if (priorityRecipient != address(0)) {
                if (
                    block.timestamp
                        <= getStartTimestamp(paymentPriority) + getGatedDuration(paymentPriority)
                ) {
                    return priorityRecipient;
                }
            }
        }
        return paymentRecipient;
    }

    /// @dev Returns the `priorityRecipient`.
    function getPriorityRecipient(bytes32 paymentPriority) internal pure returns (address) {
        return address(bytes20(paymentPriority));
    }

    /// @dev Returns the `startTimestamp`.
    function getStartTimestamp(bytes32 paymentPriority) internal pure returns (uint256) {
        return (uint256(paymentPriority) << ((20) * 8)) >> (256 - 5 * 8);
    }

    /// @dev Returns the `gatedDuration`.
    function getGatedDuration(bytes32 paymentPriority) internal pure returns (uint256) {
        return (uint256(paymentPriority) << ((20 + 5) * 8)) >> (256 - 2 * 8);
    }

    /// @dev Returns the `reverseDutchAuctionDuration`.
    function getReverseDutchAuctionDuration(bytes32 paymentPriority)
        internal
        pure
        returns (uint256)
    {
        return (uint256(paymentPriority) << ((20 + 5 + 2) * 8)) >> (256 - 2 * 8);
    }

    /// @dev Returns the `futureUse`.
    function getFutureUse(bytes32 paymentPriority) internal pure returns (uint256) {
        return (uint256(paymentPriority) << ((20 + 5 + 2 + 2) * 8)) >> (256 - 2 * 8);
    }

    /// @dev Returns the `version`.
    function getVersion(bytes32 paymentPriority) internal pure returns (uint256) {
        return uint256(paymentPriority) & 0xff;
    }
}
