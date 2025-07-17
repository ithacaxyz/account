// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {Escrow} from "../src/Escrow.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";

/**
 * @title DeployDevnetComplete
 * @notice Complete deployment script for Porto devnet with embedded configuration
 * @dev This demonstrates how a dry run would look on the Porto devnet
 */
contract DeployDevnetComplete is Script {
    // Devnet configuration
    uint256 constant PORTO_DEVNET_CHAIN_ID = 28404;
    string constant RPC_URL = "https://porto-dev.rpc.ithaca.xyz/";

    // Deployment configuration
    address constant PAUSE_AUTHORITY = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;
    address constant FUNDER_SIGNER = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;
    address constant FUNDER_OWNER = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;
    address constant SETTLER_OWNER = 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf;

    // Deployed contract addresses (will be populated during deployment)
    struct DeployedContracts {
        // Basic contracts
        address orchestrator;
        address accountImplementation;
        address accountProxy;
        address simulator;
        // Interop contracts
        address simpleFunder;
        address escrow;
        // Settlement contracts
        address settler;
    }

    DeployedContracts deployed;

    function run() external {
        console.log("\n=====================================");
        console.log("   PORTO DEVNET DEPLOYMENT");
        console.log("=====================================");
        console.log("Chain ID:", PORTO_DEVNET_CHAIN_ID);
        console.log("RPC URL:", RPC_URL);
        console.log("Dry Run: true");
        console.log("");

        // Stage 1: Deploy Basic Contracts
        console.log("\n[STAGE 1] Deploying Basic Contracts...");
        deployBasicContracts();

        // Stage 2: Deploy Interop Contracts
        console.log("\n[STAGE 2] Deploying Interop Contracts...");
        deployInteropContracts();

        // Stage 3: Deploy Settlement Contracts
        console.log("\n[STAGE 3] Deploying Settlement Contracts...");
        deploySettlementContracts();

        // Summary
        printDeploymentSummary();
    }

    function deployBasicContracts() internal {
        vm.startBroadcast();

        // Deploy Orchestrator
        Orchestrator orchestrator = new Orchestrator(PAUSE_AUTHORITY);
        deployed.orchestrator = address(orchestrator);
        console.log("  Orchestrator deployed:", deployed.orchestrator);

        // Deploy IthacaAccount implementation
        IthacaAccount implementation = new IthacaAccount(deployed.orchestrator);
        deployed.accountImplementation = address(implementation);
        console.log("  Account implementation deployed:", deployed.accountImplementation);

        // Deploy account proxy
        deployed.accountProxy = LibEIP7702.deployProxy(deployed.accountImplementation, address(0));
        console.log("  Account proxy deployed:", deployed.accountProxy);

        // Deploy Simulator
        Simulator simulator = new Simulator();
        deployed.simulator = address(simulator);
        console.log("  Simulator deployed:", deployed.simulator);

        vm.stopBroadcast();

        console.log(unicode"  ✓ Basic contracts deployment completed");
    }

    function deployInteropContracts() internal {
        vm.startBroadcast();

        // Deploy SimpleFunder
        SimpleFunder funder = new SimpleFunder(FUNDER_SIGNER, deployed.orchestrator, FUNDER_OWNER);
        deployed.simpleFunder = address(funder);
        console.log("  SimpleFunder deployed:", deployed.simpleFunder);

        // Deploy Escrow
        Escrow escrow = new Escrow();
        deployed.escrow = address(escrow);
        console.log("  Escrow deployed:", deployed.escrow);

        vm.stopBroadcast();

        console.log(unicode"  ✓ Interop contracts deployment completed");
    }

    function deploySettlementContracts() internal {
        vm.startBroadcast();

        // Deploy SimpleSettler (for devnet)
        SimpleSettler settler = new SimpleSettler(SETTLER_OWNER);
        deployed.settler = address(settler);
        console.log("  SimpleSettler deployed:", deployed.settler);

        vm.stopBroadcast();

        console.log(unicode"  ✓ Settlement contracts deployment completed");
    }

    function printDeploymentSummary() internal view {
        console.log("\n=====================================");
        console.log("   DEPLOYMENT SUMMARY");
        console.log("=====================================");
        console.log("\nBasic Contracts:");
        console.log("  Orchestrator:     ", deployed.orchestrator);
        console.log("  Implementation:   ", deployed.accountImplementation);
        console.log("  Proxy:           ", deployed.accountProxy);
        console.log("  Simulator:       ", deployed.simulator);

        console.log("\nInterop Contracts:");
        console.log("  SimpleFunder:    ", deployed.simpleFunder);
        console.log("  Escrow:          ", deployed.escrow);

        console.log("\nSettlement Contracts:");
        console.log("  Settler:         ", deployed.settler);

        console.log("\n=====================================");
        console.log(unicode"   ✓ ALL DEPLOYMENTS COMPLETE");
        console.log("=====================================");

        // Estimated costs
        console.log("\nEstimated Deployment Costs:");
        console.log("  Total contracts: 7");
        console.log("  Estimated gas: ~10M gas units");
        console.log("  At 0.5 gwei: ~0.005 ETH");

        console.log("\nNext Steps:");
        console.log("  1. Fund the deployer address with ETH");
        console.log("  2. Run with --broadcast to execute");
        console.log("  3. Verify contracts on explorer");
    }
}
