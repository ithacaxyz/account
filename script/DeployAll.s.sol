// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/DeployAll.sol";

contract DeployAllScript is Script {
    function run() external {
        address pauseAuthority = vm.envOr("PAUSE_AUTHORITY", msg.sender);
        vm.startBroadcast();
        new DeployAll(pauseAuthority);
        vm.stopBroadcast();
    }
}
