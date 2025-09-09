// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Config} from "forge-std/Config.sol";
import {Variable, TypeKind} from "forge-std/LibVariable.sol";
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
import {ExperimentERC20} from "./mock/ExperimentalERC20.sol";

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
contract DeployMain is Script, Config, SafeSingletonDeployer {

    // Chain configuration struct
    struct ChainConfig {
        uint256 chainId;
        string name;
        bool isTestnet;
        address funderOwner;
        address funderSigner;
        address settlerOwner;
        address l0SettlerOwner;
        address l0SettlerSigner;
        address layerZeroEndpoint;
        address[] oldOrchestrators;
        uint32 layerZeroEid;
        bytes32 salt;
        string[] contracts; // Array of contract names to deploy
        // EXP Token configuration (testnet only)
        address expMinterAddress;
        uint256 expMintAmount;
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
        address expToken; // EXP token (testnet only)
        address exp2Token; // EXP2 token (testnet only)
    }

    // State
    mapping(uint256 => ChainConfig) internal chainConfigs;
    mapping(uint256 => DeployedContracts) internal deployedContracts;
    uint256[] internal targetChainIds;

    // Config path
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
        // Load configuration and setup forks (enable write-back to save deployed addresses)
        string memory fullConfigPath = string.concat(vm.projectRoot(), configPath);
        _loadConfigAndForks(fullConfigPath, true);
        
        // Get all available chain IDs from configuration
        targetChainIds = config.getChainIds();
        require(targetChainIds.length > 0, "No chains found in configuration");
        
        // Load configuration for each chain
        loadConfigurations();
        loadDeployedContracts();
        executeDeployment();
    }

    /**
     * @notice Deploy to specific chains
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     */
    function run(uint256[] memory chainIds) external {
        // Load configuration and setup forks (enable write-back to save deployed addresses)
        string memory fullConfigPath = string.concat(vm.projectRoot(), configPath);
        _loadConfigAndForks(fullConfigPath, true);
        
        // If empty array, get all available chains
        if (chainIds.length == 0) {
            chainIds = config.getChainIds();
        }
        targetChainIds = chainIds;
        require(targetChainIds.length > 0, "No chains found in configuration");
        
        // Load configuration for each chain
        loadConfigurations();
        loadDeployedContracts();
        executeDeployment();
    }

    /**
     * @notice Deploy with custom config file
     * @param chainIds Array of chain IDs to deploy to (empty array = all chains)
     * @param _configPath Path to custom TOML config file
     */
    function run(uint256[] memory chainIds, string memory _configPath) external {
        configPath = _configPath;
        
        // Load configuration and setup forks (enable write-back to save deployed addresses)
        string memory fullConfigPath = string.concat(vm.projectRoot(), configPath);
        _loadConfigAndForks(fullConfigPath, true);
        
        // If empty array, get all available chains
        if (chainIds.length == 0) {
            chainIds = config.getChainIds();
        }
        targetChainIds = chainIds;
        require(targetChainIds.length > 0, "No chains found in configuration");
        
        // Load configuration for each chain
        loadConfigurations();
        loadDeployedContracts();
        executeDeployment();
    }


    /**
     * @notice Load configurations for all target chains
     */
    function loadConfigurations() internal {
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];

            // Switch to the fork for this chain (already created by _loadConfigAndForks)
            vm.selectFork(forkOf[chainId]);

            // Verify we're on the correct chain
            require(block.chainid == chainId, "Chain ID mismatch");

            // Load configuration using new StdConfig pattern
            ChainConfig memory chainConfig = loadChainConfigFromStdConfig(chainId);
            chainConfigs[chainId] = chainConfig;
        }

        // Log the loaded configuration for verification
        logLoadedConfigurations();
    }

    /**
     * @notice Load chain configuration using StdConfig
     * @param chainId The chain ID we're loading config for
     */
    function loadChainConfigFromStdConfig(uint256 chainId) internal view returns (ChainConfig memory) {
        ChainConfig memory chainConfig;

        chainConfig.chainId = chainId;

        // Use StdConfig to read variables
        chainConfig.name = config.get(chainId, "name").toString();
        chainConfig.isTestnet = config.get(chainId, "is_testnet").toBool();

        // Load addresses
        chainConfig.funderOwner = config.get(chainId, "funder_owner").toAddress();
        chainConfig.funderSigner = config.get(chainId, "funder_signer").toAddress();
        chainConfig.settlerOwner = config.get(chainId, "settler_owner").toAddress();
        chainConfig.l0SettlerOwner = config.get(chainId, "l0_settler_owner").toAddress();
        chainConfig.l0SettlerSigner = config.get(chainId, "l0_settler_signer").toAddress();
        chainConfig.layerZeroEndpoint = config.get(chainId, "layerzero_endpoint").toAddress();

        // Load other configuration
        chainConfig.layerZeroEid = uint32(config.get(chainId, "layerzero_eid").toUint256());
        chainConfig.salt = config.get(chainId, "salt").toBytes32();

        // Load EXP token configuration (testnet only)
        if (chainConfig.isTestnet) {
            chainConfig.expMinterAddress = config.get(chainId, "exp_minter_address").toAddress();
            chainConfig.expMintAmount = config.get(chainId, "exp_mint_amount").toUint256();
        }

        // Load contracts list - required field, will revert if not present
        string[] memory contractsList = config.get(chainId, "contracts").toStringArray();

        // Check if user specified "ALL" to deploy all contracts
        if (
            contractsList.length == 1
                && keccak256(bytes(contractsList[0])) == keccak256(bytes("ALL"))
        ) {
            string[] memory baseContracts = getAllContracts();
            // For testnets with ALL specified, append ExpToken
            if (chainConfig.isTestnet) {
                string[] memory testnetContracts = new string[](baseContracts.length + 1);
                for (uint256 i = 0; i < baseContracts.length; i++) {
                    testnetContracts[i] = baseContracts[i];
                }
                testnetContracts[baseContracts.length] = "ExpToken";
                chainConfig.contracts = testnetContracts;
            } else {
                // For non-testnets, use base contracts (no ExpToken)
                chainConfig.contracts = baseContracts;
            }
        } else {
            chainConfig.contracts = contractsList;
        }

        return chainConfig;
    }

    /**
     * @notice Get all available contracts (excluding ExpToken)
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
     * @notice Load deployed contracts from config
     */
    function loadDeployedContracts() internal {
        for (uint256 i = 0; i < targetChainIds.length; i++) {
            uint256 chainId = targetChainIds[i];

            DeployedContracts memory deployed;
            
            // Read deployed contract addresses from config, defaulting to address(0) if not set
            deployed.orchestrator = tryGetAddress(chainId, "orchestrator_deployed");
            deployed.ithacaAccount = tryGetAddress(chainId, "ithaca_account_deployed");
            deployed.accountProxy = tryGetAddress(chainId, "account_proxy_deployed");
            deployed.escrow = tryGetAddress(chainId, "escrow_deployed");
            deployed.simpleSettler = tryGetAddress(chainId, "simple_settler_deployed");
            deployed.layerZeroSettler = tryGetAddress(chainId, "layerzero_settler_deployed");
            deployed.simpleFunder = tryGetAddress(chainId, "simple_funder_deployed");
            deployed.simulator = tryGetAddress(chainId, "simulator_deployed");
            deployed.expToken = tryGetAddress(chainId, "exp_token_deployed");
            deployed.exp2Token = tryGetAddress(chainId, "exp2_token_deployed");

            deployedContracts[chainId] = deployed;
        }
    }
    
    /**
     * @notice Try to get an address from config, return address(0) if not found
     */
    function tryGetAddress(uint256 chainId, string memory key) internal view returns (address) {
        Variable memory variable = config.get(chainId, key);
        // Check if variable exists (TypeKind.None means missing key)
        if (variable.ty.kind == TypeKind.None) {
            return address(0);
        }
        return variable.toAddress();
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
            console.log("L0 Settler Signer:", config.l0SettlerSigner);
            console.log("Settler Owner:", config.settlerOwner);
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
     * @notice Save deployed contract address to config
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
        } else if (keccak256(bytes(contractName)) == keccak256("ExpToken")) {
            deployedContracts[chainId].expToken = contractAddress;
        } else if (keccak256(bytes(contractName)) == keccak256("Exp2Token")) {
            deployedContracts[chainId].exp2Token = contractAddress;
        }

        // Only write to config file during actual broadcasts, not simulations
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            if (keccak256(bytes(contractName)) == keccak256("Orchestrator")) {
                config.set(chainId, "orchestrator_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("IthacaAccount")) {
                config.set(chainId, "ithaca_account_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("AccountProxy")) {
                config.set(chainId, "account_proxy_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("Simulator")) {
                config.set(chainId, "simulator_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("SimpleFunder")) {
                config.set(chainId, "simple_funder_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("Escrow")) {
                config.set(chainId, "escrow_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("SimpleSettler")) {
                config.set(chainId, "simple_settler_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("LayerZeroSettler")) {
                config.set(chainId, "layerzero_settler_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("ExpToken")) {
                config.set(chainId, "exp_token_deployed", contractAddress);
            } else if (keccak256(bytes(contractName)) == keccak256("Exp2Token")) {
                config.set(chainId, "exp2_token_deployed", contractAddress);
            }
        }
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
        } else if (nameHash == keccak256("ExpToken")) {
            deployExpToken(chainId, config, deployed);
        } else {
            console.log("Warning: Unknown contract name:", contractName);
        }
    }

    function deployOrchestrator(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        bytes memory creationCode = type(Orchestrator).creationCode;
        address orchestrator =
            deployContractWithCreate2(chainId, creationCode, "", "Orchestrator");

        saveDeployedContract(chainId, "Orchestrator", orchestrator);
        deployed.orchestrator = orchestrator;
    }

    function deployIthacaAccount(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        // Ensure Orchestrator is deployed first (dependency)
        require(deployed.orchestrator != address(0), "Orchestrator must be deployed before IthacaAccount");

        bytes memory creationCode = type(IthacaAccount).creationCode;
        bytes memory args = abi.encode(deployed.orchestrator);
        address ithacaAccount =
            deployContractWithCreate2(chainId, creationCode, args, "IthacaAccount");

        saveDeployedContract(chainId, "IthacaAccount", ithacaAccount);
        deployed.ithacaAccount = ithacaAccount;
    }

    function deployAccountProxy(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        // Ensure IthacaAccount is deployed first (dependency)
        require(deployed.ithacaAccount != address(0), "IthacaAccount must be deployed before AccountProxy");

        bytes memory proxyCode = LibEIP7702.proxyInitCode(deployed.ithacaAccount, address(0));
        address accountProxy = deployContractWithCreate2(chainId, proxyCode, "", "AccountProxy");

        require(accountProxy != address(0), "Account proxy deployment failed");
        saveDeployedContract(chainId, "AccountProxy", accountProxy);
        deployed.accountProxy = accountProxy;
    }

    function deploySimulator(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        bytes memory creationCode = type(Simulator).creationCode;
        address simulator = deployContractWithCreate2(chainId, creationCode, "", "Simulator");

        saveDeployedContract(chainId, "Simulator", simulator);
        deployed.simulator = simulator;
    }

    function deploySimpleFunder(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        bytes memory creationCode = type(SimpleFunder).creationCode;

        bytes memory args = abi.encode(config.funderSigner, config.funderOwner);
        address funder = deployContractWithCreate2(chainId, creationCode, args, "SimpleFunder");

        saveDeployedContract(chainId, "SimpleFunder", funder);
        deployed.simpleFunder = funder;
    }

    function deployEscrow(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        bytes memory creationCode = type(Escrow).creationCode;
        address escrow = deployContractWithCreate2(chainId, creationCode, "", "Escrow");

        saveDeployedContract(chainId, "Escrow", escrow);
        deployed.escrow = escrow;
    }

    function deploySimpleSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        bytes memory creationCode = type(SimpleSettler).creationCode;
        bytes memory args = abi.encode(config.settlerOwner);
        address settler =
            deployContractWithCreate2(chainId, creationCode, args, "SimpleSettler");

        console.log("  Owner:", config.settlerOwner);
        saveDeployedContract(chainId, "SimpleSettler", settler);
        deployed.simpleSettler = settler;
    }

    function deployLayerZeroSettler(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        bytes memory creationCode = type(LayerZeroSettler).creationCode;
        bytes memory args = abi.encode(config.l0SettlerOwner, config.l0SettlerSigner);
        address settler =
            deployContractWithCreate2(chainId, creationCode, args, "LayerZeroSettler");

        console.log("  Owner:", config.l0SettlerOwner);
        console.log("  L0SettlerSigner:", config.l0SettlerSigner);
        console.log("  Endpoint to be configured:", config.layerZeroEndpoint);
        console.log("  EID:", config.layerZeroEid);
        console.log(
            "  Note: Endpoint must be set by owner via ConfigureLayerZeroSettler script"
        );

        saveDeployedContract(chainId, "LayerZeroSettler", settler);
        deployed.layerZeroSettler = settler;
    }

    function deployExpToken(
        uint256 chainId,
        ChainConfig memory config,
        DeployedContracts memory deployed
    ) internal {
        // Only deploy on testnets
        if (!config.isTestnet) {
            console.log("Skipping ExpToken deployment - not a testnet");
            return;
        }

        bytes memory creationCode = type(ExperimentERC20).creationCode;

        // Deploy EXP token
        // Hardcode name and symbol to "EXP"
        bytes memory args = abi.encode("EXP", "EXP", 1 ether);
        address expToken = deployContractWithCreate2(chainId, creationCode, args, "ExpToken");

        // Mint initial tokens to the configured minter address
        ExperimentERC20(payable(expToken)).mint(config.expMinterAddress, config.expMintAmount);

        console.log("  EXP Name/Symbol: EXP");
        console.log("  EXP Address:", expToken);
        saveDeployedContract(chainId, "ExpToken", expToken);
        deployed.expToken = expToken;

        // Deploy EXP2 token
        // Hardcode name and symbol to "EXP2"
        bytes memory args2 = abi.encode("EXP2", "EXP2", 1 ether);
        address exp2Token = deployContractWithCreate2(chainId, creationCode, args2, "Exp2Token");

        // Mint initial tokens to the configured minter address (same as EXP)
        ExperimentERC20(payable(exp2Token)).mint(config.expMinterAddress, config.expMintAmount);

        console.log("  EXP2 Name/Symbol: EXP2");
        console.log("  EXP2 Address:", exp2Token);
        console.log("  Minter:", config.expMinterAddress);
        console.log("  Mint Amount (each):", config.expMintAmount);
        saveDeployedContract(chainId, "Exp2Token", exp2Token);
        deployed.exp2Token = exp2Token;
    }
}
