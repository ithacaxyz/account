// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {DeployBasic} from "./DeployBasic.s.sol";
import {DeployInterop} from "./DeployInterop.s.sol";
import {DeploySimpleSettler} from "./DeploySimpleSettler.s.sol";
import {DeployLayerZeroSettler} from "./DeployLayerZeroSettler.s.sol";
import {ConfigureLayerZero} from "./ConfigureLayerZero.s.sol";

/**
 * @title DeployAll
 * @notice Master deployment script that runs all configured stages for specified chains
 * @dev Executes deployment stages based on the stages configured for each chain
 *
 * Usage:
 * # Deploy to all chains
 * forge script deploy/DeployAll.s.sol:DeployAll \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   "[]"
 *
 * # Deploy to specific chains
 * forge script deploy/DeployAll.s.sol:DeployAll \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   "[1,42161,8453]"
 */
contract DeployAll is Script {
    // Available stages
    string constant STAGE_BASIC = "basic";
    string constant STAGE_INTEROP = "interop";
    string constant STAGE_SIMPLE_SETTLER = "simpleSettler";
    string constant STAGE_LAYERZERO_SETTLER = "layerzeroSettler";
    string constant STAGE_LAYERZERO_CONFIG = "layerzeroConfig";

    function run(uint256[] memory chainIds) external {
        console.log("\n========================================");
        console.log("Full Deployment Pipeline");
        console.log("========================================");

        // Deploy Basic contracts
        console.log("\n[Stage 1: Basic Contracts]");
        DeployBasic deployBasic = new DeployBasic();
        deployBasic.run(chainIds);

        // Deploy Interop contracts
        console.log("\n[Stage 2: Interoperability Contracts]");
        DeployInterop deployInterop = new DeployInterop();
        deployInterop.run(chainIds);

        // Deploy Simple Settler (if configured)
        console.log("\n[Stage 3a: Simple Settler]");
        DeploySimpleSettler deploySimpleSettler = new DeploySimpleSettler();
        deploySimpleSettler.run(chainIds);

        // Deploy LayerZero Settler (if configured)
        console.log("\n[Stage 3b: LayerZero Settler]");
        DeployLayerZeroSettler deployLayerZeroSettler = new DeployLayerZeroSettler();
        deployLayerZeroSettler.run(chainIds);

        // Configure LayerZero peers (if configured)
        console.log("\n[Stage 4: LayerZero Configuration]");
        ConfigureLayerZero configureLayerZero = new ConfigureLayerZero();
        configureLayerZero.run(chainIds);

        console.log("\n========================================");
        console.log("Full Deployment Complete");
        console.log("========================================");
    }
}
