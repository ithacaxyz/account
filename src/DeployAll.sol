// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import "../src/PortoAccount.sol";
import "../src/Orchestrator.sol";
import "../src/AccountRegistry.sol";
import "../src/Simulator.sol";

contract DeployAll {
    address public immutable orchestrator;
    address public immutable accountImplementation;
    address public immutable accountProxy;
    address public immutable accountRegistry;
    address public immutable simulator;

    constructor() payable {
        orchestrator = address(new Orchestrator(msg.sender));
        accountImplementation = address(new PortoAccount(address(orchestrator)));
        accountProxy = LibEIP7702.deployProxy(accountImplementation, address(0));
        accountRegistry = address(new AccountRegistry());
        simulator = address(new Simulator());
    }
}
