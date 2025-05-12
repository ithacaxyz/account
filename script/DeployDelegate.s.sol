// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import "../src/DeployDelegate.sol";

contract DeployDelegateScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bool shouldWrite = vm.envOr("SAVE_DEPLOY", false);

        string memory json = vm.readFile("deployments.json");
        string memory chainId = vm.toString(block.chainid);
        address entryPoint = vm.parseJsonAddress(json, ".contracts.EntryPoint");

        vm.startBroadcast(deployerPrivateKey);
        DeployDelegate deploy = new DeployDelegate(entryPoint);
        vm.stopBroadcast();

        if (shouldWrite) {
            string memory entryPointAddr = vm.parseJsonString(json, ".contracts.EntryPoint");
            string memory delegationAddr = vm.toString(deploy.delegationImplementation());
            string memory proxyAddr = vm.toString(deploy.delegationProxy());
            string memory registryAddr = vm.parseJsonString(json, ".contracts.AccountRegistry");
            string memory simulatorAddr = vm.parseJsonString(json, ".contracts.Simulator");
            string memory pauseAuthority = vm.parseJsonString(json, ".contracts.PauseAuthority");
            string memory contractsJson = string.concat(
                '{\n  "EntryPoint": "',
                entryPointAddr,
                '",\n  "Delegation": "',
                delegationAddr,
                '",\n  "EIP7702Proxy": "',
                proxyAddr,
                '",\n  "AccountRegistry": "',
                registryAddr,
                '",\n  "Simulator": "',
                simulatorAddr,
                '",\n  "PauseAuthority": "',
                pauseAuthority,
                '"\n}'
            );

            string memory finalJson = string.concat(
                '{\n  "chainId": ', chainId, ',\n  "contracts": ', contractsJson, "\n}"
            );

            vm.writeFile("deployments.json", finalJson);
        }
    }
}
