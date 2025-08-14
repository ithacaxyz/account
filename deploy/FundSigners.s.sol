// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {FunderConfig} from "./FunderConfig.sol";

// SimpleFunder interface for setting gas wallets
interface ISimpleFunder {
    function setGasWallet(address[] memory wallets, bool isGasWallet) external;
    function gasWallets(address) external view returns (bool);
}

/**
 * @title FundSigners
 * @notice Script to fund multiple signers and set them as gas wallets in SimpleFunder
 * @dev Uses a mnemonic to derive signer addresses, tops them up to target balance, and sets them as gas wallets
 *
 * Usage:
 * # Set environment variables
 * export GAS_SIGNER_MNEMONIC="your twelve word mnemonic phrase here"
 * export PRIVATE_KEY=0x... # Account with funds to distribute
 *
 * # Fund all configured chains with default number of signers
 * forge script deploy/FundSigners.s.sol:FundSigners \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run()" \
 *   --private-key $PRIVATE_KEY
 *
 * # Fund specific chains with default number of signers
 * forge script deploy/FundSigners.s.sol:FundSigners \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run(uint256[])" \
 *   --private-key $PRIVATE_KEY \
 *   "[84532]"
 *
 * # Fund specific chains with custom number of signers
 * forge script deploy/FundSigners.s.sol:FundSigners \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run(uint256[],uint256)" \
 *   --private-key $PRIVATE_KEY \
 *   "[84532]" 5
 */
contract FundSigners is Script {
    /**
     * @notice Status of a signer after funding attempt
     */
    struct SignerStatus {
        address signer;
        uint256 initialBalance;
        uint256 amountFunded;
        bool wasFunded;
    }

    /**
     * @notice Summary of funding operations for a chain
     */
    struct ChainSummary {
        uint256 chainId;
        string name;
        uint256 signersChecked;
        uint256 signersFunded;
        uint256 totalEthSent;
    }

    // Track overall statistics
    uint256 private totalSignersFunded;
    uint256 private totalEthDistributed;
    uint256 private chainsProcessed;

    /**
     * @notice Fund all configured chains with default number of signers
     */
    function run() external {
        uint256[] memory chainIds = new uint256[](0); // Empty array means all chains
        FunderConfig configContract = new FunderConfig();
        uint256 numSigners = configContract.getNumSigners();
        execute(chainIds, numSigners);
    }

    /**
     * @notice Fund specific chains with default number of signers
     * @param chainIds Array of chain IDs to fund (empty array = all chains)
     */
    function run(uint256[] memory chainIds) external {
        FunderConfig configContract = new FunderConfig();
        uint256 numSigners = configContract.getNumSigners();
        execute(chainIds, numSigners);
    }

    /**
     * @notice Fund specific chains with custom number of signers
     * @param chainIds Array of chain IDs to fund (empty array = all chains)
     * @param numSigners Number of signers to fund (starting from index 0)
     */
    function run(uint256[] memory chainIds, uint256 numSigners) external {
        execute(chainIds, numSigners);
    }

    /**
     * @notice Main execution logic
     */
    function execute(uint256[] memory chainIds, uint256 numSigners) internal {
        console.log("=== Signer Funding Script ===");
        console.log("Number of signers to fund:", numSigners);

        // Load configuration
        FunderConfig configContract = new FunderConfig();
        FunderConfig.ChainFundingConfig[] memory allConfigs = configContract.getConfigs();
        address simpleFunderAddress = configContract.getSimpleFunderAddress();

        // Get mnemonic from environment
        string memory mnemonic = vm.envString("GAS_SIGNER_MNEMONIC");
        require(bytes(mnemonic).length > 0, "GAS_SIGNER_MNEMONIC not set");

        // Derive signer addresses
        address[] memory signers = deriveSigners(mnemonic, numSigners);
        console.log(
            string.concat(
                "\nDerived ", vm.toString(signers.length), " signer addresses from mnemonic"
            )
        );

        // Log first few signers for verification
        uint256 signersToShow = signers.length < 3 ? signers.length : 3;
        for (uint256 i = 0; i < signersToShow; i++) {
            console.log("  Signer", i, ":", signers[i]);
        }
        if (signers.length > 3) {
            console.log("  ...");
        }

        // Determine which chains to process
        uint256[] memory targetChains = chainIds.length == 0 ? getAllChainIds(allConfigs) : chainIds;

        console.log(string.concat("\nProcessing ", vm.toString(targetChains.length), " chain(s)"));

        // Process each chain
        for (uint256 i = 0; i < targetChains.length; i++) {
            uint256 chainId = targetChains[i];
            FunderConfig.ChainFundingConfig memory config = getConfigForChain(chainId, allConfigs);

            if (config.chainId == 0) {
                console.log(
                    string.concat(
                        "\nWarning: No configuration found for chain ",
                        vm.toString(chainId),
                        " - skipping"
                    )
                );
                continue;
            }

            processChain(chainId, config, signers, simpleFunderAddress);
        }

        // Print overall summary
        printOverallSummary();
    }

    /**
     * @notice Process funding for a single chain
     */
    function processChain(
        uint256 chainId,
        FunderConfig.ChainFundingConfig memory config,
        address[] memory signers,
        address simpleFunderAddress
    ) internal {
        console.log(
            string.concat("\n=== Funding on ", config.name, " (", vm.toString(chainId), ") ===")
        );
        console.log("Configuration:");
        console.log(string.concat("  Target balance: ", vm.toString(config.targetBalance)));

        // Fork to target chain
        string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
        require(bytes(rpcUrl).length > 0, string.concat("RPC_", vm.toString(chainId), " not set"));

        vm.createSelectFork(rpcUrl);

        // Verify we're on the correct chain
        require(block.chainid == chainId, "Chain ID mismatch after fork");

        // Check funder balance
        address funder = msg.sender;
        uint256 funderBalance = funder.balance;

        // Calculate max possible required (worst case: all signers have 0 balance)
        uint256 maxRequired = config.targetBalance * signers.length;

        console.log("\nFunder address:", funder);
        console.log(string.concat("Funder balance: ", vm.toString(funderBalance)));
        console.log(string.concat("Max possible required: ", vm.toString(maxRequired)));

        if (funderBalance < maxRequired) {
            console.log(
                "Warning: Funder may not have enough balance if all signers need full funding"
            );
        }

        // Fund signers
        vm.startBroadcast();
        SignerStatus[] memory statuses = fundSignersOnChain(chainId, config, signers);

        // Set gas wallets in SimpleFunder if configured
        if (simpleFunderAddress != address(0)) {
            setGasWalletsInSimpleFunder(simpleFunderAddress, signers);
        }

        vm.stopBroadcast();

        // Report results for this chain
        ChainSummary memory summary = reportChainResults(config, statuses);

        // Update overall statistics
        totalSignersFunded += summary.signersFunded;
        totalEthDistributed += summary.totalEthSent;
        chainsProcessed++;
    }

    /**
     * @notice Fund signers on a specific chain
     */
    function fundSignersOnChain(
        uint256, // chainId (unused but kept for future extensions)
        FunderConfig.ChainFundingConfig memory config,
        address[] memory signers
    ) internal returns (SignerStatus[] memory) {
        SignerStatus[] memory statuses = new SignerStatus[](signers.length);

        console.log(string.concat("\nProcessing ", vm.toString(signers.length), " signers..."));

        for (uint256 i = 0; i < signers.length; i++) {
            uint256 currentBalance = signers[i].balance;
            statuses[i].signer = signers[i];
            statuses[i].initialBalance = currentBalance;

            if (currentBalance < config.targetBalance) {
                // Calculate the amount needed to reach target balance
                uint256 amountToFund = config.targetBalance - currentBalance;

                // Fund the signer with only the difference
                (bool success,) = signers[i].call{value: amountToFund}("");

                if (success) {
                    statuses[i].wasFunded = true;
                    statuses[i].amountFunded = amountToFund;

                    console.log(
                        string.concat(
                            "  Signer ",
                            vm.toString(i),
                            " (",
                            vm.toString(signers[i]),
                            "): ",
                            vm.toString(currentBalance),
                            " -> Topped up ",
                            vm.toString(amountToFund),
                            " to reach ",
                            vm.toString(config.targetBalance)
                        )
                    );
                } else {
                    console.log(
                        string.concat(
                            "  Signer ",
                            vm.toString(i),
                            " (",
                            vm.toString(signers[i]),
                            "): ",
                            "Funding failed!"
                        )
                    );
                }
            } else {
                console.log(
                    string.concat(
                        "  Signer ",
                        vm.toString(i),
                        " (",
                        vm.toString(signers[i]),
                        "): ",
                        vm.toString(currentBalance),
                        " -> Skipped (already at or above target)"
                    )
                );
            }
        }

        return statuses;
    }

    /**
     * @notice Set gas wallets in SimpleFunder contract
     */
    function setGasWalletsInSimpleFunder(address simpleFunder, address[] memory signers) internal {
        ISimpleFunder funder = ISimpleFunder(simpleFunder);

        console.log("\nChecking and setting gas wallets in SimpleFunder:");
        console.log("  SimpleFunder address:", simpleFunder);

        // First, check which signers need to be set
        address[] memory signersToSet = new address[](signers.length);
        uint256 toSetCount = 0;
        uint256 alreadySet = 0;

        for (uint256 i = 0; i < signers.length; i++) {
            if (funder.gasWallets(signers[i])) {
                alreadySet++;
                console.log(
                    string.concat(
                        "  Signer ",
                        vm.toString(i),
                        " (",
                        vm.toString(signers[i]),
                        "): Already a gas wallet"
                    )
                );
            } else {
                signersToSet[toSetCount] = signers[i];
                toSetCount++;
                console.log(
                    string.concat(
                        "  Signer ",
                        vm.toString(i),
                        " (",
                        vm.toString(signers[i]),
                        "): Needs to be set"
                    )
                );
            }
        }

        // If there are signers to set, do it in one transaction
        if (toSetCount > 0) {
            // Create array with exact size needed
            address[] memory signersToSetFinal = new address[](toSetCount);
            for (uint256 i = 0; i < toSetCount; i++) {
                signersToSetFinal[i] = signersToSet[i];
            }

            // Set all gas wallets in one call
            console.log(
                string.concat(
                    "\n  Setting ", vm.toString(toSetCount), " gas wallets in one transaction..."
                )
            );
            funder.setGasWallet(signersToSetFinal, true);

            // Verify they were all set
            uint256 successfullySet = 0;
            for (uint256 i = 0; i < toSetCount; i++) {
                if (funder.gasWallets(signersToSetFinal[i])) {
                    successfullySet++;
                }
            }

            if (successfullySet == toSetCount) {
                console.log(
                    string.concat(
                        "  Successfully set all ", vm.toString(toSetCount), " gas wallets"
                    )
                );
            } else {
                console.log(
                    string.concat(
                        "  Warning: Only ",
                        vm.toString(successfullySet),
                        " out of ",
                        vm.toString(toSetCount),
                        " gas wallets were set"
                    )
                );
            }
        } else {
            console.log("  All signers are already gas wallets, no action needed");
        }

        console.log(
            string.concat(
                "\n  Gas wallet summary: ",
                vm.toString(alreadySet),
                " already set, ",
                vm.toString(toSetCount),
                " newly set"
            )
        );
    }

    /**
     * @notice Derive signer addresses from mnemonic
     */
    function deriveSigners(string memory mnemonic, uint256 count)
        internal
        pure
        returns (address[] memory)
    {
        address[] memory signers = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            // Derive private key using BIP44 path: m/44'/60'/0'/0/i
            uint256 privateKey = vm.deriveKey(mnemonic, uint32(i));
            signers[i] = vm.addr(privateKey);
        }

        return signers;
    }

    /**
     * @notice Get all chain IDs from configuration
     */
    function getAllChainIds(FunderConfig.ChainFundingConfig[] memory configs)
        internal
        pure
        returns (uint256[] memory)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].chainId != 0) {
                count++;
            }
        }

        uint256[] memory chainIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].chainId != 0) {
                chainIds[index++] = configs[i].chainId;
            }
        }

        return chainIds;
    }

    /**
     * @notice Get configuration for a specific chain
     */
    function getConfigForChain(uint256 chainId, FunderConfig.ChainFundingConfig[] memory configs)
        internal
        pure
        returns (FunderConfig.ChainFundingConfig memory)
    {
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].chainId == chainId) {
                return configs[i];
            }
        }
        // Return empty config if not found
        return FunderConfig.ChainFundingConfig({chainId: 0, name: "", targetBalance: 0});
    }

    /**
     * @notice Report results for a chain
     */
    function reportChainResults(
        FunderConfig.ChainFundingConfig memory config,
        SignerStatus[] memory statuses
    ) internal pure returns (ChainSummary memory) {
        uint256 signersFunded = 0;
        uint256 totalEthSent = 0;

        for (uint256 i = 0; i < statuses.length; i++) {
            if (statuses[i].wasFunded) {
                signersFunded++;
                totalEthSent += statuses[i].amountFunded;
            }
        }

        console.log(string.concat("\nSummary for ", config.name, ":"));
        console.log("  Signers checked:", statuses.length);
        console.log("  Signers funded:", signersFunded);
        console.log(string.concat("  Total sent: ", vm.toString(totalEthSent)));

        return ChainSummary({
            chainId: config.chainId,
            name: config.name,
            signersChecked: statuses.length,
            signersFunded: signersFunded,
            totalEthSent: totalEthSent
        });
    }

    /**
     * @notice Print overall summary of all operations
     */
    function printOverallSummary() internal view {
        console.log("\n=== Overall Summary ===");
        console.log("Chains processed:", chainsProcessed);
        console.log("Total signers funded:", totalSignersFunded);
        console.log(string.concat("Total distributed: ", vm.toString(totalEthDistributed)));
    }
}
