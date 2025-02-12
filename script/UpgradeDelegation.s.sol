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
        address newImplementation = 0x9C4F6D8c0d7AEF8BC997cbac908F1c6166Ce4D13;
        vm.startBroadcast(deployerPrivateKey);
        IEIP7702ProxyWithAdminABI(proxy).upgrade(newImplementation);
        vm.stopBroadcast();
    }
}
