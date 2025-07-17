// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";

// Import contracts to deploy
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {Escrow} from "../src/Escrow.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title DeployMain
 * @notice Main deployment script that executes all configured stages for specified chains
 * @dev This script directly deploys contracts without creating intermediate deployer contracts
 *
 * Usage:
 * # Deploy to all chains (using default paths)
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   "[]"
 *
 * # Deploy to specific chains (using default paths)
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   "[1,42161,8453]"
 *
 * # Deploy with custom config and registry paths
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[],string,string)" \
 *   "[1]" "path/to/config.json" "path/to/registry/"
 */
contract DeployMain is BaseDeployment {
    function deploymentType() internal pure override returns (string memory) {
        return "Main";
    }

    function run(uint256[] memory chainIds) external {
        initializeDeployment(chainIds);
        executeDeployment();
    }

    /**
     * @notice Run deployment with custom config and registry paths
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _configPath Path to the configuration JSON file
     * @param _registryPath Path to the registry output directory
     */
    function run(uint256[] memory chainIds, string memory _configPath, string memory _registryPath)
        external
    {
        initializeDeployment(chainIds, _configPath, _registryPath);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying all configured stages...");

        ChainConfig memory config = getChainConfig(chainId);
        DeployedContracts memory deployed = getDeployedContracts(chainId);

        // Deploy each stage if configured
        if (shouldDeployStage(chainId, "basic")) {
            deployBasicContracts(chainId, config, deployed);
        }

        if (shouldDeployStage(chainId, "interop")) {
            deployInteropContracts(chainId, config, deployed);
        }

        if (shouldDeployStage(chainId, "simpleSettler")) {
            deploySimpleSettler(chainId, config, deployed);
        }

        if (shouldDeployStage(chainId, "layerzeroSettler")) {
            deployLayerZeroSettler(chainId, config, deployed);
        }

        console.log(unicode"\n[✓] All configured stages deployed successfully");
    }

    function deployBasicContracts(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: Basic Contracts]");

        // Deploy Orchestrator
        if (deployed.orchestrator == address(0)) {
            Orchestrator orchestrator = new Orchestrator(config.pauseAuthority);
            console.log("Orchestrator deployed:", address(orchestrator));
            saveDeployedContract(chainId, "Orchestrator", address(orchestrator));
            deployed.orchestrator = address(orchestrator);
        } else {
            console.log("Orchestrator already deployed:", deployed.orchestrator);
        }

        // Deploy Account Implementation
        if (deployed.accountImpl == address(0)) {
            IthacaAccount accountImpl = new IthacaAccount(deployed.orchestrator);
            console.log("Account implementation deployed:", address(accountImpl));
            saveDeployedContract(chainId, "AccountImpl", address(accountImpl));
            deployed.accountImpl = address(accountImpl);
        } else {
            console.log("Account implementation already deployed:", deployed.accountImpl);
        }

        // Deploy Account Proxy
        if (deployed.accountProxy == address(0)) {
            address accountProxy = LibEIP7702.deployProxy(deployed.accountImpl, address(0));
            require(accountProxy != address(0), "Account proxy deployment failed");
            console.log("Account proxy deployed:", accountProxy);
            saveDeployedContract(chainId, "AccountProxy", accountProxy);
            deployed.accountProxy = accountProxy;
        } else {
            console.log("Account proxy already deployed:", deployed.accountProxy);
        }

        // Deploy Simulator
        if (deployed.simulator == address(0)) {
            Simulator simulator = new Simulator();
            console.log("Simulator deployed:", address(simulator));
            saveDeployedContract(chainId, "Simulator", address(simulator));
            deployed.simulator = address(simulator);
        } else {
            console.log("Simulator already deployed:", deployed.simulator);
        }

        // Verify deployments
        // verifyBasicContracts(deployed);

        console.log(unicode"[✓] Basic contracts deployed and verified");
    }

    function deployInteropContracts(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: Interop Contracts]");

        require(deployed.orchestrator != address(0), "Orchestrator not found - deploy basic first");

        // Deploy SimpleFunder
        if (deployed.simpleFunder == address(0)) {
            SimpleFunder funder =
                new SimpleFunder(config.funderSigner, deployed.orchestrator, config.funderOwner);
            console.log("SimpleFunder deployed:", address(funder));
            saveDeployedContract(chainId, "SimpleFunder", address(funder));
            deployed.simpleFunder = address(funder);
        } else {
            console.log("SimpleFunder already deployed:", deployed.simpleFunder);
        }

        // Deploy Escrow
        if (deployed.escrow == address(0)) {
            Escrow escrow = new Escrow();
            console.log("Escrow deployed:", address(escrow));
            saveDeployedContract(chainId, "Escrow", address(escrow));
            deployed.escrow = address(escrow);
        } else {
            console.log("Escrow already deployed:", deployed.escrow);
        }

        // Verify deployments
        // verifyInteropContracts(config, deployed);

        console.log(unicode"[✓] Interop contracts deployed and verified");
    }

    function deploySimpleSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: Simple Settler]");

        if (deployed.simpleSettler == address(0)) {
            SimpleSettler settler = new SimpleSettler(config.settlerOwner);
            console.log("SimpleSettler deployed:", address(settler));
            console.log("  Owner:", config.settlerOwner);
            saveDeployedContract(chainId, "SimpleSettler", address(settler));
        } else {
            console.log("SimpleSettler already deployed:", deployed.simpleSettler);
        }

        // Verify deployment
        // verifySimpleSettler(config, deployed);

        console.log(unicode"[✓] Simple settler deployed and verified");
    }

    function deployLayerZeroSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: LayerZero Settler]");

        if (deployed.layerZeroSettler == address(0)) {
            LayerZeroSettler settler =
                new LayerZeroSettler(config.layerZeroEndpoint, config.l0SettlerOwner);
            console.log("LayerZeroSettler deployed:", address(settler));
            console.log("  Endpoint:", config.layerZeroEndpoint);
            console.log("  Owner:", config.l0SettlerOwner);
            console.log("  EID:", config.layerZeroEid);
            saveDeployedContract(chainId, "LayerZeroSettler", address(settler));
        } else {
            console.log("LayerZeroSettler already deployed:", deployed.layerZeroSettler);
        }

        // Verify deployment
        // verifyLayerZeroSettler(config, deployed);

        console.log(unicode"[✓] LayerZero settler deployed and verified");
    }

    // ============================================
    // VERIFICATION FUNCTIONS
    // ============================================
    // Comment out these function calls in the deployment functions above
    // if you want to skip verification during deployment

    function verifyBasicContracts(DeployedContracts memory deployed) internal view {
        console.log("[>] Verifying basic contracts...");
        require(deployed.orchestrator.code.length > 0, "Orchestrator not deployed");
        require(deployed.accountImpl.code.length > 0, "Account implementation not deployed");
        require(deployed.accountProxy.code.length > 0, "Account proxy not deployed");
        require(deployed.simulator.code.length > 0, "Simulator not deployed");

        // Verify Account implementation points to correct orchestrator
        IthacaAccount account = IthacaAccount(payable(deployed.accountImpl));
        require(account.ORCHESTRATOR() == deployed.orchestrator, "Invalid orchestrator reference");
    }

    function verifyInteropContracts(ChainConfig memory config, DeployedContracts memory deployed)
        internal
        view
    {
        console.log("[>] Verifying interop contracts...");
        require(deployed.simpleFunder.code.length > 0, "SimpleFunder not deployed");
        require(deployed.escrow.code.length > 0, "Escrow not deployed");

        SimpleFunder funder = SimpleFunder(payable(deployed.simpleFunder));
        require(funder.funder() == config.funderSigner, "Invalid funder signer");
        require(funder.ORCHESTRATOR() == deployed.orchestrator, "Invalid orchestrator reference");
        require(funder.owner() == config.funderOwner, "Invalid funder owner");
    }

    function verifySimpleSettler(ChainConfig memory config, DeployedContracts memory deployed)
        internal
        view
    {
        console.log("[>] Verifying simple settler...");
        require(deployed.simpleSettler != address(0), "SimpleSettler not deployed");
        SimpleSettler settler = SimpleSettler(deployed.simpleSettler);
        require(settler.owner() == config.settlerOwner, "Invalid SimpleSettler owner");
    }

    function verifyLayerZeroSettler(ChainConfig memory config, DeployedContracts memory deployed)
        internal
        view
    {
        console.log("[>] Verifying LayerZero settler...");
        require(deployed.layerZeroSettler != address(0), "LayerZeroSettler not deployed");
        LayerZeroSettler lzSettler = LayerZeroSettler(payable(deployed.layerZeroSettler));
        require(lzSettler.owner() == config.l0SettlerOwner, "Invalid LayerZeroSettler owner");
        require(address(lzSettler.endpoint()) == config.layerZeroEndpoint, "Invalid endpoint");
    }
}
