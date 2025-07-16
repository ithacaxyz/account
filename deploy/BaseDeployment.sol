// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title BaseDeployment
 * @notice Base contract for all deployment scripts with retry capabilities and state tracking
 * @dev Provides common functionality for chain-aware deployments with proper error handling
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

    struct ChainDeployment {
        uint256 chainId;
        string chainName;
        DeploymentState state;
        string error;
        uint256 attempts;
        uint256 lastAttemptTimestamp;
    }

    struct DeploymentConfig {
        string environment; // mainnet, testnet, devnet
        bool dryRun;
        uint256 maxRetries;
        uint256 retryDelay;
    }

    // State tracking
    mapping(uint256 => ChainDeployment) public chainDeployments;
    uint256[] public targetChains;
    DeploymentConfig public config;

    // Registry path for persistent state
    string constant REGISTRY_PATH = "deploy/registry/";

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
     * @notice Initialize base deployment with configuration
     * @param configPath Path to deployment configuration file
     */
    function initializeDeployment(string memory configPath) internal {
        loadConfig(configPath);
        loadTargetChains();
        loadDeploymentState();
    }

    /**
     * @notice Load deployment configuration
     */
    function loadConfig(string memory configPath) internal {
        string memory configJson = vm.readFile(configPath);

        config.environment = configJson.readString(".environment");
        config.dryRun = configJson.readBool(".dryRun");
        config.maxRetries = configJson.readUint(".maxRetries");
        config.retryDelay = configJson.readUint(".retryDelay");
    }

    /**
     * @notice Load target chains based on environment
     */
    function loadTargetChains() internal {
        string memory chainsPath =
            string.concat("deploy/config/chains/", config.environment, ".json");
        string memory chainsJson = vm.readFile(chainsPath);

        uint256[] memory chains = chainsJson.readUintArray(".chains");

        for (uint256 i = 0; i < chains.length; i++) {
            targetChains.push(chains[i]);

            // Initialize chain deployment state
            chainDeployments[chains[i]] = ChainDeployment({
                chainId: chains[i],
                chainName: getChainName(chains[i]),
                state: DeploymentState.NOT_STARTED,
                error: "",
                attempts: 0,
                lastAttemptTimestamp: 0
            });
        }
    }

    /**
     * @notice Load existing deployment state from registry
     */
    function loadDeploymentState() internal {
        string memory statePath = string.concat(REGISTRY_PATH, deploymentType(), "-state.json");

        try vm.readFile(statePath) returns (string memory stateJson) {
            // Load previous deployment states
            for (uint256 i = 0; i < targetChains.length; i++) {
                uint256 chainId = targetChains[i];
                string memory chainKey = vm.toString(chainId);

                // Try to read state - if it fails, keep default
                string memory stateKey = string.concat(".", chainKey, ".state");
                if (bytes(stateJson).length > 0) {
                    chainDeployments[chainId].state =
                        DeploymentState(abi.decode(vm.parseJson(stateJson, stateKey), (uint256)));
                }

                // Try to read attempts - if it fails, keep default
                string memory attemptsKey = string.concat(".", chainKey, ".attempts");
                if (bytes(stateJson).length > 0) {
                    chainDeployments[chainId].attempts =
                        abi.decode(vm.parseJson(stateJson, attemptsKey), (uint256));
                }
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

        for (uint256 i = 0; i < targetChains.length; i++) {
            uint256 chainId = targetChains[i];
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
        vm.writeFile(statePath, json);
    }

    /**
     * @notice Execute deployment with retry logic
     */
    function executeDeployment() internal {
        printHeader();

        for (uint256 i = 0; i < targetChains.length; i++) {
            uint256 chainId = targetChains[i];

            if (shouldSkipChain(chainId)) {
                continue;
            }

            bool success = deployToChainWithRetry(chainId);

            if (!success && !config.dryRun) {
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

        while (deployment.attempts < config.maxRetries) {
            if (deployment.attempts > 0) {
                console.log("\n[>] Retrying deployment on", deployment.chainName);
                emit DeploymentRetrying(chainId, deployment.attempts + 1);

                // Wait before retry
                vm.sleep(config.retryDelay * 1000);
            }

            try this.deployToChainExternal(chainId) {
                deployment.state = DeploymentState.COMPLETED;
                deployment.error = "";
                emit DeploymentCompleted(chainId, deploymentType());
                return true;
            } catch Error(string memory reason) {
                deployment.state = DeploymentState.FAILED;
                deployment.error = reason;
                deployment.attempts++;

                console.log("\n[!] Error:", reason);
                emit DeploymentFailed(chainId, deploymentType(), reason);
            } catch {
                deployment.state = DeploymentState.FAILED;
                deployment.error = "Unknown error";
                deployment.attempts++;

                console.log("\n[!] Unknown error occurred");
                emit DeploymentFailed(chainId, deploymentType(), "Unknown error");
            }
        }

        return false;
    }

    /**
     * @notice External wrapper for deployment (enables try/catch)
     */
    function deployToChainExternal(uint256 chainId) external {
        require(msg.sender == address(this), "Only callable internally");

        ChainDeployment memory deployment = chainDeployments[chainId];

        console.log("\n=====================================");
        console.log("Deploying to:", deployment.chainName);
        console.log("Chain ID:", chainId);
        console.log("Attempt:", deployment.attempts + 1, "/", config.maxRetries);
        console.log("=====================================\n");

        // Switch to target chain
        string memory rpcUrl = getRpcUrl(chainId);
        vm.createSelectFork(rpcUrl);

        // Verify chain ID
        require(block.chainid == chainId, "Chain ID mismatch");

        // Execute deployment
        if (config.dryRun) {
            console.log("[DRY RUN] Would deploy to chain", chainId);
        } else {
            vm.startBroadcast();
            deployToChain(chainId);
            vm.stopBroadcast();
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

        if (deployment.attempts >= config.maxRetries) {
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
        console.log("Environment:", config.environment);
        console.log("Target chains:", targetChains.length);
        console.log("Dry run:", config.dryRun);
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

        for (uint256 i = 0; i < targetChains.length; i++) {
            uint256 chainId = targetChains[i];
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
        console.log("Total:", targetChains.length);
        console.log("Completed:", completed);
        console.log("Failed:", failed);
    }

    /**
     * @notice Get chain name from chain ID
     */
    function getChainName(uint256 chainId) internal view returns (string memory) {
        string memory chainsPath = "deploy/config/chains.json";
        string memory chainsJson = vm.readFile(chainsPath);

        return chainsJson.readString(string.concat(".", vm.toString(chainId), ".name"));
    }

    /**
     * @notice Get RPC URL for chain
     */
    function getRpcUrl(uint256 chainId) internal view returns (string memory) {
        string memory chainsPath = "deploy/config/chains.json";
        string memory chainsJson = vm.readFile(chainsPath);

        string memory rpcUrl =
            chainsJson.readString(string.concat(".", vm.toString(chainId), ".rpcUrl"));

        // Handle environment variable substitution
        if (bytes(rpcUrl).length > 0 && bytes(rpcUrl)[0] == "$") {
            string memory envVar = substring(rpcUrl, 2, bytes(rpcUrl).length - 1);
            return vm.envString(envVar);
        }

        return rpcUrl;
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
        view
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
        view
        returns (string memory)
    {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (string));
            }
        } catch {}
        return "";
    }

    function tryReadUint(string memory json, string memory key) internal view returns (uint256) {
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (uint256));
            }
        } catch {}
        return 0;
    }

    // Abstract functions to be implemented by derived contracts
    function deploymentType() internal pure virtual returns (string memory);
    function deployToChain(uint256 chainId) internal virtual;
}
