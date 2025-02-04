// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/Delegation.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ERC1967FactoryConstants} from "solady/utils/ERC1967FactoryConstants.sol";

contract UpgradeDelegationScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.createWallet(deployerPrivateKey).addr;
        ERC1967Factory erc1967Factory = ERC1967Factory(ERC1967FactoryConstants.ADDRESS);
        address proxy = 0x7DFc6Ae9c532EC324Ecd5ce027c425767fcDa757;
        address newImplementation = 0xEC90b0d19f7CA925445cbBaA85F90958C60501A1;
        vm.startBroadcast(deployerPrivateKey);
        erc1967Factory.upgradeAndCall(proxy, newImplementation, "");
        vm.stopBroadcast();
    }
}
