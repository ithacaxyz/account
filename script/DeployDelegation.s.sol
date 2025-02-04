// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/Delegation.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ERC1967FactoryConstants} from "solady/utils/ERC1967FactoryConstants.sol";

contract DeployDelegationScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.createWallet(deployerPrivateKey).addr;
        ERC1967Factory erc1967Factory = ERC1967Factory(ERC1967FactoryConstants.ADDRESS);
        address implementation = 0x2F1114bF790f7115822F1aAEF740A74Ffe19A0aC;
        bytes32 salt = bytes32(uint256(1));
        vm.startBroadcast(deployerPrivateKey);
        erc1967Factory.deployDeterministic(implementation, deployer, salt);
        vm.stopBroadcast();
    }
}
