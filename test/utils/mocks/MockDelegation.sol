// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Delegation} from "../../../src/Delegation.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockDelegation is Delegation, Brutalizer {
    uint256 public x;

    constructor(address entryPoint) payable Delegation(entryPoint) {}

    function setX(uint256 newX) public onlyThis {
        x = newX;
    }

    function resetX() public {
        x = 0;
    }
}
