// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";

/**
 * @title DeploySimpleSettler
 * @notice Deploys SimpleSettler contract for single-chain settlement
 * @dev Part of the settlement stage - deploys only if "simpleSettler" is in stages
 *
 * Usage:
 * forge script deploy/DeploySimpleSettler.s.sol:DeploySimpleSettler \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   "[1,42161,8453]"
 */
contract DeploySimpleSettler is BaseDeployment {
    function deploymentType() internal pure override returns (string memory) {
        return "SimpleSettler";
    }

    function run(uint256[] memory chainIds) external {
        initializeDeployment(chainIds);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        // Check if this stage should be deployed
        if (!shouldDeployStage(chainId, "simpleSettler")) {
            console.log("SimpleSettler stage not configured for this chain");
            return;
        }

        console.log("Deploying SimpleSettler...");

        // Get configuration
        ChainConfig memory chainConfig = getChainConfig(chainId);
        DeployedContracts memory existing = getDeployedContracts(chainId);

        if (existing.simpleSettler == address(0)) {
            // Deploy SimpleSettler
            SimpleSettler settler = new SimpleSettler(chainConfig.settlerOwner);
            address settlerAddress = address(settler);

            console.log("SimpleSettler deployed:", settlerAddress);
            console.log("  Owner:", chainConfig.settlerOwner);

            saveDeployedContract(chainId, "SimpleSettler", settlerAddress);
        } else {
            console.log("SimpleSettler already deployed:", existing.simpleSettler);
        }

        // Verify deployment
        verifyDeployment(chainId);

        console.log(unicode"\n[✓] SimpleSettler deployment completed");
    }

    function verifyDeployment(uint256 chainId) internal view {
        DeployedContracts memory deployed = getDeployedContracts(chainId);
        require(deployed.simpleSettler != address(0), "SimpleSettler not deployed");

        // Verify ownership
        SimpleSettler settler = SimpleSettler(deployed.simpleSettler);
        ChainConfig memory chainConfig = getChainConfig(chainId);
        require(settler.owner() == chainConfig.settlerOwner, "Invalid SimpleSettler owner");
    }
}
