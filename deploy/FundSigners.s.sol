// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

// SimpleFunder interface for setting gas wallets
interface ISimpleFunder {
    function setGasWallet(address[] memory wallets, bool isGasWallet) external;
    function gasWallets(address) external view returns (bool);
}

/**
 * @title FundSigners
 * @notice Script to fund multiple signers and set them as gas wallets in SimpleFunder
 * @dev Uses TOML configuration and a mnemonic to derive signer addresses
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
    using stdToml for string;

    /**
     * @notice Configuration for funding on a specific chain
     */
    struct ChainFundingConfig {
        uint256 chainId;
        string name;
        bool isTestnet;
        uint256 targetBalance;
        address simpleFunderAddress;
        uint256 defaultNumSigners;
    }

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

    string internal configContent;
    string internal configPath = "/deploy/config.toml";

    /**
     * @notice Fund all configured chains with default number of signers
     */
    function run() external {
        // Default to common testnets
        uint256[] memory chainIds = new uint256[](3);
        chainIds[0] = 11155111; // Sepolia
        chainIds[1] = 84532; // Base Sepolia
        chainIds[2] = 11155420; // Optimism Sepolia
        uint256 numSigners = 10; // Default
        execute(chainIds, numSigners);
    }

    /**
     * @notice Fund specific chains with default number of signers
     * @param chainIds Array of chain IDs to fund
     */
    function run(uint256[] memory chainIds) external {
        uint256 numSigners = 10; // Default
        execute(chainIds, numSigners);
    }

    /**
     * @notice Fund specific chains with custom number of signers
     * @param chainIds Array of chain IDs to fund
     * @param numSigners Number of signers to fund (starting from index 0)
     */
    function run(uint256[] memory chainIds, uint256 numSigners) external {
        execute(chainIds, numSigners);
    }

    /**
     * @notice Main execution logic
     */
    function execute(uint256[] memory chainIds, uint256 numSigners) internal {
        console.log("=== Signer Funding Script (TOML Config) ===");
        console.log("Number of signers to fund:", numSigners);

        // Load configuration
        loadConfig();

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

        console.log(string.concat("\nProcessing ", vm.toString(chainIds.length), " chain(s)"));

        // Process each chain
        for (uint256 i = 0; i < chainIds.length; i++) {
            processChain(chainIds[i], signers);
        }

        // Print overall summary
        printOverallSummary();
    }

    /**
     * @notice Process funding for a single chain
     */
    function processChain(uint256 chainId, address[] memory signers) internal {
        // Get chain configuration
        ChainFundingConfig memory config = getChainFundingConfig(chainId);

        console.log(
            string.concat("\n=== Funding on ", config.name, " (", vm.toString(chainId), ") ===")
        );
        console.log("Configuration:");
        console.log(string.concat("  Target balance: ", vm.toString(config.targetBalance)));
        console.log("  SimpleFunder address:", config.simpleFunderAddress);

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
        SignerStatus[] memory statuses = fundSignersOnChain(config, signers);

        // Set gas wallets in SimpleFunder if configured
        if (config.simpleFunderAddress != address(0) && config.simpleFunderAddress.code.length > 0)
        {
            setGasWalletsInSimpleFunder(config.simpleFunderAddress, signers);
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
    function fundSignersOnChain(ChainFundingConfig memory config, address[] memory signers)
        internal
        returns (SignerStatus[] memory)
    {
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
            try funder.gasWallets(signers[i]) returns (bool isGasWallet) {
                if (isGasWallet) {
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
            } catch {
                // If gasWallets call fails, assume signer needs to be set
                signersToSet[toSetCount] = signers[i];
                toSetCount++;
                console.log(
                    string.concat(
                        "  Signer ",
                        vm.toString(i),
                        " (",
                        vm.toString(signers[i]),
                        "): Needs to be set (check failed)"
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

            try funder.setGasWallet(signersToSetFinal, true) {
                // Verify they were all set
                uint256 successfullySet = 0;
                for (uint256 i = 0; i < toSetCount; i++) {
                    try funder.gasWallets(signersToSetFinal[i]) returns (bool isSet) {
                        if (isSet) {
                            successfullySet++;
                        }
                    } catch {}
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
            } catch {
                console.log("  Warning: Failed to set gas wallets (may not have permission)");
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

        // Try to read SimpleFunder address - may not be deployed on all chains
        try vm.readForkAddress("simple_funder_address") returns (address addr) {
            config.simpleFunderAddress = addr;
        } catch {
            // SimpleFunder not configured for this chain
            config.simpleFunderAddress = address(0);
        }

        // Try to read default number of signers
        try vm.readForkUint("default_num_signers") returns (uint256 num) {
            config.defaultNumSigners = num;
        } catch {
            config.defaultNumSigners = 10; // Default fallback
        }

        return config;
    }

    /**
     * @notice Get default number of signers from config
     */
    function getDefaultNumSigners() internal pure returns (uint256) {
        return 10; // Default to 10 signers
    }

    /**
     * @notice Report results for a chain
     */
    function reportChainResults(ChainFundingConfig memory config, SignerStatus[] memory statuses)
        internal
        pure
        returns (ChainSummary memory)
    {
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
