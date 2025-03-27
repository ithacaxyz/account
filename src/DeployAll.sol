// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import "../src/Delegation.sol";
import "../src/EntryPoint.sol";

contract DeployAll {
    address public immutable entryPoint;
    address public immutable delegationImplementation;
    address public immutable delegationProxy;

    constructor(address deployer) payable {
        entryPoint = address(new EntryPoint(deployer));
        delegationImplementation = address(new Delegation(address(entryPoint)));
        delegationProxy = LibEIP7702.deployProxy(delegationImplementation, address(0));
    }
}
