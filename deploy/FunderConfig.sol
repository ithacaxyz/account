// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title FunderConfig
 * @notice Configuration contract containing funding settings for all chains
 * @dev Defines per-chain target balance for signers
 */
contract FunderConfig {
    /**
     * @notice Configuration for funding on a specific chain
     */
    struct ChainFundingConfig {
        uint256 chainId;
        string name;
        uint256 targetBalance; // Target balance for each signer (in wei)
    }

    // NOTE: Important to change this address with the actual SimpleFunder address
    address public constant SIMPLE_FUNDER_ADDRESS = 0x2AD8F6a3bB1126a777606eaFa9da9b95530d9597;

    /**
     * @notice Get configuration for all supported chains
     * @return configs Array of funding configurations for each chain
     */
    function getConfigs() public pure returns (ChainFundingConfig[] memory configs) {
        configs = new ChainFundingConfig[](10);

        // Ethereum Mainnet - Higher target balance
        configs[0] =
            ChainFundingConfig({chainId: 1, name: "Ethereum Mainnet", targetBalance: 0.1 ether});

        // Arbitrum One - L2, lower target
        configs[1] =
            ChainFundingConfig({chainId: 42161, name: "Arbitrum One", targetBalance: 0.005 ether});

        // Base - L2, lower target
        configs[2] = ChainFundingConfig({chainId: 8453, name: "Base", targetBalance: 0.005 ether});

        // Sepolia - Testnet
        configs[3] =
            ChainFundingConfig({chainId: 11155111, name: "Sepolia", targetBalance: 0.05 ether});

        // Optimism Sepolia - Testnet
        configs[4] = ChainFundingConfig({
            chainId: 11155420,
            name: "Optimism Sepolia",
            targetBalance: 0.01 ether
        });

        // Base Sepolia - Testnet (using very low values for testing)
        configs[5] = ChainFundingConfig({
            chainId: 84532,
            name: "Base Sepolia",
            targetBalance: 0.001 ether // 1 finney for testing
        });

        // Porto Devnet
        configs[6] =
            ChainFundingConfig({chainId: 28404, name: "Porto Devnet", targetBalance: 1 ether});

        // Porto Devnet Paros
        configs[7] =
            ChainFundingConfig({chainId: 28405, name: "Porto Devnet Paros", targetBalance: 1 ether});

        // Porto Devnet Tinos
        configs[8] =
            ChainFundingConfig({chainId: 28406, name: "Porto Devnet Tinos", targetBalance: 1 ether});

        // Porto Devnet Leros
        configs[9] =
            ChainFundingConfig({chainId: 28407, name: "Porto Devnet Leros", targetBalance: 1 ether});
    }

    /**
     * @notice Get the SimpleFunder contract address (same across all chains)
     * @return The SimpleFunder contract address
     */
    function getSimpleFunderAddress() public pure returns (address) {
        return SIMPLE_FUNDER_ADDRESS;
    }

    /**
     * @notice Get the default number of signers to fund
     * @return The default number of signers (can be overridden via script parameters)
     */
    function getNumSigners() public pure returns (uint256) {
        return 10; // Default to funding 10 signers
    }
}
