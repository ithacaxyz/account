// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/EntryPoint.sol";

contract DeployEntryPointImplementationScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        new EntryPoint{salt: bytes32(0)}();
        vm.stopBroadcast();
    }
}
