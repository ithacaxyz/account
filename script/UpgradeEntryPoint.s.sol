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
        address newImplementation = 0x904176a23Ca0C5Cc7e796F754Be809d57a129E30;
        vm.startBroadcast(deployerPrivateKey);
        erc1967Factory.upgradeAndCall(
            proxy, newImplementation, abi.encodeWithSignature("_initializeOwner()", deployer)
        );
        vm.stopBroadcast();
    }
}
