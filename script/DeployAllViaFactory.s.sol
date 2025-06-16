// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IthacaFactory} from "../src/IthacaFactory.sol";

contract DeployAllViaFactoryScript is Script {
    // Custom errors
    error FactoryAddressNotSet();
    error FactoryNotDeployed();
    error PauseAuthorityNotSet();
    error OrchestratorAddressMismatch();
    error AccountImplementationAddressMismatch();
    error AccountProxyAddressMismatch();
    error SimulatorAddressMismatch();

    // Salt for deterministic deployments
    bytes32 constant DEPLOYMENT_SALT = keccak256("ithaca.account.v1");

    address public orchestrator;
    address public accountImplementation;
    address public accountProxy;
    address public simulator;

    function run() external {
        vm.startBroadcast();

        // Get factory address from env
        address factoryAddress = vm.envAddress("ITHACA_FACTORY");
        if (factoryAddress == address(0)) revert FactoryAddressNotSet();
        if (factoryAddress.code.length == 0) revert FactoryNotDeployed();

        IthacaFactory factory = IthacaFactory(factoryAddress);

        // Get pause authority from env
        address pauseAuthority = vm.envAddress("PAUSE_AUTHORITY");
        if (pauseAuthority == address(0)) revert PauseAuthorityNotSet();

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
        if (orchestrator != predictedOrchestrator) revert OrchestratorAddressMismatch();
        if (accountImplementation != predictedAccountImpl) {
            revert AccountImplementationAddressMismatch();
        }
        if (accountProxy != predictedAccountProxy) revert AccountProxyAddressMismatch();
        if (simulator != predictedSimulator) revert SimulatorAddressMismatch();

        vm.stopBroadcast();

        // Log deployed addresses
        console.log("\nDeployed contracts:");
        console.log("  Orchestrator:", orchestrator);
        console.log("  Account Implementation:", accountImplementation);
        console.log("  Account Proxy:", accountProxy);
        console.log("  Simulator:", simulator);
    }
}
