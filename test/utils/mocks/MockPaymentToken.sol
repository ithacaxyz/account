// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockPaymentToken is ERC20 {
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function anotherTransfer(address to, uint256 amount) public returns (bool) {
        transfer(to, amount);
        return true;
    }

    function name() public view virtual override returns (string memory) {
        return "Name";
    }

    function symbol() public view virtual override returns (string memory) {
        return "SYM";
    }
}
