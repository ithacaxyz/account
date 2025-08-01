// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title LayerZeroRegistry
 * @notice Central registry for LayerZero configuration including DVN addresses and chain mappings
 * @dev Maps chain IDs to EIDs and DVN identifiers to their contract addresses on each chain
 */
contract LayerZeroRegistry {
    // DVN identifier enum
    enum DVN {
        LAYERZERO_LABS,
        NETHERMIND
    }

    /**
     * @notice Get LayerZero Endpoint ID (EID) for a given chain ID
     * @param chainId The chain ID to convert
     * @return eid The LayerZero Endpoint ID
     */
    function getEid(uint256 chainId) public pure returns (uint32 eid) {
        // Mainnets
        if (chainId == 8453) return 30184; // Base
        if (chainId == 10) return 30111; // Optimism

        // Testnets
        if (chainId == 84532) return 40245; // Base Sepolia
        if (chainId == 11155420) return 40232; // Optimism Sepolia

        revert("Chain ID not supported");
    }

    /**
     * @notice Get chain ID for a given LayerZero Endpoint ID (EID)
     * @param eid The LayerZero Endpoint ID
     * @return chainId The chain ID
     */
    function getChainId(uint32 eid) public pure returns (uint256 chainId) {
        // Mainnets
        if (eid == 30184) return 8453; // Base
        if (eid == 30111) return 10; // Optimism

        // Testnets
        if (eid == 40245) return 84532; // Base Sepolia
        if (eid == 40232) return 11155420; // Optimism Sepolia

        revert("EID not supported");
    }

    /**
     * @notice Get DVN address for a specific chain
     * @param dvn The DVN enum identifier
     * @param chainId The chain ID to get the address for
     * @return The DVN contract address on the specified chain
     */
    function getDVNAddress(DVN dvn, uint256 chainId) public pure returns (address) {
        // LayerZero Labs DVN
        if (dvn == DVN.LAYERZERO_LABS) {
            // Mainnets
            if (chainId == 8453) return 0x9e059a54699a285714207b43B055483E78FAac25; // Base
            if (chainId == 10) return 0x6A02D83e8d433304bba74EF1c427913958187142; // Optimism

            // Testnets
            if (chainId == 84532) return 0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6; // Base Sepolia
            if (chainId == 11155420) return 0x07245EFe8f012C046F3b8cA501859c2F080e3cD5; // Optimism Sepolia
        }

        // Nethermind DVN
        if (dvn == DVN.NETHERMIND) {
            // Mainnets
            if (chainId == 8453) return 0x0000000000000000000000000000000000000000; // Base - TODO: Add actual address
            if (chainId == 10) return 0x0000000000000000000000000000000000000000; // Optimism - TODO: Add actual address

            // Testnets
            if (chainId == 84532) return 0x0000000000000000000000000000000000000000; // Base Sepolia - TODO: Add actual address
            if (chainId == 11155420) return 0x0000000000000000000000000000000000000000; // Optimism Sepolia - TODO: Add actual address
        }

        // Return zero address if DVN not found for the chain
        return address(0);
    }

    /**
     * @notice Get multiple DVN addresses for a specific chain
     * @param dvns Array of DVN enum identifiers
     * @param chainId The chain ID to get addresses for
     * @return addresses Array of DVN contract addresses on the specified chain
     */
    function getDVNAddresses(DVN[] memory dvns, uint256 chainId)
        public
        pure
        returns (address[] memory addresses)
    {
        addresses = new address[](dvns.length);
        for (uint256 i = 0; i < dvns.length; i++) {
            addresses[i] = getDVNAddress(dvns[i], chainId);
        }
    }

    /**
     * @notice Get all available DVNs
     * @return Array of all DVN enum values
     */
    function getAvailableDVNs() public pure returns (DVN[] memory) {
        DVN[] memory dvns = new DVN[](2);
        dvns[0] = DVN.LAYERZERO_LABS;
        dvns[1] = DVN.NETHERMIND;
        return dvns;
    }

    /**
     * @notice Check if a DVN is available on a specific chain
     * @param dvn The DVN enum identifier
     * @param chainId The chain ID to check
     * @return True if the DVN has an address on the specified chain
     */
    function isDVNAvailable(DVN dvn, uint256 chainId) public pure returns (bool) {
        return getDVNAddress(dvn, chainId) != address(0);
    }

    /**
     * @notice Get DVN name as string for logging purposes
     * @param dvn The DVN enum identifier
     * @return The human-readable name of the DVN
     */
    function getDVNName(DVN dvn) public pure returns (string memory) {
        if (dvn == DVN.LAYERZERO_LABS) return "LayerZero Labs";
        if (dvn == DVN.NETHERMIND) return "Nethermind";
        return "Unknown";
    }

    /**
     * @notice Check if a chain ID is supported
     * @param chainId The chain ID to check
     * @return True if the chain ID has a corresponding EID
     */
    function isChainSupported(uint256 chainId) public pure returns (bool) {
        return chainId == 8453 // Base
            || chainId == 10 // Optimism
            || chainId == 84532 // Base Sepolia
            || chainId == 11155420; // Optimism Sepolia
    }

    /**
     * @notice Get chain name for logging purposes
     * @param chainId The chain ID
     * @return The human-readable name of the chain
     */
    function getChainName(uint256 chainId) public pure returns (string memory) {
        if (chainId == 8453) return "Base";
        if (chainId == 10) return "Optimism";
        if (chainId == 84532) return "Base Sepolia";
        if (chainId == 11155420) return "Optimism Sepolia";
        return "Unknown";
    }
}
