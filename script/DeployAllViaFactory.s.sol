// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IthacaFactory} from "../src/IthacaFactory.sol";

contract DeployAllViaFactoryScript is Script {
    // Default factory address (can be overridden by env variable)
    address constant DEFAULT_FACTORY = 0x0000000000FFe8B47B3e2130213B802212439497;

    // Salt for deterministic deployments
    bytes32 constant DEPLOYMENT_SALT = keccak256("ithaca.account.v1");

    address public orchestrator;
    address public accountImplementation;
    address public accountProxy;
    address public simulator;

    function run() external {
        vm.startBroadcast();

        // Get factory address from env or use default
        address factoryAddress = vm.envOr("ITHACA_FACTORY", DEFAULT_FACTORY);
        require(factoryAddress.code.length > 0, "Factory not deployed");

        IthacaFactory factory = IthacaFactory(factoryAddress);

        // Get pause authority from env
        address pauseAuthority = vm.envAddress("PAUSE_AUTHORITY");
        require(pauseAuthority != address(0), "PAUSE_AUTHORITY not set");

        // Predict addresses before deployment
        (
            address predictedOrchestrator,
            address predictedAccountImpl,
            address predictedAccountProxy,
            address predictedSimulator
        ) = factory.predictAddresses(pauseAuthority, DEPLOYMENT_SALT);

        console.log("Predicted addresses:");
        console.log("  Orchestrator:", predictedOrchestrator);
        console.log("  Account Implementation:", predictedAccountImpl);
        console.log("  Account Proxy:", predictedAccountProxy);
        console.log("  Simulator:", predictedSimulator);

        // Deploy all contracts using the factory
        (orchestrator, accountImplementation, accountProxy, simulator) =
            factory.deployAll(pauseAuthority, DEPLOYMENT_SALT);

        // Verify deployments match predictions
        require(orchestrator == predictedOrchestrator, "Orchestrator address mismatch");
        require(
            accountImplementation == predictedAccountImpl, "Account implementation address mismatch"
        );
        require(accountProxy == predictedAccountProxy, "Account proxy address mismatch");
        require(simulator == predictedSimulator, "Simulator address mismatch");

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("\nDeployed contracts:");
        console.log("  Orchestrator:", orchestrator);
        console.log("  Account Implementation:", accountImplementation);
        console.log("  Account Proxy:", accountProxy);
        console.log("  Simulator:", simulator);
    }
}
