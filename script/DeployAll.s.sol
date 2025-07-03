// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";

contract DeployAllScript is Script {
    address public orchestrator;
    address public accountImplementation;
    address public accountProxy;
    address public simulator;
    address public funder;

    function run() external {
        vm.startBroadcast();
        address pauseAuthority = vm.envAddress("PAUSE_AUTHORITY");
        orchestrator = address(new Orchestrator(pauseAuthority));
        accountImplementation = address(new IthacaAccount(address(orchestrator)));
        accountProxy = LibEIP7702.deployProxy(accountImplementation, address(0));
        simulator = address(new Simulator());
        funder = address(
            new SimpleFunder(
                vm.envAddress("FUNDER"), address(orchestrator), vm.envAddress("FUNDER_OWNER")
            )
        );

        vm.stopBroadcast();
    }
}
