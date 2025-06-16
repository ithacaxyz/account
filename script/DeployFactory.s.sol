// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {SafeSingletonDeployer} from "safe-singleton-deployer-sol/SafeSingletonDeployer.sol";
import {IthacaFactory} from "../src/IthacaFactory.sol";

contract DeployFactoryScript is Script {
    using SafeSingletonDeployer for bytes;

    // Custom errors
    error FactoryDeployedToUnexpectedAddress();
    error FactoryDeploymentFailed();

    // Use a deterministic salt for the factory deployment
    bytes32 constant FACTORY_SALT = keccak256("ithaca.factory.v1");

    function run() external returns (address factory) {
        vm.startBroadcast();

        // Deploy the factory using Safe Singleton Deployer
        bytes memory factoryCreationCode = type(IthacaFactory).creationCode;

        // Compute expected address
        address predicted = factoryCreationCode.computeAddress(FACTORY_SALT);

        console.log("Predicted factory address:", predicted);

        // Check if factory is already deployed
        if (predicted.code.length > 0) {
            console.log("Factory already deployed at:", predicted);
            factory = predicted;
        } else {
            // Deploy factory via Safe Singleton Factory
            factory = factoryCreationCode.broadcastDeploy(FACTORY_SALT);
            console.log("Factory deployed to:", factory);
        }

        // Verify deployment
        if (factory != predicted) revert FactoryDeployedToUnexpectedAddress();
        if (factory.code.length == 0) revert FactoryDeploymentFailed();

        vm.stopBroadcast();
    }
}
