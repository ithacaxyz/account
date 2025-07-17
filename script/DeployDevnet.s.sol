// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";

/**
 * @title DeployDevnet
 * @notice Simple deployment script for Porto devnet without external config files
 */
contract DeployDevnet is Script {
    function run() external {
        console.log("\n========================================");
        console.log("Deploying to Porto Devnet");
        console.log("========================================");

        // Hardcoded config for devnet
        address pauseAuthority = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf; // Example address

        vm.startBroadcast();

        // Deploy Orchestrator
        Orchestrator orchestrator = new Orchestrator(pauseAuthority);
        console.log("Orchestrator deployed:", address(orchestrator));

        // Deploy IthacaAccount implementation
        IthacaAccount implementation = new IthacaAccount(address(orchestrator));
        console.log("Account implementation deployed:", address(implementation));

        // Deploy account proxy
        address proxy = LibEIP7702.deployProxy(address(implementation), address(0));
        console.log("Account proxy deployed:", proxy);

        // Deploy Simulator
        Simulator simulator = new Simulator();
        console.log("Simulator deployed:", address(simulator));

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("Deployment Complete!");
        console.log("========================================");
        console.log("Orchestrator:", address(orchestrator));
        console.log("Implementation:", address(implementation));
        console.log("Proxy:", proxy);
        console.log("Simulator:", address(simulator));
    }
}
