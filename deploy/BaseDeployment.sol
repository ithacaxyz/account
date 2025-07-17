// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title BaseDeployment
 * @notice Base contract for all deployment scripts with unified JSON configuration
 * @dev Provides simplified configuration management using Foundry's JSON parsing
 */
abstract contract BaseDeployment is Script {
    using stdJson for string;

    // Deployment states
    enum DeploymentState {
        NOT_STARTED,
        IN_PROGRESS,
        COMPLETED,
        FAILED
    }

    enum SettlerType {
        SIMPLE,
        LAYERZERO
    }

    // Unified configuration structs (alphabetically ordered for JSON parsing)
    struct ChainConfig {
        uint256 chainId;
        uint32 eid; // LayerZero endpoint ID
        address endpoint; // LayerZero endpoint address
        bool isTestnet;
        string name;
    }

    struct ContractConfig {
        address funderOwner;
        address funderSigner;
        address l0SettlerOwner;
        address pauseAuthority;
        address settlerOwner;
        string settlerType;
    }

    struct DeploymentParams {
        bool dryRun;
        string environment;
        uint256 maxRetries;
        uint256 retryDelay;
    }

    struct DeployedContracts {
        address accountImpl;
        address accountProxy;
        address escrow;
        address orchestrator;
        address settler;
        address simpleFunder;
        address simulator;
    }

    struct ChainDeployment {
        uint256 chainId;
        string chainName;
        DeploymentState state;
        string error;
        uint256 attempts;
        uint256 lastAttemptTimestamp;
    }

    // Main configuration object
    struct Config {
        DeploymentParams deployment;
        ContractConfig contracts;
        mapping(uint256 => ChainConfig) chains;
        mapping(uint256 => DeployedContracts) deployed;
        uint256[] targetChains;
    }

    // State
    Config internal config;
    mapping(uint256 => ChainDeployment) public chainDeployments;

    // Registry path for persistent state
    string constant REGISTRY_PATH = "deploy/registry/";

    // Configuration file paths
    string constant CHAINS_CONFIG = "deploy/config/chains.json";
    string constant CONTRACTS_CONFIG_PATH = "deploy/config/contracts/";
    string constant DEPLOYMENT_CONFIG_PATH = "deploy/config/deployment/";
    string constant CHAIN_SELECTION_PATH = "deploy/config/chains/";

    // Events for tracking
    event DeploymentStarted(uint256 indexed chainId, string deploymentType);
    event DeploymentCompleted(uint256 indexed chainId, string deploymentType);
    event DeploymentFailed(uint256 indexed chainId, string deploymentType, string error);
    event DeploymentRetrying(uint256 indexed chainId, uint256 attempt);

    modifier trackDeployment(uint256 chainId) {
        chainDeployments[chainId].state = DeploymentState.IN_PROGRESS;
        chainDeployments[chainId].lastAttemptTimestamp = block.timestamp;
        chainDeployments[chainId].attempts++;

        emit DeploymentStarted(chainId, deploymentType());
        _;
    }

    /**
     * @notice Initialize deployment with environment
     * @param environment Environment name (mainnet, testnet, devnet)
     */
    function initializeDeployment(string memory environment) internal {
        // Load all configuration at once
        loadFullConfiguration(environment);

        // Initialize deployment state for each chain
        initializeChainDeployments();

        // Load any existing deployment state
        loadDeploymentState();
    }

    /**
     * @notice Load all configuration from JSON files
     */
    function loadFullConfiguration(string memory environment) internal {
        // 1. Load deployment parameters
        string memory deploymentPath =
            string.concat(vm.projectRoot(), "/", DEPLOYMENT_CONFIG_PATH, environment, ".json");
        string memory deploymentJson = vm.readFile(deploymentPath);
        config.deployment = abi.decode(vm.parseJson(deploymentJson), (DeploymentParams));

        // 2. Load contract configuration
        string memory contractsPath =
            string.concat(vm.projectRoot(), "/", CONTRACTS_CONFIG_PATH, environment, ".json");
        string memory contractsJson = vm.readFile(contractsPath);
        config.contracts = abi.decode(vm.parseJson(contractsJson), (ContractConfig));

        // 3. Load target chains
        string memory chainSelectionPath =
            string.concat(vm.projectRoot(), "/", CHAIN_SELECTION_PATH, environment, ".json");
        string memory chainSelectionJson = vm.readFile(chainSelectionPath);
        config.targetChains = abi.decode(vm.parseJson(chainSelectionJson, ".chains"), (uint256[]));

        // 4. Load chain configurations
        string memory chainsPath = string.concat(vm.projectRoot(), "/", CHAINS_CONFIG);
        string memory chainsJson = vm.readFile(chainsPath);

        for (uint256 i = 0; i < config.targetChains.length; i++) {
            uint256 chainId = config.targetChains[i];
            string memory chainKey = string.concat(".", vm.toString(chainId));

            // Parse individual chain config
            // Note: RPC URLs should be passed via environment when running forge script
            ChainConfig memory chainConfig;
            chainConfig.chainId = chainId;
            chainConfig.name = chainsJson.readString(string.concat(chainKey, ".name"));
            chainConfig.endpoint =
                chainsJson.readAddress(string.concat(chainKey, ".layerZeroEndpoint"));
            chainConfig.eid = uint32(chainsJson.readUint(string.concat(chainKey, ".layerZeroEid")));

            // Optional fields - check if key exists
            chainConfig.isTestnet = tryReadBool(chainsJson, string.concat(chainKey, ".isTestnet"));

            config.chains[chainId] = chainConfig;
        }

        // 5. Load existing deployed contracts from registry
        loadDeployedContracts();
    }

    /**
     * @notice Initialize chain deployment states
     */
    function initializeChainDeployments() internal {
        for (uint256 i = 0; i < config.targetChains.length; i++) {
            uint256 chainId = config.targetChains[i];
            chainDeployments[chainId] = ChainDeployment({
                chainId: chainId,
                chainName: config.chains[chainId].name,
                state: DeploymentState.NOT_STARTED,
                error: "",
                attempts: 0,
                lastAttemptTimestamp: 0
            });
        }
    }

    /**
     * @notice Load deployed contracts from registry
     */
    function loadDeployedContracts() internal {
        for (uint256 i = 0; i < config.targetChains.length; i++) {
            uint256 chainId = config.targetChains[i];
            string memory registryFile = string.concat(
                vm.projectRoot(),
                "/",
                REGISTRY_PATH,
                config.chains[chainId].name,
                "-",
                vm.toString(chainId),
                ".json"
            );

            try vm.readFile(registryFile) returns (string memory registryJson) {
                // Use individual parsing for flexibility with missing fields
                DeployedContracts memory deployed;
                deployed.accountImpl = tryReadAddress(registryJson, ".AccountImpl");
                deployed.accountProxy = tryReadAddress(registryJson, ".AccountProxy");
                deployed.escrow = tryReadAddress(registryJson, ".Escrow");
                deployed.orchestrator = tryReadAddress(registryJson, ".Orchestrator");
                deployed.settler = tryReadAddress(registryJson, ".Settler");
                deployed.simpleFunder = tryReadAddress(registryJson, ".SimpleFunder");
                deployed.simulator = tryReadAddress(registryJson, ".Simulator");

                config.deployed[chainId] = deployed;
            } catch {
                // No registry file exists yet
            }
        }
    }

    /**
     * @notice Load existing deployment state from registry
     */
    function loadDeploymentState() internal {
        string memory statePath = string.concat(REGISTRY_PATH, deploymentType(), "-state.json");
        string memory fullPath = string.concat(vm.projectRoot(), "/", statePath);

        try vm.readFile(fullPath) returns (string memory stateJson) {
            for (uint256 i = 0; i < config.targetChains.length; i++) {
                uint256 chainId = config.targetChains[i];
                string memory chainKey = vm.toString(chainId);

                // Try to read state
                string memory stateKey = string.concat(".", chainKey, ".state");
                chainDeployments[chainId].state = DeploymentState(tryReadUint(stateJson, stateKey));

                // Try to read attempts
                string memory attemptsKey = string.concat(".", chainKey, ".attempts");
                chainDeployments[chainId].attempts = tryReadUint(stateJson, attemptsKey);
            }
        } catch {
            // No previous state found
        }
    }

    /**
     * @notice Save deployment state to registry
     */
    function saveDeploymentState() internal {
        string memory json = "{";

        for (uint256 i = 0; i < config.targetChains.length; i++) {
            uint256 chainId = config.targetChains[i];
            ChainDeployment memory deployment = chainDeployments[chainId];

            if (i > 0) json = string.concat(json, ",");

            json = string.concat(json, '"', vm.toString(chainId), '": {');
            json = string.concat(json, '"state": ', vm.toString(uint256(deployment.state)), ",");
            json = string.concat(json, '"attempts": ', vm.toString(deployment.attempts), ",");
            json = string.concat(json, '"error": "', deployment.error, '"');
            json = string.concat(json, "}");
        }

        json = string.concat(json, "}");

        string memory statePath = string.concat(REGISTRY_PATH, deploymentType(), "-state.json");
        string memory fullPath = string.concat(vm.projectRoot(), "/", statePath);
        vm.writeFile(fullPath, json);
    }

    /**
     * @notice Execute deployment with retry logic
     */
    function executeDeployment() internal {
        printHeader();

        for (uint256 i = 0; i < config.targetChains.length; i++) {
            uint256 chainId = config.targetChains[i];

            if (shouldSkipChain(chainId)) {
                continue;
            }

            bool success = deployToChainWithRetry(chainId);

            if (!success && !config.deployment.dryRun) {
                console.log("\n[!] Deployment failed on chain", chainId);
                console.log("[!] Fix the issue and run again to retry");
                saveDeploymentState();
                revert("Deployment failed");
            }
        }

        saveDeploymentState();
        printSummary();
    }

    /**
     * @notice Deploy to a single chain with retry logic
     */
    function deployToChainWithRetry(uint256 chainId) internal returns (bool success) {
        ChainDeployment storage deployment = chainDeployments[chainId];

        while (deployment.attempts < config.deployment.maxRetries) {
            if (deployment.attempts > 0) {
                console.log("\n[>] Retrying deployment on", deployment.chainName);
                emit DeploymentRetrying(chainId, deployment.attempts + 1);

                // Wait before retry
                vm.sleep(config.deployment.retryDelay * 1000);
            }

            // Execute deployment directly without try/catch
            // In production, errors will cause the script to revert and can be retried
            bool deploySuccess = executeChainDeployment(chainId);

            if (deploySuccess) {
                deployment.state = DeploymentState.COMPLETED;
                deployment.error = "";
                emit DeploymentCompleted(chainId, deploymentType());
                return true;
            } else {
                deployment.state = DeploymentState.FAILED;
                deployment.error = "Deployment failed";
                deployment.attempts++;

                console.log("\n[!] Deployment failed");
                emit DeploymentFailed(chainId, deploymentType(), "Deployment failed");
            }
        }

        return false;
    }

    /**
     * @notice Execute deployment for a specific chain
     */
    function executeChainDeployment(uint256 chainId)
        internal
        trackDeployment(chainId)
        returns (bool)
    {
        ChainDeployment memory deployment = chainDeployments[chainId];

        console.log("\n=====================================");
        console.log("Deploying to:", deployment.chainName);
        console.log("Chain ID:", chainId);
        console.log("Attempt:", deployment.attempts + 1, "/", config.deployment.maxRetries);
        console.log("=====================================\n");

        // Switch to target chain
        // For multi-chain deployments, we need the RPC URL for each chain
        string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
        vm.createSelectFork(rpcUrl);

        // Verify chain ID
        require(block.chainid == chainId, "Chain ID mismatch");

        // Execute deployment
        if (config.deployment.dryRun) {
            console.log("[DRY RUN] Would deploy to chain", chainId);
            return true;
        } else {
            vm.startBroadcast();
            deployToChain(chainId);
            vm.stopBroadcast();
            return true;
        }
    }

    /**
     * @notice Check if chain should be skipped
     */
    function shouldSkipChain(uint256 chainId) internal view returns (bool) {
        ChainDeployment memory deployment = chainDeployments[chainId];

        if (deployment.state == DeploymentState.COMPLETED) {
            console.log(unicode"\n[✓] Skipping", deployment.chainName, "- already deployed");
            return true;
        }

        if (deployment.attempts >= config.deployment.maxRetries) {
            console.log("\n[!] Skipping", deployment.chainName, "- max retries exceeded");
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
        console.log("Environment:", config.deployment.environment);
        console.log("Target chains:", config.targetChains.length);
        console.log("Dry run:", config.deployment.dryRun);
        console.log("");
    }

    /**
     * @notice Print deployment summary
     */
    function printSummary() internal view {
        console.log("\n========================================");
        console.log("Deployment Summary");
        console.log("========================================");

        uint256 completed = 0;
        uint256 failed = 0;

        for (uint256 i = 0; i < config.targetChains.length; i++) {
            uint256 chainId = config.targetChains[i];
            ChainDeployment memory deployment = chainDeployments[chainId];

            string memory status;
            string memory symbol;

            if (deployment.state == DeploymentState.COMPLETED) {
                status = "COMPLETED";
                symbol = unicode"✓";
                completed++;
            } else if (deployment.state == DeploymentState.FAILED) {
                status = "FAILED";
                symbol = unicode"✗";
                failed++;
            } else {
                status = "PENDING";
                symbol = unicode"⋯";
            }

            console.log(string.concat("[", symbol, "] ", deployment.chainName, ": ", status));

            if (bytes(deployment.error).length > 0) {
                console.log("    Error:", deployment.error);
            }
        }

        console.log("");
        console.log("Total:", config.targetChains.length);
        console.log("Completed:", completed);
        console.log("Failed:", failed);
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
            config.deployed[chainId].orchestrator = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("AccountImpl")) {
            config.deployed[chainId].accountImpl = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("AccountProxy")) {
            config.deployed[chainId].accountProxy = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("Simulator")) {
            config.deployed[chainId].simulator = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("SimpleFunder")) {
            config.deployed[chainId].simpleFunder = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("Escrow")) {
            config.deployed[chainId].escrow = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("Settler")) {
            config.deployed[chainId].settler = contractAddress;
        }

        // Save to registry file
        saveChainRegistry(chainId);
    }

    /**
     * @notice Save chain registry to file
     */
    function saveChainRegistry(uint256 chainId) internal {
        DeployedContracts memory deployed = config.deployed[chainId];

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

        if (deployed.settler != address(0)) {
            if (!first) json = string.concat(json, ",");
            json = string.concat(json, '"Settler": "', vm.toString(deployed.settler), '"');
        }

        json = string.concat(json, "}");

        string memory registryFile = string.concat(
            REGISTRY_PATH, config.chains[chainId].name, "-", vm.toString(chainId), ".json"
        );
        string memory fullPath = string.concat(vm.projectRoot(), "/", registryFile);
        vm.writeFile(fullPath, json);
    }

    /**
     * @notice Convert string to uppercase
     */
    function toUpper(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(strBytes.length);

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] >= 0x61 && strBytes[i] <= 0x7A) {
                result[i] = bytes1(uint8(strBytes[i]) - 32);
            } else {
                result[i] = strBytes[i];
            }
        }

        return string(result);
    }

    // Configuration getters for derived contracts
    function getChainConfig(uint256 chainId) internal view returns (ChainConfig memory) {
        return config.chains[chainId];
    }

    function getContractConfig() internal view returns (ContractConfig memory) {
        return config.contracts;
    }

    function getDeployedContracts(uint256 chainId)
        internal
        view
        returns (DeployedContracts memory)
    {
        return config.deployed[chainId];
    }

    /**
     * @notice Extract substring
     */
    function substring(string memory str, uint256 start, uint256 end)
        internal
        pure
        returns (string memory)
    {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
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

    function tryReadString(string memory json, string memory key)
        internal
        pure
        returns (string memory)
    {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (string));
            }
        } catch {}
        return "";
    }

    function tryReadUint(string memory json, string memory key) internal pure returns (uint256) {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (uint256));
            }
        } catch {}
        return 0;
    }

    function tryReadBool(string memory json, string memory key) internal pure returns (bool) {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (bool));
            }
        } catch {}
        return false;
    }

    // Abstract functions to be implemented by derived contracts
    function deploymentType() internal pure virtual returns (string memory);
    function deployToChain(uint256 chainId) internal virtual;
}
