// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title FundSimpleFunder
 * @notice Script to fund SimpleFunder contracts with native and ERC20 tokens across multiple chains
 * @dev Uses the same RPC format as other deployment scripts (RPC_<chainId>)
 *
 * Usage:
 * # Set environment variables
 * export PRIVATE_KEY=0x... # Account with funds to send
 * export RPC_84532=https://... # Base Sepolia RPC
 * export RPC_11155111=https://... # Sepolia RPC
 *
 * # Fund SimpleFunder on multiple chains
 * forge script deploy/FundSimpleFunder.s.sol:FundSimpleFunder \
 *   --broadcast \
 *   --multi \
 *   --slow \
 *   --sig "run(address,(uint256,address,uint256)[])" \
 *   --private-key $PRIVATE_KEY \
 *   0xFunderAddress "[(84532,0x0000000000000000000000000000000000000000,1000000000000000000),(11155111,0xTokenAddress,1000000)]"
 */
contract FundSimpleFunder is Script {
    /**
     * @notice Funding configuration for a specific token on a chain
     */
    struct FundingConfig {
        uint256 chainId;
        address tokenAddress; // 0x0 for native token
        uint256 amount;
    }

    /**
     * @notice Result of a funding operation
     */
    struct FundingResult {
        uint256 chainId;
        address tokenAddress;
        uint256 amount;
        bool success;
        string tokenType;
    }

    // Track results
    FundingResult[] private results;
    uint256 private totalChains;

    // Fork management - store fork IDs to avoid recreating forks
    mapping(uint256 => uint256) private forkIds;
    mapping(uint256 => bool) private hasFork;
    uint256 private successfulTransfers;

    /**
     * @notice Fund SimpleFunder with tokens across multiple chains
     * @param funderAddress The SimpleFunder contract address (should be same across chains if CREATE2)
     * @param configs Array of funding configurations
     */
    function run(address funderAddress, FundingConfig[] memory configs) external {
        console.log("=== SimpleFunder Funding Script ===");
        console.log("SimpleFunder address:", funderAddress);
        console.log("Configurations to process:", configs.length);
        console.log("");

        // First, create all necessary forks upfront
        populateForks(configs);

        // Process each configuration
        for (uint256 i = 0; i < configs.length; i++) {
            processChainFunding(funderAddress, configs[i]);
        }

        // Print summary
        printSummary();
    }

    /**
     * @notice Create all necessary forks upfront to avoid recreating them
     * @param configs Array of funding configurations
     */
    function populateForks(FundingConfig[] memory configs) internal {
        console.log("Creating forks for unique chains...");

        for (uint256 i = 0; i < configs.length; i++) {
            uint256 chainId = configs[i].chainId;

            // Only create fork if we haven't already
            if (!hasFork[chainId]) {
                string memory rpcUrl = vm.envString(string.concat("RPC_", vm.toString(chainId)));
                require(
                    bytes(rpcUrl).length > 0,
                    string.concat("RPC_", vm.toString(chainId), " not set")
                );

                uint256 forkId = vm.createFork(rpcUrl);
                forkIds[chainId] = forkId;
                hasFork[chainId] = true;

                console.log("  Created fork for chain", chainId, "with fork ID", forkId);
            }
        }
        console.log("");
    }

    /**
     * @notice Process funding for a single chain and token
     */
    function processChainFunding(address funderAddress, FundingConfig memory config) internal {
        console.log("=====================================");
        console.log("Processing Chain ID:", config.chainId);
        console.log("=====================================");

        // Select the already-created fork for this chain
        require(hasFork[config.chainId], "Fork not created for chain");
        vm.selectFork(forkIds[config.chainId]);

        // Verify we're on the correct chain
        require(block.chainid == config.chainId, "Chain ID mismatch after fork");

        // Track unique chains
        bool isNewChain = true;
        for (uint256 i = 0; i < results.length; i++) {
            if (results[i].chainId == config.chainId) {
                isNewChain = false;
                break;
            }
        }
        if (isNewChain) {
            totalChains++;
        }

        // Determine token type
        bool isNative = config.tokenAddress == address(0);
        string memory tokenType = isNative ? "Native" : "ERC20";

        console.log("Token type:", tokenType);
        if (!isNative) {
            console.log("Token address:", config.tokenAddress);
        }
        console.log("Amount to send:", config.amount);

        // Check sender balance
        address sender = msg.sender;
        uint256 senderBalance;

        if (isNative) {
            senderBalance = sender.balance;
            console.log("Sender native balance:", senderBalance);
        } else {
            IERC20 token = IERC20(config.tokenAddress);
            senderBalance = token.balanceOf(sender);
            console.log("Sender token balance:", senderBalance);

            // Try to get token details
            try token.symbol() returns (string memory symbol) {
                console.log("Token symbol:", symbol);
            } catch {
                console.log("Token symbol: Unable to retrieve");
            }
        }

        // Verify sufficient balance
        if (senderBalance < config.amount) {
            console.log("ERROR: Insufficient balance!");
            console.log("  Required:", config.amount);
            console.log("  Available:", senderBalance);

            results.push(
                FundingResult({
                    chainId: config.chainId,
                    tokenAddress: config.tokenAddress,
                    amount: config.amount,
                    success: false,
                    tokenType: tokenType
                })
            );

            return;
        }

        // Check current funder balance
        uint256 funderBalanceBefore;
        if (isNative) {
            funderBalanceBefore = funderAddress.balance;
            console.log("Funder native balance before:", funderBalanceBefore);
        } else {
            IERC20 token = IERC20(config.tokenAddress);
            funderBalanceBefore = token.balanceOf(funderAddress);
            console.log("Funder token balance before:", funderBalanceBefore);
        }

        // Execute the transfer
        console.log("\nExecuting transfer...");

        vm.startBroadcast();

        bool success;
        if (isNative) {
            // Send native tokens
            (success,) = funderAddress.call{value: config.amount}("");
        } else {
            // Send ERC20 tokens
            IERC20 token = IERC20(config.tokenAddress);

            // Check current allowance
            uint256 currentAllowance = token.allowance(sender, funderAddress);

            // Approve if needed (some tokens don't allow changing non-zero allowance)
            if (currentAllowance < config.amount) {
                // Reset allowance to 0 first if it's non-zero (for tokens like USDT)
                if (currentAllowance > 0) {
                    token.approve(funderAddress, 0);
                }
                token.approve(funderAddress, config.amount);
            }

            // Transfer tokens
            success = token.transfer(funderAddress, config.amount);
        }

        vm.stopBroadcast();

        // Verify the transfer
        uint256 funderBalanceAfter;
        if (isNative) {
            funderBalanceAfter = funderAddress.balance;
        } else {
            IERC20 token = IERC20(config.tokenAddress);
            funderBalanceAfter = token.balanceOf(funderAddress);
        }

        uint256 actualTransferred = funderBalanceAfter - funderBalanceBefore;

        if (success && actualTransferred == config.amount) {
            console.log("Transfer successful!");
            console.log("  Funder balance after:", funderBalanceAfter);
            console.log("  Amount transferred:", actualTransferred);
            successfulTransfers++;
        } else {
            console.log("Transfer failed or amount mismatch!");
            console.log("  Expected transfer:", config.amount);
            console.log("  Actual transferred:", actualTransferred);
        }

        // Store result
        results.push(
            FundingResult({
                chainId: config.chainId,
                tokenAddress: config.tokenAddress,
                amount: config.amount,
                success: success && actualTransferred == config.amount,
                tokenType: tokenType
            })
        );

        console.log("");
    }

    /**
     * @notice Print summary of all funding operations
     */
    function printSummary() internal view {
        console.log("=====================================");
        console.log("Funding Summary");
        console.log("=====================================");
        console.log("Total chains processed:", totalChains);
        console.log("Total transfers:", results.length);
        console.log("Successful transfers:", successfulTransfers);
        console.log("");

        if (results.length > 0) {
            console.log("Details:");
            for (uint256 i = 0; i < results.length; i++) {
                FundingResult memory result = results[i];

                string memory status = result.success ? "[SUCCESS]" : "[FAILED]";
                string memory tokenInfo = result.tokenAddress == address(0)
                    ? "Native"
                    : string.concat("Token: ", vm.toString(result.tokenAddress));

                console.log(
                    string.concat(
                        "[",
                        status,
                        "] Chain ",
                        vm.toString(result.chainId),
                        " - ",
                        tokenInfo,
                        " - Amount: ",
                        vm.toString(result.amount)
                    )
                );
            }
        }

        if (successfulTransfers < results.length) {
            console.log("");
            console.log("Warning: Some transfers failed. Please review the logs above.");
        } else if (successfulTransfers == results.length && results.length > 0) {
            console.log("");
            console.log("All transfers completed successfully!");
        }
    }
}
