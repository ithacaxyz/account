// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import "../src/EntryPoint.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {ERC1967FactoryConstants} from "solady/utils/ERC1967FactoryConstants.sol";

contract UpgradeEntryPointScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.createWallet(deployerPrivateKey).addr;
        ERC1967Factory erc1967Factory = ERC1967Factory(ERC1967FactoryConstants.ADDRESS);
        address proxy = 0x307AF7d28AfEE82092aA95D35644898311CA5360;
        address newImplementation = 0x417C61a18f3e89fD27A073f3351De6783D182860;
        bytes memory initializeOwnerData = abi.encodeWithSignature("_initializeOwner()", deployer);
        vm.startBroadcast(deployerPrivateKey);
        erc1967Factory.upgradeAndCall(proxy, newImplementation, "");
        vm.stopBroadcast();
    }
}
