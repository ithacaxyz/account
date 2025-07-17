// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {Escrow} from "../src/Escrow.sol";

/**
 * @title DeployInterop
 * @notice Deploys interoperability contracts: SimpleFunder and Escrow
 * @dev Second stage of deployment - depends on Basic contracts being deployed first
 *
 * Usage:
 * forge script deploy/DeployInterop.s.sol:DeployInterop \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "mainnet"
 */
contract DeployInterop is BaseDeployment {
    using stdJson for string;

    function deploymentType() internal pure override returns (string memory) {
        return "Interop";
    }

    function run(uint256[] memory chainIds) external {
        initializeDeployment(chainIds);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        // Check if this stage should be deployed
        if (!shouldDeployStage(chainId, "interop")) {
            console.log("Interop stage not configured for this chain");
            return;
        }

        console.log("Deploying interoperability contracts...");

        // Get configuration
        ChainConfig memory chainConfig = getChainConfig(chainId);
        DeployedContracts memory existing = getDeployedContracts(chainId);

        // Verify dependencies
        require(
            existing.orchestrator != address(0), "Orchestrator not found - run DeployBasic first"
        );

        // Deploy SimpleFunder
        if (existing.simpleFunder == address(0)) {
            address simpleFunder = deploySimpleFunder(
                chainConfig.funderSigner, existing.orchestrator, chainConfig.funderOwner
            );
            console.log("SimpleFunder deployed:", simpleFunder);
            saveDeployedContract(chainId, "SimpleFunder", simpleFunder);
        } else {
            console.log("SimpleFunder already deployed:", existing.simpleFunder);
        }

        // Deploy Escrow
        if (existing.escrow == address(0)) {
            address escrow = deployEscrow();
            console.log("Escrow deployed:", escrow);
            saveDeployedContract(chainId, "Escrow", escrow);
        } else {
            console.log("Escrow already deployed:", existing.escrow);
        }

        // Verify deployments
        verifyDeployments(chainId);

        console.log(unicode"\n[✓] Interop contracts deployment completed");
    }

    function deploySimpleFunder(address funderSigner, address orchestrator, address funderOwner)
        internal
        returns (address)
    {
        SimpleFunder funder = new SimpleFunder(funderSigner, orchestrator, funderOwner);
        return address(funder);
    }

    function deployEscrow() internal returns (address) {
        Escrow escrow = new Escrow();
        return address(escrow);
    }

    function verifyDeployments(uint256 chainId) internal view {
        console.log("\n[>] Verifying deployments...");

        DeployedContracts memory contracts = getDeployedContracts(chainId);
        ChainConfig memory chainConfig = getChainConfig(chainId);

        // Verify SimpleFunder
        require(contracts.simpleFunder.code.length > 0, "SimpleFunder not deployed");
        SimpleFunder funder = SimpleFunder(payable(contracts.simpleFunder));
        require(funder.funder() == chainConfig.funderSigner, "Invalid funder signer");
        require(funder.ORCHESTRATOR() == contracts.orchestrator, "Invalid orchestrator reference");
        require(funder.owner() == chainConfig.funderOwner, "Invalid funder owner");

        // Verify Escrow
        require(contracts.escrow.code.length > 0, "Escrow not deployed");

        console.log(unicode"[✓] All verifications passed");
    }
}
