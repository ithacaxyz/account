// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {SafeSingletonDeployer} from "./SafeSingletonDeployer.sol";

/**
 * @title BaseDeploymentToml
 * @notice Base contract for all deployment scripts with TOML configuration support
 * @dev Uses Foundry's new fork* cheatcodes from PR #11236
 *      The workflow is:
 *      1. Create a fork using RPC_{chainId} environment variable
 *      2. Use vm.fork* functions to read variables from the active fork's config
 */
abstract contract BaseDeploymentToml is Script, SafeSingletonDeployer {
    using stdToml for string;

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
        bytes32 salt;
        Stage[] stages;
        uint256 targetBalance; // For funding configuration
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

    // Paths and config
    string internal registryPath;
    string internal configContent; // For unified config
    string internal configPath = "/deploy/config.toml";

    // Events for tracking
    event DeploymentStarted(uint256 indexed chainId, string deploymentType);
    event DeploymentCompleted(uint256 indexed chainId, string deploymentType);
    event ContractAlreadyDeployed(
        uint256 indexed chainId, string contractName, address deployedAddress
    );

    /**
     * @notice Initialize deployment with target chains using TOML config
     * @param chainIds Array of chain IDs to deploy to
     */
    function initializeDeployment(uint256[] memory chainIds) internal {
        require(chainIds.length > 0, "Must specify at least one chain ID");

        // Load unified configuration
        string memory fullConfigPath = string.concat(vm.projectRoot(), configPath);
        configContent = vm.readFile(fullConfigPath);

        // Load registry path from config.toml
        registryPath = configContent.readString(".deployment.registry_path");

        // Store target chain IDs
        targetChainIds = chainIds;

        // Load configuration for each chain
        loadConfigurations();

        // Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Initialize deployment with custom config path
     * @param chainIds Array of chain IDs to deploy to
     * @param _configPath Path to the config file
     */
    function initializeDeployment(uint256[] memory chainIds, string memory _configPath) internal {
        configPath = _configPath;
        initializeDeployment(chainIds);
    }

    /**
     * @notice Load configurations for all target chains
     */
    function loadConfigurations() internal {
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];

            // Use the RPC_{chainId} environment variable directly
            // This matches the naming convention in config.toml
            string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));

            // Create fork using the RPC URL
            uint256 forkId = vm.createFork(rpcUrl);
            vm.selectFork(forkId);

            // Verify we're on the correct chain
            require(block.chainid == chainId, "Chain ID mismatch");

            // Load configuration from fork variables
            ChainConfig memory config = loadChainConfigFromFork(chainId);
            chainConfigs[chainId] = config;
        }

        // Log the loaded configuration for verification
        logLoadedConfigurations();
    }

    /**
     * @notice Load chain configuration from the currently active fork
     * @param chainId The chain ID we're loading config for
     */
    function loadChainConfigFromFork(uint256 chainId) internal view returns (ChainConfig memory) {
        ChainConfig memory config;

        config.chainId = chainId;

        // Use vm.fork* functions to read variables from the active fork
        config.name = vm.forkString("name");
        config.isTestnet = vm.forkBool("is_testnet");

        // Load addresses
        config.pauseAuthority = vm.forkAddress("pause_authority");
        config.funderOwner = vm.forkAddress("funder_owner");
        config.funderSigner = vm.forkAddress("funder_signer");
        config.settlerOwner = vm.forkAddress("settler_owner");
        config.l0SettlerOwner = vm.forkAddress("l0_settler_owner");
        config.layerZeroEndpoint = vm.forkAddress("layerzero_endpoint");

        // Load other configuration
        config.layerZeroEid = uint32(vm.forkUint("layerzero_eid"));
        config.salt = vm.forkBytes32("salt");
        config.targetBalance = vm.forkUint("target_balance");

        // Load stages - since there's no forkStringArray, we need to determine stages based on chain
        config.stages = getDefaultStages(config.isTestnet, chainId);

        return config;
    }

    /**
     * @notice Get default stages based on chain type
     */
    function getDefaultStages(bool isTestnet, uint256 chainId)
        internal
        pure
        returns (Stage[] memory)
    {
        // Porto devnets don't have LayerZero
        if (chainId >= 28404 && chainId <= 28407) {
            Stage[] memory stages = new Stage[](3);
            stages[0] = Stage.Core;
            stages[1] = Stage.Interop;
            stages[2] = Stage.SimpleSettler;
            return stages;
        }

        // All other chains have all stages
        Stage[] memory stages = new Stage[](4);
        stages[0] = Stage.Core;
        stages[1] = Stage.Interop;
        stages[2] = Stage.SimpleSettler;
        stages[3] = Stage.LayerZeroSettler;
        return stages;
    }

    /**
     * @notice Parse stage strings from TOML to Stage enum array
     */
    function parseStages(string[] memory stageStrings) internal pure returns (Stage[] memory) {
        Stage[] memory stages = new Stage[](stageStrings.length);

        for (uint256 i = 0; i < stageStrings.length; i++) {
            bytes32 stageHash = keccak256(bytes(stageStrings[i]));

            if (stageHash == keccak256("core")) {
                stages[i] = Stage.Core;
            } else if (stageHash == keccak256("interop")) {
                stages[i] = Stage.Interop;
            } else if (stageHash == keccak256("simple_settler")) {
                stages[i] = Stage.SimpleSettler;
            } else if (stageHash == keccak256("layerzero_settler")) {
                stages[i] = Stage.LayerZeroSettler;
            } else {
                revert(string.concat("Unknown stage: ", stageStrings[i]));
            }
        }

        return stages;
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
     * @notice Log loaded configurations
     */
    function logLoadedConfigurations() internal view {
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            ChainConfig memory config = chainConfigs[chainId];

            console.log("-------------------------------------");
            console.log("Loaded configuration for chain:", chainId);
            console.log("Name:", config.name);
            console.log("Is Testnet:", config.isTestnet);
            console.log("Funder Owner:", config.funderOwner);
            console.log("Funder Signer:", config.funderSigner);
            console.log("L0 Settler Owner:", config.l0SettlerOwner);
            console.log("Settler Owner:", config.settlerOwner);
            console.log("Pause Authority:", config.pauseAuthority);
            console.log("LayerZero Endpoint:", config.layerZeroEndpoint);
            console.log("LayerZero EID:", config.layerZeroEid);
            console.log("Target Balance (wei):", config.targetBalance);
            console.log("Salt:");
            console.logBytes32(config.salt);
        }

        console.log(
            unicode"\n[⚠️] Please review the above configuration values from TOML before proceeding.\n"
        );
    }

    /**
     * @notice Execute deployment
     */
    function executeDeployment() internal {
        printHeader();

        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
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

        // Use the RPC_{chainId} environment variable directly
        string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));

        // Create and switch to fork for the chain
        vm.createSelectFork(rpcUrl);

        // Verify chain ID
        require(block.chainid == chainId, "Chain ID mismatch");

        // Execute deployment
        deployToChain(chainId);

        emit DeploymentCompleted(chainId, deploymentType());
    }

    /**
     * @notice Get chain configuration
     */
    function getChainConfig(uint256 chainId) internal view returns (ChainConfig memory) {
        return chainConfigs[chainId];
    }

    /**
     * @notice Get deployed contracts for a chain
     */
    function getDeployedContracts(uint256 chainId)
        internal
        view
        returns (DeployedContracts memory)
    {
        return deployedContracts[chainId];
    }

    /**
     * @notice Print deployment header
     */
    function printHeader() internal view {
        console.log("\n========================================");
        console.log(deploymentType(), "Deployment (TOML Config)");
        console.log("========================================");
        console.log("Config file:", configPath);
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

        // Write to registry file
        writeToRegistry(chainId, contractName, contractAddress);
    }

    /**
     * @notice Write to registry file
     */
    function writeToRegistry(uint256 chainId, string memory contractName, address contractAddress)
        internal
    {
        // Only save registry during actual broadcasts, not dry runs
        if (
            !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
                && !vm.isContext(VmSafe.ForgeContext.ScriptResume)
        ) {
            return;
        }

        DeployedContracts memory deployed = deployedContracts[chainId];

        string memory json = "{";
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

    /**
     * @notice Get registry filename based on chainId and salt
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

    /**
     * @notice Try to read an address from JSON
     */
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

    /**
     * @notice Verify Safe Singleton Factory is deployed
     */
    function verifySafeSingletonFactory(uint256 chainId) internal view {
        require(SAFE_SINGLETON_FACTORY.code.length > 0, "Safe Singleton Factory not deployed");
        console.log("Safe Singleton Factory verified at:", SAFE_SINGLETON_FACTORY);
    }

    /**
     * @notice Deploy contract using CREATE or CREATE2
     */
    function deployContract(
        uint256 chainId,
        bytes memory creationCode,
        bytes memory args,
        string memory contractName
    ) internal returns (address deployed) {
        bytes32 salt = chainConfigs[chainId].salt;

        // Use CREATE2 via Safe Singleton Factory
        address predicted;
        if (args.length > 0) {
            predicted = computeAddress(creationCode, args, salt);
        } else {
            predicted = computeAddress(creationCode, salt);
        }

        // Check if already deployed
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
        require(deployed == predicted, "CREATE2 address mismatch");
    }

    /**
     * @notice Abstract functions to be implemented by child contracts
     */
    function deploymentType() internal pure virtual returns (string memory);
    function deployToChain(uint256 chainId) internal virtual;
}
