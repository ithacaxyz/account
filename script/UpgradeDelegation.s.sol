// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/Delegation.sol";

interface IEIP7702ProxyWithAdminABI {
    function implementation() external view returns (address);
    function admin() external view returns (address);
    function changeAdmin(address) external returns (bool);
    function upgrade(address) external returns (bool);
    function bad() external;
}

contract UpgradeDelegationScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // address deployer = vm.createWallet(deployerPrivateKey).addr;
        address proxy = 0xF9a8529Bb95ac7707129700f06343338E4767A27;
        address newImplementation = 0x23165b46bee38d6FeCfC50f57c29F1035cA10B0F;
        vm.startBroadcast(deployerPrivateKey);
        IEIP7702ProxyWithAdminABI(proxy).upgrade(newImplementation);
        vm.stopBroadcast();
    }
}
