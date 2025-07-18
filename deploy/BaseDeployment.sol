// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DefaultConfig} from "./DefaultConfig.sol";

/**
 * @title BaseDeployment
 * @notice Base contract for all deployment scripts with Solidity configuration
 * @dev Uses type-safe Solidity configuration instead of JSON parsing
 */
abstract contract BaseDeployment is Script {
    // Deployment stages enum
    enum Stage {
        Core,
        Interop,
        SimpleSettler,
        LayerZeroSettler
    }

    // Chain configuration struct
    struct ChainConfig {
        uint256 chainId;
        string name;
        bool isTestnet;
        address pauseAuthority;
        address funderOwner;
        address funderSigner;
        address settlerOwner;
        address l0SettlerOwner;
        address layerZeroEndpoint;
        uint32 layerZeroEid;
        Stage[] stages;
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

    // Paths
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
        // Load configuration from Solidity config
        loadConfiguration(chainIds);

        // Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Initialize deployment with custom registry path
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _registryPath Path to the registry output directory
     */
    function initializeDeployment(uint256[] memory chainIds, string memory _registryPath)
        internal
    {
        // Set custom registry path
        registryPath = _registryPath;

        // Load configuration from Solidity config
        loadConfiguration(chainIds);

        // Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Load configuration from Solidity config contract
     */
    function loadConfiguration(uint256[] memory chainIds) internal {
        // Get configurations from DefaultConfig
        DefaultConfig configContract = new DefaultConfig();
        ChainConfig[] memory allConfigs = configContract.getConfigs();

        // Filter chains based on input
        if (chainIds.length == 0) {
            // Deploy to all chains
            targetChainIds = new uint256[](allConfigs.length);

            // Load all configurations
            for (uint256 i = 0; i < allConfigs.length; i++) {
                uint256 chainId = allConfigs[i].chainId;
                targetChainIds[i] = chainId;
                chainConfigs[chainId] = allConfigs[i];
            }
        } else {
            // Deploy to specified chains only
            targetChainIds = chainIds;

            // Load configurations for specified chains
            for (uint256 i = 0; i < chainIds.length; i++) {
                uint256 chainId = chainIds[i];
                bool found = false;

                // Find the configuration for this chain
                for (uint256 j = 0; j < allConfigs.length; j++) {
                    if (allConfigs[j].chainId == chainId) {
                        chainConfigs[chainId] = allConfigs[j];
                        found = true;
                        break;
                    }
                }

                require(
                    found, string.concat("Chain ID not found in config: ", vm.toString(chainId))
                );
            }
        }

        // Log the loaded configuration for verification
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            ChainConfig memory config = chainConfigs[chainId];

            console.log("-------------------------------------");
            console.log("Loaded configuration for chain:", chainId);
            console.log("Name:", config.name);
            console.log("Funder Owner:", config.funderOwner);
            console.log("Funder Signer:", config.funderSigner);
            console.log("L0 Settler Owner:", config.l0SettlerOwner);
            console.log("Settler Owner:", config.settlerOwner);
            console.log("Pause Authority:", config.pauseAuthority);
            console.log("LayerZero Endpoint:", config.layerZeroEndpoint);
            console.log("LayerZero EID:", config.layerZeroEid);
            console.log("Is Testnet:", config.isTestnet);
        }

        // Warn the operator to verify configuration before proceeding
        console.log(
            unicode"\n[⚠️] Please review the above configuration values and ensure they are correct before proceeding with deployment.\n"
        );
    }

    /**
     * @notice Check if a specific stage should be deployed for a chain
     */
    function shouldDeployStage(uint256 chainId, Stage stage) internal view returns (bool) {
        Stage[] memory stages = chainConfigs[chainId].stages;
        for (uint256 i = 0; i < stages.length; i++) {
            if (stages[i] == stage) {
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
            string memory registryFile = getRegistryFilename(chainId);

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

        // Check if deployment file exists to skip
        string memory registryFile = getRegistryFilename(chainId);
        if (vm.exists(registryFile)) {
            console.log(unicode"\n[✓] Skipping", config.name, "- already deployed");
            return true;
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

        string memory registryFile = getRegistryFilename(chainId);
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

    // Helper functions for safe JSON parsing (still needed for registry files)
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

    // Abstract functions to be implemented by derived contracts
    function deploymentType() internal pure virtual returns (string memory);
    function deployToChain(uint256 chainId) internal virtual;

    /**
     * @notice Get registry filename based on chainId
     * @param chainId The chain ID
     * @return The full path to the registry file
     */
    function getRegistryFilename(uint256 chainId) internal view returns (string memory) {
        string memory filename = string.concat(
            vm.projectRoot(), "/", registryPath, "deployment_", vm.toString(chainId), ".json"
        );
        return filename;
    }
}
