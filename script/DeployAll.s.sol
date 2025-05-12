// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import "../src/DeployAll.sol";

contract DeployAllScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bool shouldWrite = vm.envOr("SAVE_DEPLOY", false);

        vm.startBroadcast(deployerPrivateKey);
        DeployAll deployer = new DeployAll();
        vm.stopBroadcast();

        address entryPoint = deployer.entryPoint();
        address delegation = deployer.delegationImplementation();
        address proxy = deployer.delegationProxy();
        address registry = deployer.accountRegistry();
        address simulator = deployer.simulator();
        address pauseAuthority = vm.addr(deployerPrivateKey);

        if (shouldWrite) {
            string memory contractsJson = string.concat(
                '{"EntryPoint":"',
                vm.toString(entryPoint),
                '","Delegation":"',
                vm.toString(delegation),
                '","EIP7702Proxy":"',
                vm.toString(proxy),
                '","AccountRegistry":"',
                vm.toString(registry),
                '","Simulator":"',
                vm.toString(simulator),
                '","PauseAuthority":"',
                vm.toString(pauseAuthority),
                '"}'
            );

            string memory finalJson = string.concat(
                '{"chainId":', vm.toString(block.chainid), ',"contracts":', contractsJson, "}"
            );

            vm.writeFile("deployments.json", finalJson);
        }
    }
}
