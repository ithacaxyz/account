// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {SafeSingletonDeployer} from "./SafeSingletonDeployer.sol";

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
 * @notice Main deployment script using TOML configuration
 * @dev Reads configuration from deploy/config.toml
 *
 * Usage:
 * # Deploy to all chains in config.toml
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run()" \
 *   --private-key $PRIVATE_KEY
 *
 * # Deploy to all chains (using empty array)
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[]"
 *
 * # Deploy to specific chains
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[1,42161,8453]"
 *
 * # Deploy with custom config file
 * forge script deploy/DeployMain.s.sol:DeployMain \
 *   --broadcast \
 *   --sig "run(uint256[],string)" \
 *   --private-key $PRIVATE_KEY \
 *   "[1]" "/deploy/custom-config.toml"
 */
contract DeployMain is Script, SafeSingletonDeployer {
    using stdToml for string;

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
        string[] contracts; // Array of contract names to deploy
    }

    struct DeployedContracts {
        address ithacaAccount; // The IthacaAccount implementation contract
        address accountProxy; // The EIP-7702 proxy
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

    function deploymentType() internal pure returns (string memory) {
        return "Main";
    }

    /**
     * @notice Deploy to all chains in config
     */
    function run() external {
        // Get all available chain IDs from fork configuration
        uint256[] memory chainIds = vm.readForkChainIds();
        initializeDeployment(chainIds);
        executeDeployment();
    }

    /**
     * @notice Deploy to specific chains
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     */
    function run(uint256[] memory chainIds) external {
        // If empty array, get all available chains
        if (chainIds.length == 0) {
            chainIds = vm.readForkChainIds();
        }
        initializeDeployment(chainIds);
        executeDeployment();
    }

    /**
     * @notice Deploy with custom config file
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _configPath Path to custom TOML config file
     */
    function run(uint256[] memory chainIds, string memory _configPath) external {
        // If empty array, get all available chains
        if (chainIds.length == 0) {
            chainIds = vm.readForkChainIds();
        }
        initializeDeployment(chainIds, _configPath);
        executeDeployment();
    }

    /**
     * @notice Initialize deployment with target chains using TOML config
     * @param chainIds Array of chain IDs to deploy to
     */
    function initializeDeployment(uint256[] memory chainIds) internal {
        require(chainIds.length > 0, "No chains found in configuration");

        // Load unified configuration
        string memory fullConfigPath = string.concat(vm.projectRoot(), configPath);
        configContent = vm.readFile(fullConfigPath);

        // Load registry path from config.toml
        registryPath = configContent.readString(".profile.deployment.registry_path");

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

        // Use vm.readFork* functions to read variables from the active fork
        config.name = vm.readForkString("name");
        config.isTestnet = vm.readForkBool("is_testnet");

        // Load addresses
        config.pauseAuthority = vm.readForkAddress("pause_authority");
        config.funderOwner = vm.readForkAddress("funder_owner");
        config.funderSigner = vm.readForkAddress("funder_signer");
        config.settlerOwner = vm.readForkAddress("settler_owner");
        config.l0SettlerOwner = vm.readForkAddress("l0_settler_owner");
        config.layerZeroEndpoint = vm.readForkAddress("layerzero_endpoint");

        // Load other configuration
        config.layerZeroEid = uint32(vm.readForkUint("layerzero_eid"));
        config.salt = vm.readForkBytes32("salt");

        // Load contracts list - required field, will revert if not present
        string[] memory contractsList = vm.readForkStringArray("contracts");

        // Check if user specified "ALL" to deploy all contracts
        if (
            contractsList.length == 1
                && keccak256(bytes(contractsList[0])) == keccak256(bytes("ALL"))
        ) {
            config.contracts = getAllContracts();
        } else {
            config.contracts = contractsList;
        }

        return config;
    }

    /**
     * @notice Get all available contracts
     */
    function getAllContracts() internal pure returns (string[] memory) {
        string[] memory contracts = new string[](8);
        contracts[0] = "Orchestrator";
        contracts[1] = "IthacaAccount";
        contracts[2] = "AccountProxy";
        contracts[3] = "Simulator";
        contracts[4] = "SimpleFunder";
        contracts[5] = "Escrow";
        contracts[6] = "SimpleSettler";
        contracts[7] = "LayerZeroSettler";
        return contracts;
    }

    /**
     * @notice Check if a specific contract should be deployed for a chain
     */
    function shouldDeployContract(uint256 chainId, string memory contractName)
        internal
        view
        returns (bool)
    {
        string[] memory contracts = chainConfigs[chainId].contracts;
        for (uint256 i = 0; i < contracts.length; i++) {
            if (keccak256(bytes(contracts[i])) == keccak256(bytes(contractName))) {
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
                deployed.ithacaAccount = tryReadAddress(registryJson, ".IthacaAccount");
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
        console.log(deploymentType(), "Deployment");
        console.log("========================================");
        console.log("Config file:", configPath);
        console.log("Target chains:", targetChainIds.length);
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            console.log("  -", targetChainIds[i]);
        }
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
        } else if (keccak256(bytes(contractName)) == keccak256("IthacaAccount")) {
            deployedContracts[chainId].ithacaAccount = contractAddress;
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

        if (deployed.ithacaAccount != address(0)) {
            if (!first) json = string.concat(json, ",");
            json =
                string.concat(json, '"IthacaAccount": "', vm.toString(deployed.ithacaAccount), '"');
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
    function deployContractWithCreate2(
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

    function deployToChain(uint256 chainId) internal {
        console.log("Deploying configured contracts from TOML config...");

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

        // Deploy each contract from the config
        for (uint256 i = 0; i < config.contracts.length; i++) {
            string memory contractName = config.contracts[i];
            deployContract(chainId, config, deployed, contractName);
        }

        console.log(unicode"\n[✓] All configured contracts deployed successfully");
    }

    function deployContract(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed,
        string memory contractName
    ) internal {
        bytes32 nameHash = keccak256(bytes(contractName));

        if (nameHash == keccak256("Orchestrator")) {
            deployOrchestrator(chainId, config, deployed);
        } else if (nameHash == keccak256("IthacaAccount")) {
            deployIthacaAccount(chainId, config, deployed);
        } else if (nameHash == keccak256("AccountProxy")) {
            deployAccountProxy(chainId, config, deployed);
        } else if (nameHash == keccak256("Simulator")) {
            deploySimulator(chainId, config, deployed);
        } else if (nameHash == keccak256("SimpleFunder")) {
            deploySimpleFunder(chainId, config, deployed);
        } else if (nameHash == keccak256("Escrow")) {
            deployEscrow(chainId, config, deployed);
        } else if (nameHash == keccak256("SimpleSettler")) {
            deploySimpleSettler(chainId, config, deployed);
        } else if (nameHash == keccak256("LayerZeroSettler")) {
            deployLayerZeroSettler(chainId, config, deployed);
        } else {
            console.log("Warning: Unknown contract name:", contractName);
        }
    }

    function deployOrchestrator(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        if (deployed.orchestrator == address(0)) {
            bytes memory creationCode = type(Orchestrator).creationCode;
            bytes memory args = abi.encode(config.pauseAuthority);
            address orchestrator =
                deployContractWithCreate2(chainId, creationCode, args, "Orchestrator");

            saveDeployedContract(chainId, "Orchestrator", orchestrator);
            deployed.orchestrator = orchestrator;
        } else {
            console.log("Orchestrator already deployed:", deployed.orchestrator);
        }
    }

    function deployIthacaAccount(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        // Ensure Orchestrator is deployed first (dependency)
        if (deployed.orchestrator == address(0)) {
            console.log("Deploying Orchestrator first (dependency for IthacaAccount)...");
            deployOrchestrator(chainId, config, deployed);
        }

        if (deployed.ithacaAccount == address(0)) {
            bytes memory creationCode = type(IthacaAccount).creationCode;
            bytes memory args = abi.encode(deployed.orchestrator);
            address ithacaAccount =
                deployContractWithCreate2(chainId, creationCode, args, "IthacaAccount");

            saveDeployedContract(chainId, "IthacaAccount", ithacaAccount);
            deployed.ithacaAccount = ithacaAccount;
        } else {
            console.log("IthacaAccount already deployed:", deployed.ithacaAccount);
        }
    }

    function deployAccountProxy(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        // Ensure IthacaAccount is deployed first (dependency)
        if (deployed.ithacaAccount == address(0)) {
            console.log("Deploying IthacaAccount first (dependency for AccountProxy)...");
            deployIthacaAccount(chainId, config, deployed);
        }

        if (deployed.accountProxy == address(0)) {
            bytes memory proxyCode = LibEIP7702.proxyInitCode(deployed.ithacaAccount, address(0));
            address accountProxy = deployContractWithCreate2(chainId, proxyCode, "", "AccountProxy");

            require(accountProxy != address(0), "Account proxy deployment failed");
            saveDeployedContract(chainId, "AccountProxy", accountProxy);
            deployed.accountProxy = accountProxy;
        } else {
            console.log("AccountProxy already deployed:", deployed.accountProxy);
        }
    }

    function deploySimulator(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        if (deployed.simulator == address(0)) {
            bytes memory creationCode = type(Simulator).creationCode;
            address simulator = deployContractWithCreate2(chainId, creationCode, "", "Simulator");

            saveDeployedContract(chainId, "Simulator", simulator);
            deployed.simulator = simulator;
        } else {
            console.log("Simulator already deployed:", deployed.simulator);
        }
    }

    function deploySimpleFunder(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        // Ensure Orchestrator is deployed first (dependency)
        if (deployed.orchestrator == address(0)) {
            console.log("Deploying Orchestrator first (dependency for SimpleFunder)...");
            deployOrchestrator(chainId, config, deployed);
        }

        if (deployed.simpleFunder == address(0)) {
            bytes memory creationCode = type(SimpleFunder).creationCode;
            bytes memory args =
                abi.encode(config.funderSigner, deployed.orchestrator, config.funderOwner);
            address funder = deployContractWithCreate2(chainId, creationCode, args, "SimpleFunder");

            saveDeployedContract(chainId, "SimpleFunder", funder);
            deployed.simpleFunder = funder;
        } else {
            console.log("SimpleFunder already deployed:", deployed.simpleFunder);
        }
    }

    function deployEscrow(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        if (deployed.escrow == address(0)) {
            bytes memory creationCode = type(Escrow).creationCode;
            address escrow = deployContractWithCreate2(chainId, creationCode, "", "Escrow");

            saveDeployedContract(chainId, "Escrow", escrow);
            deployed.escrow = escrow;
        } else {
            console.log("Escrow already deployed:", deployed.escrow);
        }
    }

    function deploySimpleSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        if (deployed.simpleSettler == address(0)) {
            bytes memory creationCode = type(SimpleSettler).creationCode;
            bytes memory args = abi.encode(config.settlerOwner);
            address settler =
                deployContractWithCreate2(chainId, creationCode, args, "SimpleSettler");

            console.log("  Owner:", config.settlerOwner);
            saveDeployedContract(chainId, "SimpleSettler", settler);
            deployed.simpleSettler = settler;
        } else {
            console.log("SimpleSettler already deployed:", deployed.simpleSettler);
        }
    }

    function deployLayerZeroSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        if (deployed.layerZeroSettler == address(0)) {
            bytes memory creationCode = type(LayerZeroSettler).creationCode;
            bytes memory args = abi.encode(config.layerZeroEndpoint, config.l0SettlerOwner);
            address settler =
                deployContractWithCreate2(chainId, creationCode, args, "LayerZeroSettler");

            console.log("  Endpoint:", config.layerZeroEndpoint);
            console.log("  Owner:", config.l0SettlerOwner);
            console.log("  EID:", config.layerZeroEid);
            saveDeployedContract(chainId, "LayerZeroSettler", settler);
            deployed.layerZeroSettler = settler;
        } else {
            console.log("LayerZeroSettler already deployed:", deployed.layerZeroSettler);
        }
    }
}
