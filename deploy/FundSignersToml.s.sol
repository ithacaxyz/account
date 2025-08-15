// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {MultiSigSigner} from "../src/MultiSigSigner.sol";
import {PauseAuthority} from "../src/PauseAuthority.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";

/**
 * @title FundSignersToml
 * @notice Script to fund signers on multiple chains using TOML configuration
 * @dev Reads configuration from deploy/config.toml
 *
 * Usage:
 * # Fund signers on all chains in config
 * forge script deploy/FundSignersToml.s.sol:FundSignersToml \
 *   --broadcast \
 *   --sig "run()" \
 *   --private-key $PRIVATE_KEY
 *
 * # Fund signers on specific chains
 * forge script deploy/FundSignersToml.s.sol:FundSignersToml \
 *   --broadcast \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[11155111,84532]"
 *
 * # Fund specific number of signers
 * forge script deploy/FundSignersToml.s.sol:FundSignersToml \
 *   --broadcast \
 *   --sig "run(uint256[],uint256)" \
 *   --private-key $PRIVATE_KEY \
 *   "[11155111]" 5
 *
 * # Use custom config file
 * forge script deploy/FundSignersToml.s.sol:FundSignersToml \
 *   --broadcast \
 *   --sig "run(uint256[],uint256,string)" \
 *   --private-key $PRIVATE_KEY \
 *   "[11155111]" 10 "/deploy/custom-config.toml"
 */
contract FundSignersToml is Script {
    using stdToml for string;

    struct ChainFundingConfig {
        uint256 chainId;
        string name;
        bool isTestnet;
        uint256 targetBalance;
        string rpcUrl;
        address simpleFunderAddress;
    }

    string internal configContent;
    string internal configPath = "/deploy/config.toml";

    /**
     * @notice Fund signers on all chains
     */
    function run() external {
        // Default to testing chains
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 11155111; // Sepolia
        chainIds[1] = 84532; // Base Sepolia
        chainIds[2] = 11155420; // Optimism Sepolia
        uint256 numSigners = getDefaultNumSigners();
        fundSigners(chainIds, numSigners);
    }

    /**
     * @notice Fund signers on specific chains with default number
     */
    function run(uint256[] memory chainIds) external {
        uint256 numSigners = getDefaultNumSigners();
        fundSigners(chainIds, numSigners);
    }

    /**
     * @notice Fund specific number of signers on chains
     */
    function run(uint256[] memory chainIds, uint256 numSigners) external {
        fundSigners(chainIds, numSigners);
    }

    /**
     * @notice Fund signers with custom config file
     */
    function run(uint256[] memory chainIds, uint256 numSigners, string memory _configPath)
        external
    {
        configPath = _configPath;
        fundSigners(chainIds, numSigners);
    }

    /**
     * @notice Main funding logic
     */
    function fundSigners(uint256[] memory chainIds, uint256 numSigners) internal {
        // Load config
        loadConfig();

        console.log("\n========================================");
        console.log("Funding Signers from TOML Config");
        console.log("========================================");
        console.log("Number of signers:", numSigners);
        console.log("Target chains:", chainIds.length);

        for (uint256 i = 0; i < chainIds.length; i++) {
            fundSignersOnChain(chainIds[i], numSigners);
        }

        console.log("\n========================================");
        console.log("Funding Complete");
        console.log("========================================");
    }

    /**
     * @notice Fund signers on a specific chain
     */
    function fundSignersOnChain(uint256 chainId, uint256 numSigners) internal {
        // Get chain configuration
        ChainFundingConfig memory config = getChainFundingConfig(chainId);

        console.log("\n-------------------------------------");
        console.log("Funding on:", config.name);
        console.log("Chain ID:", chainId);
        console.log("Is Testnet:", config.isTestnet);
        console.log("Target balance per signer:", config.targetBalance, "wei");

        // Switch to the target chain using RPC_{chainId} environment variable
        string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
        vm.createSelectFork(rpcUrl);

        // Verify chain ID
        require(block.chainid == chainId, "Chain ID mismatch");

        // Fund each signer
        uint256 totalFunded = 0;
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < numSigners; i++) {
            // Generate signer address (deterministic based on index)
            address signer = vm.addr(uint256(keccak256(abi.encodePacked("SIGNER", i + 1))));

            // Check current balance
            uint256 currentBalance = signer.balance;

            if (currentBalance < config.targetBalance) {
                uint256 amountToFund = config.targetBalance - currentBalance;

                console.log("  Funding signer", i + 1, ":", signer);
                console.log("    Current balance:", currentBalance);
                console.log("    Amount to fund:", amountToFund);

                // Fund the signer directly with ETH
                vm.broadcast();
                (bool success,) = signer.call{value: amountToFund}("");
                require(success, "Transfer failed");

                totalFunded++;
                totalAmount += amountToFund;
            } else {
                console.log("  Signer", i + 1, "already funded:", signer);
            }
        }

        console.log("-------------------------------------");
        console.log("Funded", totalFunded, "signers");
        console.log("Total amount:", totalAmount, "wei");
    }

    /**
     * @notice Load configuration from TOML
     */
    function loadConfig() internal {
        string memory fullConfigPath = string.concat(vm.projectRoot(), configPath);
        configContent = vm.readFile(fullConfigPath);
    }

    /**
     * @notice Get chain funding configuration
     */
    function getChainFundingConfig(uint256 chainId) internal returns (ChainFundingConfig memory) {
        // Create fork and read configuration from fork variables
        string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        ChainFundingConfig memory config;
        config.chainId = chainId;
        config.name = vm.readForkString("name");
        config.isTestnet = vm.readForkBool("is_testnet");
        config.targetBalance = vm.readForkUint("target_balance");
        config.rpcUrl = rpcUrl;
        config.simpleFunderAddress = vm.readForkAddress("simple_funder_address");

        return config;
    }

    /**
     * @notice Get default number of signers from config
     */
    function getDefaultNumSigners() internal returns (uint256) {
        // For simplicity, use a hardcoded default since all chains have the same value
        // Alternatively, could read from any fork's variables
        return 10;
    }
}
