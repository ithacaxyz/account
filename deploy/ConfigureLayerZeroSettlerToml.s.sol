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
 * @title ConfigureLayerZeroSettlerToml
 * @notice Configuration script for LayerZeroSettler using fork cheatcodes
 * @dev Uses Foundry's new fork* cheatcodes to read configuration from active forks
 *      Note: This script must be run by the LayerZeroSettler's delegate (owner)
 *
 * Usage:
 * # Configure specific chains (requires L0_SETTLER_OWNER_PK in env)
 * forge script deploy/ConfigureLayerZeroSettlerToml.s.sol:ConfigureLayerZeroSettlerToml \
 *   --broadcast \
 *   --slow \
 *   --sig "run(uint256[])" \
 *   --private-key $L0_SETTLER_OWNER_PK \
 *   "[84532,11155420]"
 */
contract ConfigureLayerZeroSettlerToml is Script {
    // Configuration type constants (matching ULN302)
    uint32 constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 constant CONFIG_TYPE_ULN = 2;

    struct LayerZeroChainConfig {
        uint256 chainId;
        address sendUln302;
        address receiveUln302;
        uint256[] destinationChainIds;
        address[] requiredDVNs;
        address[] optionalDVNs;
        uint8 optionalDVNThreshold;
        uint64 confirmations;
        uint32 maxMessageSize;
        uint32 eid;
    }

    // Fork ids for chain switching
    mapping(uint256 => uint256) public forkIds;
    mapping(uint256 => string) public forkNames;

    /**
     * @notice Configure specific chains
     */
    function run(uint256[] memory chainIds) external {
        console.log("=== LayerZero Configuration Starting (Fork Cheatcodes) ===");
        console.log("Configuring", chainIds.length, "chains");

        // Create forks for all chains
        createForks(chainIds);

        // Configure each chain
        for (uint256 i = 0; i < chainIds.length; i++) {
            configureChain(chainIds[i]);
        }

        console.log("\n=== LayerZero Configuration Complete ===");
    }

    /**
     * @notice Create forks for all chains
     */
    function createForks(uint256[] memory chainIds) internal {
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Get RPC URL from environment variable following the RPC_{chainId} pattern
            string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));

            // Create fork
            uint256 forkId = vm.createFork(rpcUrl);
            forkIds[chainId] = forkId;

            // Store fork name for later use
            vm.selectFork(forkId);
            forkNames[chainId] = vm.forkString("name");

            console.log("  Created fork for chain", chainId, "fork ID:", forkId);
        }
    }

    /**
     * @notice Configure a single chain
     */
    function configureChain(uint256 chainId) internal {
        console.log("\n-------------------------------------");
        console.log("Configuring chain:", chainId);

        // Switch to the source chain
        vm.selectFork(forkIds[chainId]);

        // Get LayerZero config for this chain using fork cheatcodes
        LayerZeroChainConfig memory config = getLayerZeroChainConfig(chainId);

        if (config.sendUln302 == address(0)) {
            console.log("  No LayerZero configuration found for chain", chainId);
            return;
        }

        // Get the LayerZero settler address
        address layerZeroSettler = vm.forkAddress("layerzero_settler_address");
        require(layerZeroSettler != address(0), "LayerZeroSettler address not set in config");

        LayerZeroSettler settler = LayerZeroSettler(payable(layerZeroSettler));
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(settler.endpoint());

        console.log("  LayerZeroSettler:", layerZeroSettler);
        console.log("  Endpoint:", address(endpoint));

        // Configure pathways to all destinations
        for (uint256 i = 0; i < config.destinationChainIds.length; i++) {
            uint256 destChainId = config.destinationChainIds[i];

            // Switch to destination chain to get its EID
            vm.selectFork(forkIds[destChainId]);
            uint32 destEid = uint32(vm.forkUint("layerzero_eid"));

            // Switch back to source chain
            vm.selectFork(forkIds[chainId]);

            console.log("  Configuring pathway to chain", destChainId, "EID:", destEid);

            // Set executor config
            setExecutorConfig(settler, endpoint, destEid, layerZeroSettler);

            // Set ULN config for sending
            setSendUlnConfig(
                settler,
                endpoint,
                destEid,
                config.sendUln302,
                config.requiredDVNs,
                config.optionalDVNs,
                config.optionalDVNThreshold,
                config.confirmations
            );

            // Switch to destination chain to set receive config
            vm.selectFork(forkIds[destChainId]);

            // Get destination chain's receive config
            LayerZeroChainConfig memory destConfig = getLayerZeroChainConfig(destChainId);

            // Set receive ULN config
            setReceiveUlnConfig(
                LayerZeroSettler(payable(layerZeroSettler)),
                ILayerZeroEndpointV2(LayerZeroSettler(payable(layerZeroSettler)).endpoint()),
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

        console.log("  Chain", chainId, "configuration complete");
    }

    /**
     * @notice Get LayerZero configuration for a chain using fork cheatcodes
     */
    function getLayerZeroChainConfig(uint256 chainId)
        internal
        view
        returns (LayerZeroChainConfig memory config)
    {
        config.chainId = chainId;

        // Read from fork variables
        try vm.forkAddress("layerzero_send_uln302") returns (address sendUln) {
            config.sendUln302 = sendUln;
        } catch {
            // No LayerZero config for this chain
            return config;
        }

        config.receiveUln302 = vm.forkAddress("layerzero_receive_uln302");
        config.eid = uint32(vm.forkUint("layerzero_eid"));
        config.confirmations = uint64(vm.forkUint("layerzero_confirmations"));
        config.maxMessageSize = uint32(vm.forkUint("layerzero_max_message_size"));
        config.optionalDVNThreshold = uint8(vm.forkUint("layerzero_optional_dvn_threshold"));

        // For now, hardcode destination chain IDs based on the source chain
        // Base Sepolia -> Optimism Sepolia
        // Optimism Sepolia -> Base Sepolia
        if (chainId == 84532) {
            config.destinationChainIds = new uint256[](1);
            config.destinationChainIds[0] = 11155420;
        } else if (chainId == 11155420) {
            config.destinationChainIds = new uint256[](1);
            config.destinationChainIds[0] = 84532;
        } else {
            config.destinationChainIds = new uint256[](0);
        }

        // Get required DVN - for now just LayerZero Labs DVN
        config.requiredDVNs = new address[](1);
        config.requiredDVNs[0] = vm.forkAddress("dvn_layerzero_labs");

        // No optional DVNs for now
        config.optionalDVNs = new address[](0);

        return config;
    }

    // ============================================
    // CONFIGURATION FUNCTIONS
    // ============================================

    function setExecutorConfig(
        LayerZeroSettler settler,
        ILayerZeroEndpointV2 endpoint,
        uint32 destEid,
        address layerZeroSettler
    ) internal {
        // LayerZeroSettler uses self-execution model, no executor config needed
        console.log("    Skipping executor config (self-execution model)");
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

        // The endpoint.setConfig must be called by the delegate of the OApp
        // The L0 settler owner should have been set as the delegate
        address l0SettlerOwner = vm.forkAddress("l0_settler_owner");
        console.log("    L0 Settler Owner (should be delegate):", l0SettlerOwner);
        console.log("    Note: Ensure you're using the L0_SETTLER_OWNER_PK private key");

        vm.broadcast();
        endpoint.setConfig(address(settler), sendUln302, params);
        console.log("    Send ULN config set");
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
        console.log("    Receive ULN config set");
    }
}
