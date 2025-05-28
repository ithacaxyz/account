// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {PortoAccount} from "../src/PortoAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {Simulator} from "../src/Simulator.sol";

contract DeployAllScript is Script {
    address public orchestrator;
    address public accountImplementation;
    address public accountProxy;
    address public accountRegistry;
    address public simulator;

    function run() external {
        vm.startBroadcast();
        address pauseAuthority = vm.envAddress("PAUSE_AUTHORITY");
        orchestrator = address(new Orchestrator(pauseAuthority));
        accountImplementation = address(new PortoAccount(address(orchestrator)));
        accountProxy = LibEIP7702.deployProxy(accountImplementation, address(0));
        accountRegistry = address(new AccountRegistry());
        simulator = address(new Simulator());
        vm.stopBroadcast();
    }
}
