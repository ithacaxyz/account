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

    // TODO: Set the correct LayerZeroSettler address before running the script.
    address public constant LAYER_ZERO_SETTLER = 0x4225041FF3DB1C7d7a1029406bB80C7298767aca;

    /**
     * @notice Get configuration for all supported chains
     * @return configs Array of configurations for all chains
     */
    function getConfigs() public pure returns (ChainConfig[] memory configs) {
        configs = new ChainConfig[](2);

        // Get all chain IDs
        // TODO: Set all chain IDs that will be wired with each other here.
        uint256[] memory allChainIds = new uint256[](2);

        allChainIds[0] = 84532; // Base Sepolia
        allChainIds[1] = 11155420; // Optimism Sepolia

        // Base Sepolia
        configs[0] = ChainConfig({
            chainId: 84532,
            destinationChainIds: _getDestinationChainIds(allChainIds, 84532),
            sendUln302: 0xC1868e054425D378095A003EcbA3823a5D0135C9, // SendUln302 on Base Sepolia
            receiveUln302: 0x12523de19dc41c91F7d2093E0CFbB76b17012C8d, // ReceiveUln302 on Base Sepolia
            executor: LAYER_ZERO_SETTLER, // Always set Settler as the custom executor
            requiredDVNs: _getRequiredDVNs(),
            optionalDVNs: _getOptionalDVNs(),
            optionalDVNThreshold: 0,
            confirmations: 1, // Base has near-instant finality
            maxMessageSize: 10000
        });

        // Optimism Sepolia
        configs[1] = ChainConfig({
            chainId: 11155420,
            destinationChainIds: _getDestinationChainIds(allChainIds, 11155420),
            sendUln302: 0xB31D2cb502E25B30C651842C7C3293c51Fe6d16f, // SendUln302 on OP Sepolia
            receiveUln302: 0x9284fd59B95b9143AF0b9795CAC16eb3C723C9Ca, // ReceiveUln302 on OP Sepolia
            executor: LAYER_ZERO_SETTLER, // Always set Settler as the custom executor
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
