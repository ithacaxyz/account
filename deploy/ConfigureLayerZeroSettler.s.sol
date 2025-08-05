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
import {LayerZeroConfig} from "./LayerZeroConfig.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title ConfigureLayerZeroSettler
 * @notice Configuration script for LayerZeroSettler using ULN302
 * @dev Uses vm.createSelectFork to configure all chains from a single execution
 *
 * Fork switching pattern:
 * 1. For each source chain:
 *    - Fork to source chain
 *    - Configure SEND pathways to all destinations
 * 2. For each destination of that source:
 *    - Fork to destination chain
 *    - Configure RECEIVE pathway from the source
 *
 * This ensures configurations are set on the correct chains where they're needed.
 *
 * Usage:
 * # Configure all chains in LayerZeroConfig
 * forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
 *  --broadcast \
 * --slow \
 * --sig "run()" \
 * --private-key $PRIVATE_KEY
 *
 * # Configure specific chains
 * forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[8453,10]"
 */
contract ConfigureLayerZeroSettler is Script {
    // Configuration type constants (matching ULN302)
    uint32 constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 constant CONFIG_TYPE_ULN = 2;

    // LayerZero configuration
    LayerZeroConfig public configContract;

    // Fork ids
    mapping(uint256 => uint256) public forkIds;

    struct ConfigData {
        address[] requiredDVNAddresses;
        address[] optionalDVNAddresses;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
    }

    function run() external {
        // Configure all chains
        uint256[] memory chainIds = new uint256[](0);
        configureChains(chainIds);
    }

    function run(uint256[] memory chainIds) external {
        // Configure specific chains
        configureChains(chainIds);
    }

    function configureChains(uint256[] memory requestedChainIds) internal {
        // Deploy config contract once BEFORE any fork (it's a pure contract, chain-independent)
        configContract = new LayerZeroConfig();
        LayerZeroConfig.ChainConfig[] memory allConfigs = configContract.getConfigs();

        // Get LayerZero settler address from config
        address layerZeroSettler = configContract.LAYER_ZERO_SETTLER();
        if (layerZeroSettler == address(0)) {
            revert("LayerZeroSettler address not set in config");
        }

        console.log("=== LayerZero Configuration Starting ===");
        console.log("LayerZeroSettler address:", layerZeroSettler);

        // Determine which chains to configure
        uint256[] memory chainIds = getChainIdsToProcess(requestedChainIds, allConfigs);
        console.log("Configuring", chainIds.length, "chains");

        populateChainForks(chainIds);

        for (uint256 i = 0; i < chainIds.length; i++) {
            configureChain(chainIds[i], layerZeroSettler);
        }

        console.log("\n=== LayerZero Configuration Complete ===");
    }

    function populateChainForks(uint256[] memory chainIds) internal {
        for (uint256 i = 0; i < chainIds.length; i++) {
            string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainIds[i])));
            uint256 id = vm.createSelectFork(rpcUrl);
            forkIds[chainIds[i]] = id;
        }
    }

    function getChainIdsToProcess(
        uint256[] memory requestedChainIds,
        LayerZeroConfig.ChainConfig[] memory allConfigs
    ) internal pure returns (uint256[] memory) {
        if (requestedChainIds.length == 0) {
            // Return all chain IDs from config
            uint256[] memory allChainIds = new uint256[](allConfigs.length);
            for (uint256 i = 0; i < allConfigs.length; i++) {
                allChainIds[i] = allConfigs[i].chainId;
            }
            return allChainIds;
        }

        // Filter requested chains that exist in config
        uint256 count = 0;
        for (uint256 i = 0; i < requestedChainIds.length; i++) {
            if (hasConfig(requestedChainIds[i], allConfigs)) {
                count++;
            }
        }

        uint256[] memory validChainIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < requestedChainIds.length; i++) {
            if (hasConfig(requestedChainIds[i], allConfigs)) {
                validChainIds[index++] = requestedChainIds[i];
            }
        }

        return validChainIds;
    }

    function hasConfig(uint256 chainId, LayerZeroConfig.ChainConfig[] memory allConfigs)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < allConfigs.length; i++) {
            if (allConfigs[i].chainId == chainId) {
                return true;
            }
        }
        return false;
    }

    function getConfig(uint256 chainId)
        internal
        view
        returns (LayerZeroConfig.ChainConfig memory)
    {
        LayerZeroConfig.ChainConfig[] memory allConfigs = configContract.getConfigs();
        for (uint256 i = 0; i < allConfigs.length; i++) {
            if (allConfigs[i].chainId == chainId) {
                return allConfigs[i];
            }
        }
        revert("No config for chain");
    }

    function configureChain(uint256 sourceChainId, address layerZeroSettler) internal {
        LayerZeroConfig.ChainConfig memory sourceConfig = getConfig(sourceChainId);

        console.log("\n=== Configuring chain", configContract.getChainName(sourceChainId), "===");
        console.log("Chain ID:", sourceChainId);
        console.log("EID:", configContract.getEid(sourceChainId));

        vm.selectFork(forkIds[sourceChainId]);

        // Verify we're on the correct chain
        require(block.chainid == sourceChainId, "Source chain ID mismatch");

        // Get the endpoint from the settler on source chain
        LayerZeroSettler sourceSettler = LayerZeroSettler(payable(layerZeroSettler));
        ILayerZeroEndpointV2 sourceEndpoint = ILayerZeroEndpointV2(sourceSettler.endpoint());

        console.log("Source endpoint address:", address(sourceEndpoint));

        // Configure send pathways to all destination chains
        configureSendPathways(sourceEndpoint, sourceSettler, sourceConfig);

        // Step 2: For each destination, fork to destination chain and configure RECEIVE pathways
        for (uint256 i = 0; i < sourceConfig.destinationChainIds.length; i++) {
            uint256 destChainId = sourceConfig.destinationChainIds[i];

            console.log(
                "\n  -> Switching to destination chain",
                configContract.getChainName(destChainId),
                "for receive configuration"
            );

            vm.selectFork(forkIds[destChainId]);

            // Verify we're on the correct destination chain
            require(block.chainid == destChainId, "Destination chain ID mismatch");

            // Get the endpoint from the settler on destination chain
            LayerZeroSettler destSettler = LayerZeroSettler(payable(layerZeroSettler));
            ILayerZeroEndpointV2 destEndpoint = ILayerZeroEndpointV2(destSettler.endpoint());

            // Configure this destination to receive from the source chain
            configureReceivePathway(destEndpoint, destSettler, destChainId, sourceChainId);
        }
    }

    function configureSendPathways(
        ILayerZeroEndpointV2 endpoint,
        LayerZeroSettler settler,
        LayerZeroConfig.ChainConfig memory config
    ) internal {
        uint256 destinationCount = config.destinationChainIds.length;

        if (destinationCount == 0) {
            console.log("No destination chains to configure");
            return;
        }

        console.log("\nConfiguring SEND pathways to", destinationCount, "destinations");

        // Resolve DVN addresses
        ConfigData memory configData = ConfigData({
            requiredDVNAddresses: configContract.getDVNAddresses(config.requiredDVNs, config.chainId),
            optionalDVNAddresses: configContract.getDVNAddresses(config.optionalDVNs, config.chainId),
            requiredDVNCount: uint8(config.requiredDVNs.length),
            optionalDVNCount: uint8(config.optionalDVNs.length)
        });

        // Log DVN addresses
        logDVNAddresses(config, configData);

        // Prepare send configurations for all destinations
        SetConfigParam[] memory sendParams = new SetConfigParam[](destinationCount * 2);

        for (uint256 i = 0; i < destinationCount; i++) {
            uint256 remoteChainId = config.destinationChainIds[i];
            uint32 remoteEid = configContract.getEid(remoteChainId);

            console.log("  -> Configuring send to", configContract.getChainName(remoteChainId));

            // Executor configuration (maxMessageSize first, then executor)
            bytes memory executorConfig = abi.encode(config.maxMessageSize, config.executor);

            // Create UlnConfig struct first
            UlnConfig memory ulnConfigStruct = UlnConfig({
                confirmations: uint64(1), // TODO: Set this to config.confirmations
                requiredDVNCount: configData.requiredDVNCount,
                optionalDVNCount: configData.optionalDVNCount,
                optionalDVNThreshold: config.optionalDVNThreshold,
                requiredDVNs: configData.requiredDVNAddresses,
                optionalDVNs: configData.optionalDVNAddresses
            });

            // Encode the struct
            bytes memory ulnConfig = abi.encode(ulnConfigStruct);

            sendParams[i * 2] = SetConfigParam({
                eid: remoteEid,
                configType: CONFIG_TYPE_EXECUTOR,
                config: executorConfig
            });

            sendParams[i * 2 + 1] =
                SetConfigParam({eid: remoteEid, configType: CONFIG_TYPE_ULN, config: ulnConfig});
        }

        // Execute send configuration
        vm.startBroadcast();
        console.log("Setting send configurations...");
        endpoint.setConfig(address(settler), config.sendUln302, sendParams);
        vm.stopBroadcast();

        console.log(unicode"✓ Send pathways configured");
    }

    function configureReceivePathway(
        ILayerZeroEndpointV2 endpoint,
        LayerZeroSettler settler,
        uint256 destChainId,
        uint256 sourceChainId
    ) internal {
        console.log("    <- Configuring receive from", configContract.getChainName(sourceChainId));

        // Get destination chain config to use its DVN settings
        LayerZeroConfig.ChainConfig memory destConfig = getConfig(destChainId);

        // Resolve DVN addresses for the destination chain
        ConfigData memory configData = ConfigData({
            requiredDVNAddresses: configContract.getDVNAddresses(destConfig.requiredDVNs, destChainId),
            optionalDVNAddresses: configContract.getDVNAddresses(destConfig.optionalDVNs, destChainId),
            requiredDVNCount: uint8(destConfig.requiredDVNs.length),
            optionalDVNCount: uint8(destConfig.optionalDVNs.length)
        });

        // Get source EID
        uint32 sourceEid = configContract.getEid(sourceChainId);

        // Create UlnConfig struct first
        UlnConfig memory ulnConfigStruct = UlnConfig({
            confirmations: uint64(1), // TODO: Set this to destConfig.confirmations
            requiredDVNCount: configData.requiredDVNCount,
            optionalDVNCount: configData.optionalDVNCount,
            optionalDVNThreshold: destConfig.optionalDVNThreshold,
            requiredDVNs: configData.requiredDVNAddresses,
            optionalDVNs: configData.optionalDVNAddresses
        });

        // Encode the struct
        bytes memory ulnConfig = abi.encode(ulnConfigStruct);

        // Prepare single receive configuration
        SetConfigParam[] memory receiveParams = new SetConfigParam[](1);
        receiveParams[0] =
            SetConfigParam({eid: sourceEid, configType: CONFIG_TYPE_ULN, config: ulnConfig});

        // Execute receive configuration
        vm.startBroadcast();
        console.log("    Setting receive configuration...");
        endpoint.setConfig(address(settler), destConfig.receiveUln302, receiveParams);
        vm.stopBroadcast();

        console.log(unicode"    ✓ Receive pathway configured");
    }

    function logDVNAddresses(
        LayerZeroConfig.ChainConfig memory config,
        ConfigData memory configData
    ) internal view {
        console.log("DVN addresses for chain", config.chainId);

        if (configData.requiredDVNAddresses.length > 0) {
            console.log("Required DVNs:");
            for (uint256 i = 0; i < configData.requiredDVNAddresses.length; i++) {
                string memory dvnName = configContract.getDVNName(config.requiredDVNs[i]);
                console.log("  ", dvnName, ":", configData.requiredDVNAddresses[i]);
            }
        }

        if (configData.optionalDVNAddresses.length > 0) {
            console.log("Optional DVNs:");
            for (uint256 i = 0; i < configData.optionalDVNAddresses.length; i++) {
                string memory dvnName = configContract.getDVNName(config.optionalDVNs[i]);
                console.log("  ", dvnName, ":", configData.optionalDVNAddresses[i]);
            }
        }
    }
}
