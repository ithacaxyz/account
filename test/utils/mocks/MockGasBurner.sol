// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {GasBurnerLib} from "solady/utils/GasBurnerLib.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockGasBurner {
    uint256 public randomness;

    function setRandomness(uint256 r) public {
        randomness = r;
    }

    function burnGas(uint256 x, uint256 r) public {
        if (r & 1 == 0) {
            GasBurnerLib.burnPure(x);
        } else {
            this.burnGas(x, r >> 1);
        }
        randomness = r;
    }
}
