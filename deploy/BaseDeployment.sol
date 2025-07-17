// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SafeSingletonDeployer} from "./SafeSingletonDeployer.sol";

/**
 * @title BaseDeployment
 * @notice Base contract for all deployment scripts with unified JSON configuration
 * @dev Provides simplified configuration management using Foundry's JSON parsing
 */
abstract contract BaseDeployment is Script, SafeSingletonDeployer {
    using stdJson for string;

    // Unified configuration struct (alphabetically ordered for JSON parsing)
    struct ChainConfig {
        address funderOwner;
        address funderSigner;
        bool isTestnet;
        address l0SettlerOwner;
        address layerZeroEndpoint;
        uint32 layerZeroEid;
        string name;
        address pauseAuthority;
        bytes32 salt;
        address settlerOwner;
        string[] stages;
    }

    struct DeployedContracts {
        address accountImpl;
        address accountProxy;
        address escrow;
        address orchestrator;
        address simpleSettler;
        address layerZeroSettler;
        address simpleFunder;
        address simulator;
    }

    // State
    mapping(uint256 => ChainConfig) internal chainConfigs;
    mapping(uint256 => DeployedContracts) internal deployedContracts;
    uint256[] internal targetChainIds;

    // Configurable paths with defaults
    string internal configPath = "deploy/deploy-config.json";
    string internal registryPath = "deploy/registry/";

    // Events for tracking
    event DeploymentStarted(uint256 indexed chainId, string deploymentType);
    event DeploymentCompleted(uint256 indexed chainId, string deploymentType);
    event ContractAlreadyDeployed(
        uint256 indexed chainId, string contractName, address deployedAddress
    );

    /**
     * @notice Initialize deployment with target chains
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     */
    function initializeDeployment(uint256[] memory chainIds) internal {
        // Load configuration
        loadFullConfiguration(chainIds);

        // Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Initialize deployment with custom paths
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _configPath Path to the configuration JSON file
     * @param _registryPath Path to the registry output directory
     */
    function initializeDeployment(
        uint256[] memory chainIds,
        string memory _configPath,
        string memory _registryPath
    ) internal {
        // Set custom paths
        configPath = _configPath;
        registryPath = _registryPath;

        // Load configuration
        loadFullConfiguration(chainIds);

        // Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Load all configuration from unified JSON file
     */
    function loadFullConfiguration(uint256[] memory chainIds) internal {
        string memory fullConfigPath = string.concat(vm.projectRoot(), "/", configPath);
        string memory configJson = vm.readFile(fullConfigPath);

        // Get all chain IDs from the config
        string[] memory keys = vm.parseJsonKeys(configJson, "$");

        // Filter chains based on input
        if (chainIds.length == 0) {
            // Deploy to all chains
            targetChainIds = new uint256[](keys.length);
            for (uint256 i = 0; i < keys.length; i++) {
                targetChainIds[i] = vm.parseUint(keys[i]);
            }
        } else {
            // Deploy to specified chains only
            targetChainIds = chainIds;
        }

        // Load configuration for each target chain
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            string memory chainKey = string.concat(".", vm.toString(chainId));

            // Parse individual fields for flexibility
            ChainConfig memory config;
            config.funderOwner = configJson.readAddress(string.concat(chainKey, ".funderOwner"));
            config.funderSigner = configJson.readAddress(string.concat(chainKey, ".funderSigner"));
            config.isTestnet = configJson.readBool(string.concat(chainKey, ".isTestnet"));
            config.l0SettlerOwner =
                configJson.readAddress(string.concat(chainKey, ".l0SettlerOwner"));
            config.layerZeroEndpoint =
                configJson.readAddress(string.concat(chainKey, ".layerZeroEndpoint"));
            config.layerZeroEid =
                uint32(configJson.readUint(string.concat(chainKey, ".layerZeroEid")));
            config.name = configJson.readString(string.concat(chainKey, ".name"));
            config.pauseAuthority =
                configJson.readAddress(string.concat(chainKey, ".pauseAuthority"));

            // Salt is optional - if not present or empty, it will be bytes32(0)
            config.salt = tryReadBytes32(configJson, string.concat(chainKey, ".salt"));

            config.settlerOwner = configJson.readAddress(string.concat(chainKey, ".settlerOwner"));
            config.stages = configJson.readStringArray(string.concat(chainKey, ".stages"));

            chainConfigs[chainId] = config;
        }

        // Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Check if a specific stage should be deployed for a chain
     */
    function shouldDeployStage(uint256 chainId, string memory stage) internal view returns (bool) {
        string[] memory stages = chainConfigs[chainId].stages;
        for (uint256 i = 0; i < stages.length; i++) {
            if (keccak256(bytes(stages[i])) == keccak256(bytes(stage))) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Load deployed contracts from registry
     */
    function loadDeployedContracts() internal {
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            bytes32 salt = chainConfigs[chainId].salt;
            string memory registryFile = getRegistryFilename(chainId, salt);

            try vm.readFile(registryFile) returns (string memory registryJson) {
                // Use individual parsing for flexibility with missing fields
                DeployedContracts memory deployed;
                deployed.accountImpl = tryReadAddress(registryJson, ".AccountImpl");
                deployed.accountProxy = tryReadAddress(registryJson, ".AccountProxy");
                deployed.escrow = tryReadAddress(registryJson, ".Escrow");
                deployed.orchestrator = tryReadAddress(registryJson, ".Orchestrator");
                deployed.simpleSettler = tryReadAddress(registryJson, ".SimpleSettler");
                deployed.layerZeroSettler = tryReadAddress(registryJson, ".LayerZeroSettler");
                deployed.simpleFunder = tryReadAddress(registryJson, ".SimpleFunder");
                deployed.simulator = tryReadAddress(registryJson, ".Simulator");

                deployedContracts[chainId] = deployed;
            } catch {
                // No registry file exists yet
            }
        }
    }

    /**
     * @notice Execute deployment
     */
    function executeDeployment() internal {
        printHeader();

        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];

            if (shouldSkipChain(chainId)) {
                continue;
            }

            executeChainDeployment(chainId);
        }

        printSummary();
    }

    /**
     * @notice Execute deployment for a specific chain
     */
    function executeChainDeployment(uint256 chainId) internal {
        ChainConfig memory config = chainConfigs[chainId];

        console.log("\n=====================================");
        console.log("Deploying to:", config.name);
        console.log("Chain ID:", chainId);
        console.log("=====================================\n");

        emit DeploymentStarted(chainId, deploymentType());

        // Switch to target chain for deployment
        // For multi-chain deployments, we need the RPC URL for each chain
        string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
        vm.createSelectFork(rpcUrl);

        // Verify chain ID
        require(block.chainid == chainId, "Chain ID mismatch");

        // Execute deployment
        deployToChain(chainId);

        emit DeploymentCompleted(chainId, deploymentType());
    }

    /**
     * @notice Check if chain should be skipped
     */
    function shouldSkipChain(uint256 chainId) internal view returns (bool) {
        ChainConfig memory config = chainConfigs[chainId];

        // For CREATE (salt = 0), check if deployment file exists to skip
        if (config.salt == bytes32(0)) {
            string memory registryFile = getRegistryFilename(chainId, config.salt);
            if (vm.exists(registryFile)) {
                console.log(unicode"\n[✓] Skipping", config.name, "- already deployed (CREATE)");
                return true;
            }
        }

        return false;
    }

    /**
     * @notice Print deployment header
     */
    function printHeader() internal view {
        console.log("\n========================================");
        console.log(deploymentType(), "Deployment");
        console.log("========================================");
        console.log("Target chains:", targetChainIds.length);
        console.log("");
    }

    /**
     * @notice Print deployment summary
     */
    function printSummary() internal view {
        console.log("\n========================================");
        console.log("Deployment Summary");
        console.log("========================================");

        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            ChainConfig memory config = chainConfigs[chainId];

            console.log(string.concat(unicode"[✓] ", config.name, " (", vm.toString(chainId), ")"));
        }

        console.log("");
        console.log("Total chains:", targetChainIds.length);
    }

    /**
     * @notice Save deployed contract address to registry
     */
    function saveDeployedContract(
        uint256 chainId,
        string memory contractName,
        address contractAddress
    ) internal {
        // Update in-memory config
        if (keccak256(bytes(contractName)) == keccak256("Orchestrator")) {
            deployedContracts[chainId].orchestrator = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("AccountImpl")) {
            deployedContracts[chainId].accountImpl = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("AccountProxy")) {
            deployedContracts[chainId].accountProxy = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("Simulator")) {
            deployedContracts[chainId].simulator = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("SimpleFunder")) {
            deployedContracts[chainId].simpleFunder = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("Escrow")) {
            deployedContracts[chainId].escrow = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("SimpleSettler")) {
            deployedContracts[chainId].simpleSettler = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("LayerZeroSettler")) {
            deployedContracts[chainId].layerZeroSettler = contractAddress;
        }

        // Save to registry file
        saveChainRegistry(chainId);
    }

    /**
     * @notice Save chain registry to file
     */
    function saveChainRegistry(uint256 chainId) internal {
        // Only save registry during actual broadcasts, not dry runs
        if (
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                && !vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            return;
        }

        DeployedContracts memory deployed = deployedContracts[chainId];

        string memory json = "{";

        // Build JSON with deployed addresses
        bool first = true;

        if (deployed.orchestrator != address(0)) {
            json = string.concat(json, '"Orchestrator": "', vm.toString(deployed.orchestrator), '"');
            first = false;
        }

        if (deployed.accountImpl != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(json, '"AccountImpl": "', vm.toString(deployed.accountImpl), '"');
            first = false;
        }

        if (deployed.accountProxy != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(json, '"AccountProxy": "', vm.toString(deployed.accountProxy), '"');
            first = false;
        }

        if (deployed.simulator != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(json, '"Simulator": "', vm.toString(deployed.simulator), '"');
            first = false;
        }

        if (deployed.simpleFunder != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(json, '"SimpleFunder": "', vm.toString(deployed.simpleFunder), '"');
            first = false;
        }

        if (deployed.escrow != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(json, '"Escrow": "', vm.toString(deployed.escrow), '"');
            first = false;
        }

        if (deployed.simpleSettler != address(0)) {
            if (!first) json = string.concat(json, ",");
            json =
                string.concat(json, '"SimpleSettler": "', vm.toString(deployed.simpleSettler), '"');
            first = false;
        }

        if (deployed.layerZeroSettler != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(
                json, '"LayerZeroSettler": "', vm.toString(deployed.layerZeroSettler), '"'
            );
        }

        json = string.concat(json, "}");

        bytes32 salt = chainConfigs[chainId].salt;
        string memory registryFile = getRegistryFilename(chainId, salt);
        vm.writeFile(registryFile, json);
    }

    // Configuration getters for derived contracts
    function getChainConfig(uint256 chainId) internal view returns (ChainConfig memory) {
        return chainConfigs[chainId];
    }

    function getDeployedContracts(uint256 chainId)
        internal
        view
        returns (DeployedContracts memory)
    {
        return deployedContracts[chainId];
    }

    // Helper functions for safe JSON parsing
    function tryReadAddress(string memory json, string memory key)
        internal
        pure
        returns (address)
    {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (address));
            }
        } catch {}
        return address(0);
    }

    function tryReadUint(string memory json, string memory key) internal pure returns (uint256) {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (uint256));
            }
        } catch {}
        return 0;
    }

    function tryReadBytes32(string memory json, string memory key)
        internal
        pure
        returns (bytes32)
    {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (bytes32));
            }
        } catch {}
        return bytes32(0);
    }

    // Abstract functions to be implemented by derived contracts
    function deploymentType() internal pure virtual returns (string memory);
    function deployToChain(uint256 chainId) internal virtual;

    /**
     * @notice Get registry filename based on chainId and salt
     * @param chainId The chain ID
     * @param salt The deployment salt
     * @return The full path to the registry file
     */
    function getRegistryFilename(uint256 chainId, bytes32 salt)
        internal
        view
        returns (string memory)
    {
        string memory filename = string.concat(
            vm.projectRoot(),
            "/",
            registryPath,
            "deployment_",
            vm.toString(chainId),
            "_",
            vm.toString(salt),
            ".json"
        );
        return filename;
    }

    // ============================================
    // CREATE2 DEPLOYMENT HELPERS
    // ============================================

    /**
     * @notice Check if we should use CREATE2 based on salt configuration
     * @param chainId The chain ID to check
     * @return true if salt is set (non-zero), false otherwise
     */
    function shouldUseCreate2(uint256 chainId) internal view returns (bool) {
        return chainConfigs[chainId].salt != bytes32(0);
    }

    /**
     * @notice Verify Safe Singleton Factory is deployed
     * @dev Reverts if factory is not deployed when CREATE2 is required
     * @param chainId The chain ID to check
     */
    function verifySafeSingletonFactory(uint256 chainId) internal view {
        if (shouldUseCreate2(chainId)) {
            require(SAFE_SINGLETON_FACTORY.code.length > 0, "Safe Singleton Factory not deployed");
            console.log("Safe Singleton Factory verified at:", SAFE_SINGLETON_FACTORY);
        }
    }

    /**
     * @notice Deploy contract using CREATE or CREATE2 based on configuration
     * @param chainId The chain ID for configuration
     * @param creationCode The contract creation code
     * @param args The constructor arguments (can be empty)
     * @param contractName Name of the contract for logging
     * @return deployed The deployed contract address
     */
    function deployContract(
        uint256 chainId,
        bytes memory creationCode,
        bytes memory args,
        string memory contractName
    ) internal returns (address deployed) {
        bytes32 salt = chainConfigs[chainId].salt;
        require(salt != bytes32(0), "deployContract should only be used for CREATE2");

        // Use CREATE2 via Safe Singleton Factory
        // First compute the predicted address
        address predicted;
        if (args.length > 0) {
            predicted = computeAddress(creationCode, args, salt);
        } else {
            predicted = computeAddress(creationCode, salt);
        }

        // Check if already deployed (CREATE2 collision)
        if (predicted.code.length > 0) {
            console.log(unicode"[🔷] ", contractName, "already deployed at:", predicted);
            emit ContractAlreadyDeployed(chainId, contractName, predicted);
            return predicted;
        }

        // Deploy using CREATE2
        if (args.length > 0) {
            deployed = broadcastDeploy(creationCode, args, salt);
        } else {
            deployed = broadcastDeploy(creationCode, salt);
        }

        console.log(string.concat(contractName, " deployed with CREATE2:"), deployed);
        console.log("  Salt:", vm.toString(salt));
        console.log("  Predicted:", predicted);
    }
}
