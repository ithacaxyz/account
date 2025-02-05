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
        address implementation = 0x4Ee65f4CEd87Ff98fd40627Ac19C159E99C9D295;
        vm.startBroadcast(deployerPrivateKey);
        new EIP7702Proxy{salt: bytes32(0)}(implementation, deployer);
        vm.stopBroadcast();
    }
}
