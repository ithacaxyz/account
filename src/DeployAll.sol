// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import "../src/Delegation.sol";
import "../src/EntryPoint.sol";

contract DeployAll {
    address public immutable entryPoint;
    address public immutable delegationImplementation;
    address public immutable delegationProxy;

    constructor(address deployer) payable {
        entryPoint = address(new EntryPoint(deployer));
        delegationImplementation = address(new Delegation(address(entryPoint)));
        delegationProxy = address(new EIP7702Proxy(delegationImplementation, address(0)));
    }
}
