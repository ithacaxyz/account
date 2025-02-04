// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/EntryPoint.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ERC1967FactoryConstants} from "solady/utils/ERC1967FactoryConstants.sol";

contract DeployEntryPointScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.createWallet(deployerPrivateKey).addr;
        ERC1967Factory erc1967Factory = ERC1967Factory(ERC1967FactoryConstants.ADDRESS);
        address implementation = 0x7448A2968DbC7ae0104711bbd7b6921380612653;
        bytes32 salt = bytes32(0);
        vm.startBroadcast(deployerPrivateKey);
        erc1967Factory.deployDeterministic(implementation, deployer, salt);
        vm.stopBroadcast();
    }
}
