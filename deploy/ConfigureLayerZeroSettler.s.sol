// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Script.sol";
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
contract ConfigureLayerZeroSettler is Script {
    // Configuration type constants (matching ULN302)
    uint32 constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 constant CONFIG_TYPE_ULN = 2;

    struct LayerZeroChainConfig {
        uint256 chainId;
        string name;
        address layerZeroSettlerAddress;
        address layerZeroEndpoint;
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
    mapping(uint256 => LayerZeroChainConfig) public chainConfigs;
    uint256[] public configuredChainIds;

    /**
     * @notice Configure all chains with LayerZero configuration
     */
    function run() external {
        // Get all chain IDs from fork configuration
        uint256[] memory chainIds = vm.readForkChainIds();
        run(chainIds);
    }

    /**
     * @notice Configure specific chains
     */
    function run(uint256[] memory chainIds) public {
        console.log("=== LayerZero Configuration Starting ===");
        console.log("Loading configuration from deploy/config.toml");
        console.log("Configuring", chainIds.length, "chains");

        // Load configurations for all chains
        loadConfigurations(chainIds);

        // Create forks for all chains that have LayerZero config
        createForks();

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

            // Create fork to read configuration
            string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
            uint256 forkId = vm.createFork(rpcUrl);
            vm.selectFork(forkId);

            // Try to load LayerZero configuration
            LayerZeroChainConfig memory config = loadChainConfig(chainId);

            // Only store if chain has LayerZero configuration
            if (config.sendUln302 != address(0)) {
                chainConfigs[chainId] = config;
                configuredChainIds.push(chainId);
                forkIds[chainId] = forkId;

                console.log(
                    string.concat(
                        "  Loaded LayerZero config for ",
                        config.name,
                        " (",
                        vm.toString(chainId),
                        ")"
                    )
                );
            }
        }

        console.log("Found LayerZero configuration for", configuredChainIds.length, "chains");
    }

    /**
     * @notice Load configuration for a single chain from fork variables
     */
    function loadChainConfig(uint256 chainId)
        internal
        view
        returns (LayerZeroChainConfig memory config)
    {
        config.chainId = chainId;

        // Load basic chain info - required
        config.name = vm.readForkString("name");

        // Try to load LayerZero settler address - if not present, this chain doesn't have LayerZero config
        try vm.readForkAddress("layerzero_settler_address") returns (address addr) {
            config.layerZeroSettlerAddress = addr;
        } catch {
            // No LayerZero settler configured for this chain - this is ok, return empty config
            return config;
        }

        // If we have a LayerZero settler, all other LayerZero fields are required
        config.layerZeroEndpoint = vm.readForkAddress("layerzero_endpoint");
        config.eid = uint32(vm.readForkUint("layerzero_eid"));
        config.sendUln302 = vm.readForkAddress("layerzero_send_uln302");
        config.receiveUln302 = vm.readForkAddress("layerzero_receive_uln302");

        // Load destination chain IDs - required for LayerZero configuration
        config.destinationChainIds = vm.readForkUintArray("layerzero_destination_chain_ids");

        // Load DVN configuration - required and optional DVN arrays
        string[] memory requiredDVNNames = vm.readForkStringArray("layerzero_required_dvns");
        string[] memory optionalDVNNames = vm.readForkStringArray("layerzero_optional_dvns");

        // Resolve DVN names to addresses
        config.requiredDVNs = resolveDVNAddresses(requiredDVNNames);
        config.optionalDVNs = resolveDVNAddresses(optionalDVNNames);

        // Load optional DVN threshold - required field
        config.optionalDVNThreshold = uint8(vm.readForkUint("layerzero_optional_dvn_threshold"));

        // Load confirmations - required field
        config.confirmations = uint64(vm.readForkUint("layerzero_confirmations"));

        // Load max message size - required field
        config.maxMessageSize = uint32(vm.readForkUint("layerzero_max_message_size"));

        return config;
    }

    /**
     * @notice Resolve DVN names to addresses by reading from fork variables
     * @dev Takes DVN variable names and looks up their addresses using vm.readForkAddress
     * @param dvnNames Array of DVN variable names from config (e.g., "dvn_layerzero_labs")
     * @return addresses Array of resolved DVN addresses
     */
    function resolveDVNAddresses(string[] memory dvnNames)
        internal
        view
        returns (address[] memory)
    {
        address[] memory addresses = new address[](dvnNames.length);

        for (uint256 i = 0; i < dvnNames.length; i++) {
            addresses[i] = vm.readForkAddress(dvnNames[i]);
            require(
                addresses[i] != address(0),
                string.concat("DVN address not configured for: ", dvnNames[i])
            );
        }

        return addresses;
    }

    /**
     * @notice Create forks for all configured chains
     */
    function createForks() internal {
        console.log("\n=== Creating forks for configured chains ===");

        for (uint256 i = 0; i < configuredChainIds.length; i++) {
            uint256 chainId = configuredChainIds[i];
            LayerZeroChainConfig memory config = chainConfigs[chainId];

            console.log("  Fork created for", config.name, "fork ID:", forkIds[chainId]);
        }
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
        console.log("  EID:", config.eid);

        // Switch to the source chain
        vm.selectFork(forkIds[chainId]);

        LayerZeroSettler settler = LayerZeroSettler(payable(config.layerZeroSettlerAddress));
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(config.layerZeroEndpoint);

        // Configure pathways to all destinations
        for (uint256 i = 0; i < config.destinationChainIds.length; i++) {
            uint256 destChainId = config.destinationChainIds[i];

            // Skip if destination not configured
            if (forkIds[destChainId] == 0) {
                console.log("  Skipping unconfigured destination:", destChainId);
                continue;
            }

            LayerZeroChainConfig memory destConfig = chainConfigs[destChainId];

            console.log(string.concat("\n  Configuring pathway to ", destConfig.name));
            console.log("    Destination EID:", destConfig.eid);

            // Set executor config (self-execution model)
            setExecutorConfig(settler, endpoint, destConfig.eid);

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
            vm.selectFork(forkIds[destChainId]);

            // Set receive ULN config on destination
            setReceiveUlnConfig(
                LayerZeroSettler(payable(destConfig.layerZeroSettlerAddress)),
                ILayerZeroEndpointV2(destConfig.layerZeroEndpoint),
                config.eid, // Source EID
                destConfig.receiveUln302,
                destConfig.requiredDVNs,
                destConfig.optionalDVNs,
                destConfig.optionalDVNThreshold,
                destConfig.confirmations
            );

            // Switch back to source chain
            vm.selectFork(forkIds[chainId]);
        }

        console.log("\n  Configuration complete for", config.name);
    }

    // ============================================
    // CONFIGURATION FUNCTIONS
    // ============================================

    function setExecutorConfig(
        LayerZeroSettler settler,
        ILayerZeroEndpointV2 endpoint,
        uint32 destEid
    ) internal {
        // LayerZeroSettler uses self-execution model, no executor config needed
        console.log("    Using self-execution model (no executor config)");
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
        address l0SettlerOwner = vm.readForkAddress("l0_settler_owner");
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
