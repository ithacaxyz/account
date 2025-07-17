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

    // Unified configuration struct (alphabetically ordered for JSON parsing)
    struct ChainConfig {
        bool dryRun;
        address funderOwner;
        address funderSigner;
        bool isTestnet;
        address l0SettlerOwner;
        address layerZeroEndpoint;
        uint32 layerZeroEid;
        uint256 maxRetries;
        string name;
        address pauseAuthority;
        uint256 retryDelay;
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

    struct ChainDeployment {
        uint256 chainId;
        string chainName;
        DeploymentState state;
        string error;
        uint256 attempts;
        uint256 lastAttemptTimestamp;
    }

    // State
    mapping(uint256 => ChainConfig) internal chainConfigs;
    mapping(uint256 => DeployedContracts) internal deployedContracts;
    mapping(uint256 => ChainDeployment) public chainDeployments;
    uint256[] internal targetChainIds;

    // Registry path for persistent state
    string constant REGISTRY_PATH = "deploy/registry/";

    // Configuration file path
    string constant CONFIG_FILE = "deploy/deploy-config.json";

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
     * @notice Initialize deployment with target chains
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     */
    function initializeDeployment(uint256[] memory chainIds) internal {
        // Load configuration
        loadFullConfiguration(chainIds);

        // Initialize deployment state for each chain
        initializeChainDeployments();

        // Load any existing deployment state
        loadDeploymentState();
    }

    /**
     * @notice Load all configuration from unified JSON file
     */
    function loadFullConfiguration(uint256[] memory chainIds) internal {
        string memory configPath = string.concat(vm.projectRoot(), "/", CONFIG_FILE);
        string memory configJson = vm.readFile(configPath);

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
            config.dryRun = configJson.readBool(string.concat(chainKey, ".dryRun"));
            config.funderOwner = configJson.readAddress(string.concat(chainKey, ".funderOwner"));
            config.funderSigner = configJson.readAddress(string.concat(chainKey, ".funderSigner"));
            config.isTestnet = configJson.readBool(string.concat(chainKey, ".isTestnet"));
            config.l0SettlerOwner =
                configJson.readAddress(string.concat(chainKey, ".l0SettlerOwner"));
            config.layerZeroEndpoint =
                configJson.readAddress(string.concat(chainKey, ".layerZeroEndpoint"));
            config.layerZeroEid =
                uint32(configJson.readUint(string.concat(chainKey, ".layerZeroEid")));
            config.maxRetries = configJson.readUint(string.concat(chainKey, ".maxRetries"));
            config.name = configJson.readString(string.concat(chainKey, ".name"));
            config.pauseAuthority =
                configJson.readAddress(string.concat(chainKey, ".pauseAuthority"));
            config.retryDelay = configJson.readUint(string.concat(chainKey, ".retryDelay"));
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
     * @notice Initialize chain deployment states
     */
    function initializeChainDeployments() internal {
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            chainDeployments[chainId] = ChainDeployment({
                chainId: chainId,
                chainName: chainConfigs[chainId].name,
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
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
            string memory registryFile = string.concat(
                vm.projectRoot(),
                "/",
                REGISTRY_PATH,
                chainConfigs[chainId].name,
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
     * @notice Load existing deployment state from registry
     */
    function loadDeploymentState() internal {
        string memory statePath = string.concat(REGISTRY_PATH, deploymentType(), "-state.json");
        string memory fullPath = string.concat(vm.projectRoot(), "/", statePath);

        try vm.readFile(fullPath) returns (string memory stateJson) {
            for (uint256 i = 0; i < targetChainIds.length; i++) {
                uint256 chainId = targetChainIds[i];
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

        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
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

        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];

            if (shouldSkipChain(chainId)) {
                continue;
            }

            bool success = deployToChainWithRetry(chainId);

            if (!success && !chainConfigs[chainId].dryRun) {
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
        ChainConfig memory config = chainConfigs[chainId];

        while (deployment.attempts < config.maxRetries) {
            if (deployment.attempts > 0) {
                console.log("\n[>] Retrying deployment on", deployment.chainName);
                emit DeploymentRetrying(chainId, deployment.attempts + 1);

                // Wait before retry
                vm.sleep(config.retryDelay * 1000);
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
        ChainConfig memory config = chainConfigs[chainId];

        console.log("\n=====================================");
        console.log("Deploying to:", deployment.chainName);
        console.log("Chain ID:", chainId);
        console.log("Attempt:", deployment.attempts + 1, "/", config.maxRetries);
        console.log("=====================================\n");

        // Execute deployment
        if (config.dryRun) {
            console.log("[DRY RUN] Would deploy to chain", chainId);
            console.log("[DRY RUN] Configuration:");
            console.log("  Pause Authority:", config.pauseAuthority);
            console.log("  Funder Signer:", config.funderSigner);
            console.log("  Funder Owner:", config.funderOwner);
            console.log("  Stages:");
            for (uint256 i = 0; i < config.stages.length; i++) {
                console.log("    -", config.stages[i]);
            }
            return true;
        } else {
            // Switch to target chain for actual deployment
            // For multi-chain deployments, we need the RPC URL for each chain
            string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
            vm.createSelectFork(rpcUrl);

            // Verify chain ID
            require(block.chainid == chainId, "Chain ID mismatch");

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

        if (deployment.attempts >= chainConfigs[chainId].maxRetries) {
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

        uint256 completed = 0;
        uint256 failed = 0;

        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];
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
        console.log("Total:", targetChainIds.length);
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

        string memory registryFile = string.concat(
            REGISTRY_PATH, chainConfigs[chainId].name, "-", vm.toString(chainId), ".json"
        );
        string memory fullPath = string.concat(vm.projectRoot(), "/", registryFile);
        vm.writeFile(fullPath, json);
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
