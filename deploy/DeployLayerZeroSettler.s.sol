// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title DeployLayerZeroSettler
 * @notice Deploys LayerZeroSettler contract for cross-chain settlement
 * @dev Part of the settlement stage - deploys only if "layerzeroSettler" is in stages
 *
 * Usage:
 * forge script deploy/DeployLayerZeroSettler.s.sol:DeployLayerZeroSettler \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   "[1,42161,8453]"
 */
contract DeployLayerZeroSettler is BaseDeployment {
    function deploymentType() internal pure override returns (string memory) {
        return "LayerZeroSettler";
    }

    function run(uint256[] memory chainIds) external {
        initializeDeployment(chainIds);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        // Check if this stage should be deployed
        if (!shouldDeployStage(chainId, "layerzeroSettler")) {
            console.log("LayerZeroSettler stage not configured for this chain");
            return;
        }

        console.log("Deploying LayerZeroSettler...");

        // Get configuration
        ChainConfig memory chainConfig = getChainConfig(chainId);
        DeployedContracts memory existing = getDeployedContracts(chainId);

        if (existing.layerZeroSettler == address(0)) {
            // Deploy LayerZeroSettler
            LayerZeroSettler settler =
                new LayerZeroSettler(chainConfig.layerZeroEndpoint, chainConfig.l0SettlerOwner);
            address settlerAddress = address(settler);

            console.log("LayerZeroSettler deployed:", settlerAddress);
            console.log("  Endpoint:", chainConfig.layerZeroEndpoint);
            console.log("  Owner:", chainConfig.l0SettlerOwner);
            console.log("  EID:", chainConfig.layerZeroEid);

            saveDeployedContract(chainId, "LayerZeroSettler", settlerAddress);
        } else {
            console.log("LayerZeroSettler already deployed:", existing.layerZeroSettler);
        }

        // Verify deployment
        verifyDeployment(chainId);

        console.log(unicode"\n[✓] LayerZeroSettler deployment completed");
        console.log("[!] Remember to run LayerZeroConfig to set up cross-chain peers");
    }

    function verifyDeployment(uint256 chainId) internal view {
        DeployedContracts memory deployed = getDeployedContracts(chainId);
        require(deployed.layerZeroSettler != address(0), "LayerZeroSettler not deployed");

        // Verify configuration
        LayerZeroSettler settler = LayerZeroSettler(payable(deployed.layerZeroSettler));
        ChainConfig memory chainConfig = getChainConfig(chainId);

        require(settler.owner() == chainConfig.l0SettlerOwner, "Invalid LayerZeroSettler owner");
        require(address(settler.endpoint()) == chainConfig.layerZeroEndpoint, "Invalid endpoint");
    }
}
