// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {ILayerZeroEndpointV2} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from
    "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from
    "../lib/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/uln/UlnBase.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title ConfigureLayerZeroSettler
 * @notice Configuration script for LayerZeroSettler using TOML configuration
 * @dev Reads all LayerZero configuration from deploy/config.toml
 *      Note: This script must be run by the LayerZeroSettler's delegate (owner)
 *
 * Usage:
 * # Configure all chains
 * source .env
 * forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run()" \
 *   --private-key $L0_SETTLER_OWNER_PK
 *
 * # Configure specific chains
 * forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run(uint256[])" \
 *   --private-key $L0_SETTLER_OWNER_PK \
 *   "[84532,11155420]"
 */
contract ConfigureLayerZeroSettler is Script, Config {
    // Configuration type constants (matching ULN302)
    uint32 constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 constant CONFIG_TYPE_ULN = 2;

    struct LayerZeroChainConfig {
        uint256 chainId;
        string name;
        address layerZeroSettlerAddress;
        address layerZeroEndpoint;
        address l0SettlerSigner;
        uint32 eid;
        address sendUln302;
        address receiveUln302;
        uint256[] destinationChainIds;
        address[] requiredDVNs;
        address[] optionalDVNs;
        uint8 optionalDVNThreshold;
        uint64 confirmations;
        uint32 maxMessageSize;
    }

    // Fork ids for chain switching
    mapping(uint256 => uint256) public forkIds;
    mapping(uint256 => bool) public isForkInitialized;
    mapping(uint256 => LayerZeroChainConfig) public chainConfigs;
    uint256[] public configuredChainIds;

    /**
     * @notice Configure all chains with LayerZero configuration
     */
    function run() external {
        // Load configuration and setup forks
        string memory configPath = string.concat(vm.projectRoot(), "/deploy/config.toml");
        _loadConfigAndForks(configPath, false);
        
        // Get all chain IDs from configuration
        uint256[] memory chainIds = config.getChainIds();
        run(chainIds);
    }

    /**
     * @notice Configure specific chains
     */
    function run(uint256[] memory chainIds) public {
        console.log("=== LayerZero Configuration Starting ===");
        console.log("Loading configuration from deploy/config.toml");
        console.log("Configuring", chainIds.length, "chains");

        // If config not already loaded, load it
        if (address(config) == address(0)) {
            string memory configPath = string.concat(vm.projectRoot(), "/deploy/config.toml");
            _loadConfigAndForks(configPath, false);
        }

        // Load configurations for all chains
        loadConfigurations(chainIds);

        // Configure each chain
        for (uint256 i = 0; i < configuredChainIds.length; i++) {
            configureChain(configuredChainIds[i]);
        }

        console.log("\n=== LayerZero Configuration Complete ===");
    }

    /**
     * @notice Load configurations for all chains from TOML
     */
    function loadConfigurations(uint256[] memory chainIds) internal {
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Switch to the fork for this chain (already created by _loadConfigAndForks)
            vm.selectFork(forkOf[chainId]);

            // Try to load LayerZero configuration
            LayerZeroChainConfig memory chainConfig = loadChainConfig(chainId);
            
            // Only add chains that have LayerZero configuration
            if (chainConfig.layerZeroSettlerAddress != address(0)) {
                chainConfigs[chainId] = chainConfig;
                configuredChainIds.push(chainId);
                forkIds[chainId] = forkOf[chainId];
                isForkInitialized[forkOf[chainId]] = true;

                console.log(
                    string.concat(
                        "  Loaded LayerZero config for ", chainConfig.name, " (", vm.toString(chainId), ")"
                    )
                );
            }
        }

        console.log("Found LayerZero configuration for", configuredChainIds.length, "chains");
    }

    /**
     * @notice Load configuration for a single chain using StdConfig
     */
    function loadChainConfig(uint256 chainId)
        internal
        view
        returns (LayerZeroChainConfig memory chainConfig)
    {
        chainConfig.chainId = chainId;

        // Load basic chain info - required
        chainConfig.name = config.get(chainId, "name").toString();

        // Try to load LayerZero settler deployed address first, then fall back to expected address
        address settlerAddr = config.get(chainId, "layerzero_settler_deployed").toAddress();
        if (settlerAddr == address(0)) {
            // Fall back to expected address from config
            settlerAddr = config.get(chainId, "layerzero_settler_address").toAddress();
        }
        if (settlerAddr == address(0)) {
            // No LayerZero settler configured for this chain - this is ok, return empty config
            return chainConfig;
        }
        chainConfig.layerZeroSettlerAddress = settlerAddr;

        // If we have a LayerZero settler, all other LayerZero fields are required
        chainConfig.layerZeroEndpoint = config.get(chainId, "layerzero_endpoint").toAddress();
        chainConfig.l0SettlerSigner = config.get(chainId, "l0_settler_signer").toAddress();
        chainConfig.eid = uint32(config.get(chainId, "layerzero_eid").toUint256());
        chainConfig.sendUln302 = config.get(chainId, "layerzero_send_uln302").toAddress();
        chainConfig.receiveUln302 = config.get(chainId, "layerzero_receive_uln302").toAddress();

        // Load destination chain IDs - required for LayerZero configuration
        chainConfig.destinationChainIds = config.get(chainId, "layerzero_destination_chain_ids").toUint256Array();

        // Load DVN configuration - required and optional DVN arrays
        string[] memory requiredDVNNames = config.get(chainId, "layerzero_required_dvns").toStringArray();
        string[] memory optionalDVNNames = config.get(chainId, "layerzero_optional_dvns").toStringArray();

        // Resolve DVN names to addresses
        chainConfig.requiredDVNs = resolveDVNAddresses(chainId, requiredDVNNames);
        chainConfig.optionalDVNs = resolveDVNAddresses(chainId, optionalDVNNames);

        // Load optional DVN threshold - required field
        chainConfig.optionalDVNThreshold = uint8(config.get(chainId, "layerzero_optional_dvn_threshold").toUint256());

        // Load confirmations - required field
        chainConfig.confirmations = uint64(config.get(chainId, "layerzero_confirmations").toUint256());

        // Load max message size - required field
        chainConfig.maxMessageSize = uint32(config.get(chainId, "layerzero_max_message_size").toUint256());

        return chainConfig;
    }

    /**
     * @notice Resolve DVN names to addresses using StdConfig
     * @dev Takes DVN variable names and looks up their addresses using config.get
     * @param chainId The chain ID to resolve DVN addresses for
     * @param dvnNames Array of DVN variable names from config (e.g., "dvn_layerzero_labs")
     * @return addresses Array of resolved DVN addresses
     */
    function resolveDVNAddresses(uint256 chainId, string[] memory dvnNames)
        internal
        view
        returns (address[] memory)
    {
        address[] memory addresses = new address[](dvnNames.length);

        for (uint256 i = 0; i < dvnNames.length; i++) {
            addresses[i] = config.get(chainId, dvnNames[i]).toAddress();
            require(
                addresses[i] != address(0),
                string.concat("DVN address not configured for: ", dvnNames[i])
            );
        }

        return addresses;
    }

    function _selectFork(uint256 chainId) internal {
        vm.selectFork(forkOf[chainId]);
    }

    /**
     * @notice Configure a single chain
     */
    function configureChain(uint256 chainId) internal {
        LayerZeroChainConfig memory config = chainConfigs[chainId];

        console.log("\n-------------------------------------");
        console.log(string.concat("Configuring ", config.name, " (", vm.toString(chainId), ")"));
        console.log("  LayerZero Settler:", config.layerZeroSettlerAddress);
        console.log("  Endpoint:", config.layerZeroEndpoint);
        console.log("  L0SettlerSigner:", config.l0SettlerSigner);
        console.log("  EID:", config.eid);

        // Switch to the source chain
        _selectFork(chainId);

        LayerZeroSettler settler = LayerZeroSettler(payable(config.layerZeroSettlerAddress));

        // Set or update the endpoint on the settler
        address currentEndpoint = address(settler.endpoint());
        if (currentEndpoint != config.layerZeroEndpoint) {
            if (currentEndpoint == address(0)) {
                console.log("  Setting endpoint to:", config.layerZeroEndpoint);
            } else {
                console.log("  Updating endpoint from:", currentEndpoint);
                console.log("  To:", config.layerZeroEndpoint);
            }
            vm.broadcast();
            settler.setEndpoint(config.layerZeroEndpoint);
            console.log("  Endpoint configured successfully");
        } else {
            console.log("  Endpoint already set to:", config.layerZeroEndpoint);
        }

        // Set or update the L0SettlerSigner on the settler
        address currentSigner = settler.l0SettlerSigner();
        if (currentSigner != config.l0SettlerSigner) {
            if (currentSigner == address(0)) {
                console.log("  Setting L0SettlerSigner to:", config.l0SettlerSigner);
            } else {
                console.log("  Updating L0SettlerSigner from:", currentSigner);
                console.log("  To:", config.l0SettlerSigner);
            }
            vm.broadcast();
            settler.setL0SettlerSigner(config.l0SettlerSigner);
            console.log("  L0SettlerSigner configured successfully");
        } else {
            console.log("  L0SettlerSigner already set to:", config.l0SettlerSigner);
        }

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(config.layerZeroEndpoint);

        // Configure pathways to all destinations
        for (uint256 i = 0; i < config.destinationChainIds.length; i++) {
            uint256 destChainId = config.destinationChainIds[i];

            LayerZeroChainConfig memory destConfig = chainConfigs[destChainId];

            console.log(string.concat("\n  Configuring pathway to ", destConfig.name));
            console.log("    Destination EID:", destConfig.eid);

            // Set executor config (self-execution model)
            setExecutorConfig(config, settler, endpoint, destConfig.eid);

            // Set send ULN config
            setSendUlnConfig(
                settler,
                endpoint,
                destConfig.eid,
                config.sendUln302,
                config.requiredDVNs,
                config.optionalDVNs,
                config.optionalDVNThreshold,
                config.confirmations
            );

            // Switch to destination chain to set receive config
            _selectFork(destChainId);

            // Ensure destination settler has endpoint set before configuring
            LayerZeroSettler destSettler =
                LayerZeroSettler(payable(destConfig.layerZeroSettlerAddress));
            address currentDestEndpoint = address(destSettler.endpoint());
            if (currentDestEndpoint != destConfig.layerZeroEndpoint) {
                if (currentDestEndpoint == address(0)) {
                    console.log(
                        "      Setting endpoint on destination:", destConfig.layerZeroEndpoint
                    );
                } else {
                    console.log("      Updating endpoint on destination from:", currentDestEndpoint);
                    console.log("      To:", destConfig.layerZeroEndpoint);
                }
                vm.broadcast();
                destSettler.setEndpoint(destConfig.layerZeroEndpoint);
                console.log("      Destination endpoint configured successfully");
            } else {
                console.log("      Destination endpoint already set:", destConfig.layerZeroEndpoint);
            }

            // Set receive ULN config on destination
            setReceiveUlnConfig(
                destSettler,
                ILayerZeroEndpointV2(destConfig.layerZeroEndpoint),
                config.eid, // Source EID
                destConfig.receiveUln302,
                destConfig.requiredDVNs,
                destConfig.optionalDVNs,
                destConfig.optionalDVNThreshold,
                destConfig.confirmations
            );

            // Switch back to source chain
            _selectFork(chainId);
        }

        console.log("\n  Configuration complete for", config.name);
    }

    // ============================================
    // CONFIGURATION FUNCTIONS
    // ============================================

    function setExecutorConfig(
        LayerZeroChainConfig memory config,
        LayerZeroSettler settler,
        ILayerZeroEndpointV2 endpoint,
        uint32 destEid
    ) internal {
        console.log("    Setting executor config:");
        console.log("      Executor (self-execution):", address(settler));
        console.log("      Max message size:", config.maxMessageSize);
        console.log("      Send ULN302:", config.sendUln302);

        bytes memory executorConfig = abi.encode(config.maxMessageSize, settler);
        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] =
            SetConfigParam({eid: destEid, configType: CONFIG_TYPE_EXECUTOR, config: executorConfig});

        vm.broadcast();
        endpoint.setConfig(address(settler), config.sendUln302, params);
        console.log("      Executor config set");
    }

    function setSendUlnConfig(
        LayerZeroSettler settler,
        ILayerZeroEndpointV2 endpoint,
        uint32 destEid,
        address sendUln302,
        address[] memory requiredDVNs,
        address[] memory optionalDVNs,
        uint8 optionalDVNThreshold,
        uint64 confirmations
    ) internal {
        console.log("    Setting send ULN config:");
        console.log("      Send ULN302:", sendUln302);
        console.log("      Required DVNs:", requiredDVNs.length);
        if (requiredDVNs.length > 0) {
            console.log("        -", requiredDVNs[0]);
        }
        console.log("      Confirmations:", confirmations);

        UlnConfig memory ulnConfig = UlnConfig({
            confirmations: confirmations,
            requiredDVNCount: uint8(requiredDVNs.length),
            optionalDVNCount: uint8(optionalDVNs.length),
            optionalDVNThreshold: optionalDVNThreshold > 0
                ? optionalDVNThreshold
                : uint8(optionalDVNs.length),
            requiredDVNs: requiredDVNs,
            optionalDVNs: optionalDVNs
        });

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: destEid,
            configType: CONFIG_TYPE_ULN,
            config: abi.encode(ulnConfig)
        });

        // Get the L0 settler owner who should be the delegate
        address l0SettlerOwner = config.get(vm.getChainId(), "l0_settler_owner").toAddress();
        console.log("      L0 Settler Owner (delegate):", l0SettlerOwner);

        vm.broadcast();
        endpoint.setConfig(address(settler), sendUln302, params);
        console.log("      Send ULN config set");
    }

    function setReceiveUlnConfig(
        LayerZeroSettler settler,
        ILayerZeroEndpointV2 endpoint,
        uint32 sourceEid,
        address receiveUln302,
        address[] memory requiredDVNs,
        address[] memory optionalDVNs,
        uint8 optionalDVNThreshold,
        uint64 confirmations
    ) internal {
        console.log("    Setting receive ULN config:");
        console.log("      Receive ULN302:", receiveUln302);
        console.log("      Required DVNs:", requiredDVNs.length);
        if (requiredDVNs.length > 0) {
            console.log("        -", requiredDVNs[0]);
        }

        UlnConfig memory ulnConfig = UlnConfig({
            confirmations: confirmations,
            requiredDVNCount: uint8(requiredDVNs.length),
            optionalDVNCount: uint8(optionalDVNs.length),
            optionalDVNThreshold: optionalDVNThreshold > 0
                ? optionalDVNThreshold
                : uint8(optionalDVNs.length),
            requiredDVNs: requiredDVNs,
            optionalDVNs: optionalDVNs
        });

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: sourceEid,
            configType: CONFIG_TYPE_ULN,
            config: abi.encode(ulnConfig)
        });

        vm.broadcast();
        endpoint.setConfig(address(settler), receiveUln302, params);
        console.log("      Receive ULN config set");
    }
}
