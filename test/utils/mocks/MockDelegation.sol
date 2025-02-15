// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../../../src/Delegation.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockDelegation is Delegation, Brutalizer {
    function compensate(address paymentToken, uint256 paymentAmount, address to) public virtual {
        if (msg.sender != ENTRY_POINT) revert Unauthorized();
        TokenTransferLib.safeTransfer(paymentToken, to, paymentAmount);
    }
}
