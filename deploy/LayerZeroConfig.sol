// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LayerZeroRegistry} from "./LayerZeroRegistry.sol";

/**
 * @title LayerZeroConfig
 * @notice Configuration for LayerZero ULN302 settings across all chains
 * @dev Provides all configuration needed for sending messages FROM each chain
 */
contract LayerZeroConfig is LayerZeroRegistry {
    /**
     * @notice Complete configuration for sending messages FROM a specific chain
     * @dev Contains all addresses and settings needed when on this chain
     */
    struct ChainConfig {
        // Chain info
        uint256 chainId;
        // Destination chains this chain can send to
        uint256[] destinationChainIds; // Chain IDs of destination chains
        // Library addresses on this chain
        address sendUln302; // SendUln302 library address
        address receiveUln302; // ReceiveUln302 library address
        // Your custom executor on this chain
        address executor;
        // DVN identifiers (enum values - will be resolved dynamically)
        DVN[] requiredDVNs; // Required DVNs - all must verify
        DVN[] optionalDVNs; // Optional DVNs - only threshold needed
        uint8 optionalDVNThreshold; // How many optional DVNs must verify
        // Configuration values
        uint64 confirmations; // Block confirmations for messages FROM this chain
        uint32 maxMessageSize; // Max message size in bytes
    }

    address public constant LAYER_ZERO_SETTLER = 0x0000000000000000000000000000000000000000;

    /**
     * @notice Get configuration for all supported chains
     * @return configs Array of configurations for all chains
     */
    function getConfigs() public pure returns (ChainConfig[] memory configs) {
        configs = new ChainConfig[](4);

        // Get all chain IDs
        // TODO: Set all chain IDs that will be wired with each other here.
        uint256[] memory allChainIds = new uint256[](4);
        allChainIds[0] = 8453; // Base
        allChainIds[1] = 10; // Optimism
        allChainIds[2] = 84532; // Base Sepolia
        allChainIds[3] = 11155420; // Optimism Sepolia

        // Base
        configs[0] = ChainConfig({
            chainId: 8453,
            destinationChainIds: _getDestinationChainIds(allChainIds, 8453),
            sendUln302: 0x0000000000000000000000000000000000000000, // TODO: SendUln302 on Base
            receiveUln302: 0x0000000000000000000000000000000000000000, // TODO: ReceiveUln302 on Base
            executor: LAYER_ZERO_SETTLER,
            requiredDVNs: _getRequiredDVNs(),
            optionalDVNs: _getOptionalDVNs(),
            optionalDVNThreshold: 0,
            confirmations: 1, // Base has near-instant finality
            maxMessageSize: 10000
        });

        // Optimism
        configs[1] = ChainConfig({
            chainId: 10,
            destinationChainIds: _getDestinationChainIds(allChainIds, 10),
            sendUln302: 0x0000000000000000000000000000000000000000, // TODO: SendUln302 on Optimism
            receiveUln302: 0x0000000000000000000000000000000000000000, // TODO: ReceiveUln302 on Optimism
            executor: LAYER_ZERO_SETTLER,
            requiredDVNs: _getRequiredDVNs(),
            optionalDVNs: _getOptionalDVNs(),
            optionalDVNThreshold: 0,
            confirmations: 1, // Optimism has near-instant finality
            maxMessageSize: 10000
        });

        // Base Sepolia
        configs[2] = ChainConfig({
            chainId: 84532,
            destinationChainIds: _getDestinationChainIds(allChainIds, 84532),
            sendUln302: 0x0000000000000000000000000000000000000000, // TODO: SendUln302 on Base Sepolia
            receiveUln302: 0x0000000000000000000000000000000000000000, // TODO: ReceiveUln302 on Base Sepolia
            executor: LAYER_ZERO_SETTLER,
            requiredDVNs: _getRequiredDVNs(),
            optionalDVNs: _getOptionalDVNs(),
            optionalDVNThreshold: 0,
            confirmations: 1, // Base has near-instant finality
            maxMessageSize: 10000
        });

        // Optimism Sepolia
        configs[3] = ChainConfig({
            chainId: 11155420,
            destinationChainIds: _getDestinationChainIds(allChainIds, 11155420),
            sendUln302: 0x0000000000000000000000000000000000000000, // TODO: SendUln302 on OP Sepolia
            receiveUln302: 0x0000000000000000000000000000000000000000, // TODO: ReceiveUln302 on OP Sepolia
            executor: LAYER_ZERO_SETTLER,
            requiredDVNs: _getRequiredDVNs(),
            optionalDVNs: _getOptionalDVNs(),
            optionalDVNThreshold: 0,
            confirmations: 1, // Optimism has near-instant finality
            maxMessageSize: 10000
        });
    }

    /**
     * @notice Get required DVN enum values
     */
    function _getRequiredDVNs() private pure returns (DVN[] memory) {
        DVN[] memory dvns = new DVN[](1);
        dvns[0] = DVN.LAYERZERO_LABS;
        return dvns;
    }

    /**
     * @notice Get optional DVN enum values (empty by default)
     */
    function _getOptionalDVNs() private pure returns (DVN[] memory) {
        // No optional DVNs configured by default
        return new DVN[](0);
    }

    /**
     * @notice Get destination chain IDs for a given origin chain
     * @param allChainIds Array of all chain IDs in the system
     * @param originChainId The chain ID to exclude from destinations
     * @return destinationChainIds Array of all chain IDs except the origin
     */
    function _getDestinationChainIds(uint256[] memory allChainIds, uint256 originChainId)
        private
        pure
        returns (uint256[] memory destinationChainIds)
    {
        // Create array with size = total chains - 1
        destinationChainIds = new uint256[](allChainIds.length - 1);

        uint256 destIndex = 0;
        for (uint256 i = 0; i < allChainIds.length; i++) {
            if (allChainIds[i] != originChainId) {
                destinationChainIds[destIndex] = allChainIds[i];
                destIndex++;
            }
        }

        return destinationChainIds;
    }
}
