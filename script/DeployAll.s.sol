// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";
import {Escrow} from "../src/Escrow.sol";

contract DeployAllScript is Script {
    address public orchestrator;
    address public accountImplementation;
    address public accountProxy;
    address public simulator;
    address public funder;
    address public simpleSettler;
    address public escrow;

    function run() external {
        vm.startBroadcast();
        orchestrator = address(new Orchestrator());
        accountImplementation = address(new IthacaAccount(address(orchestrator)));
        accountProxy = LibEIP7702.deployProxy(accountImplementation, address(0));
        simulator = address(new Simulator());
        funder = address(
            new SimpleFunder(
                vm.envAddress("FUNDER"), address(orchestrator), vm.envAddress("FUNDER_OWNER")
            )
        );
        simpleSettler = address(new SimpleSettler(vm.envAddress("SETTLER_OWNER")));
        escrow = address(new Escrow());

        vm.stopBroadcast();
    }
}
