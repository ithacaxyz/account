// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeploymentToml} from "./BaseDeploymentToml.sol";
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
 * @title DeployMainToml
 * @notice Main deployment script using TOML configuration
 * @dev Reads configuration from deploy/config.toml instead of Solidity config contracts
 *
 * Usage:
 * # Deploy to all chains in config.toml
 * forge script deploy/DeployMainToml.s.sol:DeployMainToml \
 *   --broadcast \
 *   --sig "run()" \
 *   --private-key $PRIVATE_KEY
 *
 * # Deploy to specific chains
 * forge script deploy/DeployMainToml.s.sol:DeployMainToml \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[1,42161,8453]"
 *
 * # Deploy with custom config file
 * forge script deploy/DeployMainToml.s.sol:DeployMainToml \
 *   --broadcast \
 *   --sig "run(uint256[],string)" \
 *   --private-key $PRIVATE_KEY \
 *   "[1]" "/deploy/custom-config.toml"
 */
contract DeployMainToml is BaseDeploymentToml {
    function deploymentType() internal pure override returns (string memory) {
        return "Main";
    }

    /**
     * @notice Deploy to all chains in config
     */
    function run() external {
        uint256[] memory chainIds = new uint256[](0); // Empty array = all chains
        initializeDeployment(chainIds);
        executeDeployment();
    }

    /**
     * @notice Deploy to specific chains
     * @param chainIds Array of chain IDs to deploy to
     */
    function run(uint256[] memory chainIds) external {
        initializeDeployment(chainIds);
        executeDeployment();
    }

    /**
     * @notice Deploy with custom config file
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _configPath Path to custom TOML config file
     */
    function run(uint256[] memory chainIds, string memory _configPath) external {
        initializeDeployment(chainIds, _configPath);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying all configured stages from TOML config...");

        // Verify Safe Singleton Factory if CREATE2 is needed
        verifySafeSingletonFactory(chainId);

        ChainConfig memory config = getChainConfig(chainId);
        DeployedContracts memory deployed = getDeployedContracts(chainId);

        // Warning for CREATE2 deployments
        if (config.salt != bytes32(0)) {
            console.log(unicode"\n⚠️  CREATE2 DEPLOYMENT - SAVE YOUR SALT!");
            console.log("Salt:", vm.toString(config.salt));
            console.log("This salt is REQUIRED to deploy to same addresses on new chains");
            console.log(unicode"Store it securely with backups!\n");
        }

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
            bytes memory creationCode = type(Orchestrator).creationCode;
            bytes memory args = abi.encode(config.pauseAuthority);
            address orchestrator = deployContract(chainId, creationCode, args, "Orchestrator");

            saveDeployedContract(chainId, "Orchestrator", orchestrator);
            deployed.orchestrator = orchestrator;
        } else {
            console.log("Orchestrator already deployed:", deployed.orchestrator);
        }

        // Deploy Account Implementation
        if (deployed.accountImpl == address(0)) {
            bytes memory creationCode = type(IthacaAccount).creationCode;
            bytes memory args = abi.encode(deployed.orchestrator);
            address accountImpl = deployContract(chainId, creationCode, args, "IthacaAccount");

            saveDeployedContract(chainId, "AccountImpl", accountImpl);
            deployed.accountImpl = accountImpl;
        } else {
            console.log("Account implementation already deployed:", deployed.accountImpl);
        }

        // Deploy Account Proxy
        if (deployed.accountProxy == address(0)) {
            bytes memory proxyCode = LibEIP7702.proxyInitCode(deployed.accountImpl, address(0));
            address accountProxy = deployContract(chainId, proxyCode, "", "AccountProxy");

            require(accountProxy != address(0), "Account proxy deployment failed");
            saveDeployedContract(chainId, "AccountProxy", accountProxy);
            deployed.accountProxy = accountProxy;
        } else {
            console.log("Account proxy already deployed:", deployed.accountProxy);
        }

        // Deploy Simulator
        if (deployed.simulator == address(0)) {
            bytes memory creationCode = type(Simulator).creationCode;
            address simulator = deployContract(chainId, creationCode, "", "Simulator");

            saveDeployedContract(chainId, "Simulator", simulator);
            deployed.simulator = simulator;
        } else {
            console.log("Simulator already deployed:", deployed.simulator);
        }

        console.log(unicode"[✓] Core contracts deployed");
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
            bytes memory creationCode = type(SimpleFunder).creationCode;
            bytes memory args =
                abi.encode(config.funderSigner, deployed.orchestrator, config.funderOwner);
            address funder = deployContract(chainId, creationCode, args, "SimpleFunder");

            saveDeployedContract(chainId, "SimpleFunder", funder);
            deployed.simpleFunder = funder;
        } else {
            console.log("SimpleFunder already deployed:", deployed.simpleFunder);
        }

        // Deploy Escrow
        if (deployed.escrow == address(0)) {
            bytes memory creationCode = type(Escrow).creationCode;
            address escrow = deployContract(chainId, creationCode, "", "Escrow");

            saveDeployedContract(chainId, "Escrow", escrow);
            deployed.escrow = escrow;
        } else {
            console.log("Escrow already deployed:", deployed.escrow);
        }

        console.log(unicode"[✓] Interop contracts deployed");
    }

    function deploySimpleSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: Simple Settler]");

        if (deployed.simpleSettler == address(0)) {
            bytes memory creationCode = type(SimpleSettler).creationCode;
            bytes memory args = abi.encode(config.settlerOwner);
            address settler = deployContract(chainId, creationCode, args, "SimpleSettler");

            console.log("  Owner:", config.settlerOwner);
            saveDeployedContract(chainId, "SimpleSettler", settler);
        } else {
            console.log("SimpleSettler already deployed:", deployed.simpleSettler);
        }

        console.log(unicode"[✓] Simple settler deployed");
    }

    function deployLayerZeroSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        console.log("\n[Stage: LayerZero Settler]");

        if (deployed.layerZeroSettler == address(0)) {
            bytes memory creationCode = type(LayerZeroSettler).creationCode;
            bytes memory args = abi.encode(config.layerZeroEndpoint, config.l0SettlerOwner);
            address settler = deployContract(chainId, creationCode, args, "LayerZeroSettler");

            console.log("  Endpoint:", config.layerZeroEndpoint);
            console.log("  Owner:", config.l0SettlerOwner);
            console.log("  EID:", config.layerZeroEid);
            saveDeployedContract(chainId, "LayerZeroSettler", settler);
        } else {
            console.log("LayerZeroSettler already deployed:", deployed.layerZeroSettler);
        }

        console.log(unicode"[✓] LayerZero settler deployed");
    }
}
