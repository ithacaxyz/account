// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/Delegation.sol";
import {EIP7702Proxy} from "solady/accounts/EIP7702Proxy.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ERC1967FactoryConstants} from "solady/utils/ERC1967FactoryConstants.sol";

contract DeployDelegationScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.createWallet(deployerPrivateKey).addr;
        address implementation = 0x23165b46bee38d6FeCfC50f57c29F1035cA10B0F;
        vm.startBroadcast(deployerPrivateKey);
        new EIP7702Proxy{salt: bytes32(0)}(implementation, deployer);
        vm.stopBroadcast();
    }
}
