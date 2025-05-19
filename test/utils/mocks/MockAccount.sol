// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {PortoAccount} from "../../../src/PortoAccount.sol";
import {Brutalizer} from "../Brutalizer.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockAccount is PortoAccount, Brutalizer {
    uint256 public x;

    constructor(address orchestrator) payable PortoAccount(orchestrator) {}

    function _keyTypeCanBeSuperAdmin(KeyType) internal pure override returns (bool) {
        return true;
    }

    function setX(uint256 newX) public onlyThis {
        x = newX;
    }

    function resetX() public {
        x = 0;
    }
}
