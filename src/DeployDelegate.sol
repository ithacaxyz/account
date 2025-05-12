// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import "../src/Delegation.sol";

contract DeployDelegate {
    address public immutable delegationImplementation;
    address public immutable delegationProxy;

    constructor(address entryPoint) payable {
        delegationImplementation = address(new Delegation(entryPoint));
        delegationProxy = LibEIP7702.deployProxy(delegationImplementation, address(0));
    }
}
