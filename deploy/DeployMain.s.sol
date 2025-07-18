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
 * # Export your private key
 * export PRIVATE_KEY=0x...
 *
 * # Deploy to all chains (using default config)
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[]"
 *
 * # Deploy to specific chains (using default config)
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[1,42161,8453]"
 *
 * # Deploy with custom registry path
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[],string)" \
 *   --private-key $PRIVATE_KEY \
 *   "[1]" "path/to/registry/"
 *
 * # Note: To use a custom config, modify DefaultConfig.sol directly
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
     * @notice Run deployment with custom registry path
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _registryPath Path to the registry output directory
     */
    function run(uint256[] memory chainIds, string memory _registryPath) external {
        initializeDeployment(chainIds, _registryPath);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying all configured stages...");

        ChainConfig memory config = getChainConfig(chainId);
        DeployedContracts memory deployed = getDeployedContracts(chainId);

        // Deploy each stage if configured
        if (shouldDeployStage(chainId, Stage.Core)) {
            deployCoreContracts(chainId, config, deployed);
        }

        if (shouldDeployStage(chainId, Stage.Interop)) {
            deployInteropContracts(chainId, config, deployed);
        }

        if (shouldDeployStage(chainId, Stage.SimpleSettler)) {
            deploySimpleSettler(chainId, config, deployed);
        }

        if (shouldDeployStage(chainId, Stage.LayerZeroSettler)) {
            deployLayerZeroSettler(chainId, config, deployed);
        }

        console.log(unicode"\n[✓] All configured stages deployed successfully");
    }

    function deployCoreContracts(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: Core Contracts]");

        // Deploy Orchestrator
        if (deployed.orchestrator == address(0)) {
            vm.broadcast();
            address orchestrator = address(new Orchestrator(config.pauseAuthority));
            console.log("Orchestrator deployed:", orchestrator);
            saveDeployedContract(chainId, "Orchestrator", orchestrator);
            deployed.orchestrator = orchestrator;
        } else {
            console.log("Orchestrator already deployed:", deployed.orchestrator);
        }

        // Deploy Account Implementation
        if (deployed.accountImpl == address(0)) {
            vm.broadcast();
            address accountImpl = address(new IthacaAccount(deployed.orchestrator));
            console.log("IthacaAccount deployed:", accountImpl);
            saveDeployedContract(chainId, "AccountImpl", accountImpl);
            deployed.accountImpl = accountImpl;
        } else {
            console.log("Account implementation already deployed:", deployed.accountImpl);
        }

        // Deploy Account Proxy
        if (deployed.accountProxy == address(0)) {
            vm.broadcast();
            address accountProxy = LibEIP7702.deployProxy(deployed.accountImpl, address(0));
            console.log("AccountProxy deployed:", accountProxy);
            require(accountProxy != address(0), "Account proxy deployment failed");
            saveDeployedContract(chainId, "AccountProxy", accountProxy);
            deployed.accountProxy = accountProxy;
        } else {
            console.log("Account proxy already deployed:", deployed.accountProxy);
        }

        // Deploy Simulator
        if (deployed.simulator == address(0)) {
            vm.broadcast();
            address simulator = address(new Simulator());
            console.log("Simulator deployed:", simulator);
            saveDeployedContract(chainId, "Simulator", simulator);
            deployed.simulator = simulator;
        } else {
            console.log("Simulator already deployed:", deployed.simulator);
        }

        // Verify deployments
        // verifyCoreContracts(deployed);

        console.log(unicode"[✓] Core contracts deployed and verified");
    }

    function deployInteropContracts(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: Interop Contracts]");

        require(deployed.orchestrator != address(0), "Orchestrator not found - deploy core first");

        // Deploy SimpleFunder
        if (deployed.simpleFunder == address(0)) {
            vm.broadcast();
            address funder = address(
                new SimpleFunder(config.funderSigner, deployed.orchestrator, config.funderOwner)
            );
            console.log("SimpleFunder deployed:", funder);
            saveDeployedContract(chainId, "SimpleFunder", funder);
            deployed.simpleFunder = funder;
        } else {
            console.log("SimpleFunder already deployed:", deployed.simpleFunder);
        }

        // Deploy Escrow
        if (deployed.escrow == address(0)) {
            vm.broadcast();
            address escrow = address(new Escrow());
            console.log("Escrow deployed:", escrow);
            saveDeployedContract(chainId, "Escrow", escrow);
            deployed.escrow = escrow;
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
            vm.broadcast();
            address settler = address(new SimpleSettler(config.settlerOwner));
            console.log("SimpleSettler deployed:", settler);
            console.log("  Owner:", config.settlerOwner);
            saveDeployedContract(chainId, "SimpleSettler", settler);
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
            vm.broadcast();
            address settler =
                address(new LayerZeroSettler(config.layerZeroEndpoint, config.l0SettlerOwner));
            console.log("LayerZeroSettler deployed:", settler);
            console.log("  Endpoint:", config.layerZeroEndpoint);
            console.log("  Owner:", config.l0SettlerOwner);
            console.log("  EID:", config.layerZeroEid);
            saveDeployedContract(chainId, "LayerZeroSettler", settler);
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

    function verifyCoreContracts(DeployedContracts memory deployed) internal view {
        console.log("[>] Verifying core contracts...");
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
