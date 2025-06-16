// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {SafeSingletonDeployer} from "safe-singleton-deployer-sol/SafeSingletonDeployer.sol";
import {IthacaFactory} from "../src/IthacaFactory.sol";

contract DeployFactoryScript is Script {
    using SafeSingletonDeployer for bytes;

    address constant expectedFactoryAddress = 0x0000000000FFe8B47B3e2130213B802212439497;
    bytes32 constant factorySalt =
        0x0000000000000000000000000000000000000000000000000000000000000001;

    function run() external returns (address factory) {
        vm.startBroadcast();

        // Deploy the factory using Safe Singleton Deployer
        bytes memory factoryCreationCode = type(IthacaFactory).creationCode;

        // Compute expected address
        address predicted = factoryCreationCode.computeAddress(factorySalt);

        // Deploy factory
        factory = factoryCreationCode.broadcastDeploy(factorySalt);

        // Verify deployment
        require(factory == predicted, "Factory deployed to unexpected address");
        require(factory.code.length > 0, "Factory deployment failed");

        vm.stopBroadcast();

        // Log the deployed factory address
        console.log("IthacaFactory deployed to:", factory);
    }
}
