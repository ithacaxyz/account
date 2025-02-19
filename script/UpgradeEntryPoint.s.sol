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
        address newImplementation = 0xcaC83d258BAA181b686bA7b3f6FCD0FCF75d5082;
        bytes memory initializeOwnerData = abi.encodeWithSignature("_initializeOwner()", deployer);
        vm.startBroadcast(deployerPrivateKey);
        erc1967Factory.upgradeAndCall(proxy, newImplementation, initializeOwnerData);
        vm.stopBroadcast();
    }
}
