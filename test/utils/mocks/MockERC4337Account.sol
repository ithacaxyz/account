// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ERC4337} from "solady/accounts/ERC4337.sol";

contract MockERC4337Account is ERC4337 {
    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("MockERC4337Account", "0.0.1");
    }
}
