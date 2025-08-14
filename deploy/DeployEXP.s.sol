// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Script} from "forge-std/Script.sol";
import {ExperimentERC20} from "../deploy/mock/ExperimentalERC20.sol";

/**
 * @title DeployEXP
 * @notice Script to deploy ExperimentERC20 token across multiple chains and mint initial supply
 * @dev Deploys EXP token to specified chains with initial minting to a designated address
 *
 * Usage:
 * # Set environment variables
 * export PRIVATE_KEY=0x...
 * export RPC_84532="https://sepolia.base.org"  # Base Sepolia
 *
 * # Deploy to single chain (Base Sepolia) with 1000 tokens
 * forge script deploy/DeployEXP.s.sol:DeployEXP \
 *   --sig "run(uint256[],address,uint256)" \
 *   "[84532]" \
 *   "0xYourRecipientAddress" \
 *   "1000000000000000000000" \
 *   --broadcast \
 *   --private-key $PRIVATE_KEY
 *
 * # Deploy to multiple chains
 * forge script deploy/DeployEXP.s.sol:DeployEXP \
 *   --sig "run(uint256[],address,uint256)" \
 *   "[84532,11155111,421614]" \
 *   "0xYourRecipientAddress" \
 *   "1000000000000000000000" \
 *   --broadcast \
 *   --private-key $PRIVATE_KEY
 */
contract DeployEXP is Script {
    mapping(uint256 => address) public deployedTokens;

    error InvalidChainIds();
    error InvalidMintAddress();
    error InvalidMintAmount();

    function run(uint256[] calldata chainIds, address mintTo, uint256 mintAmount) external {
        // Validate inputs
        if (chainIds.length == 0) revert InvalidChainIds();
        if (mintTo == address(0)) revert InvalidMintAddress();
        if (mintAmount == 0) revert InvalidMintAmount();

        // Deploy to each chain
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Switch to the appropriate fork/chain
            string memory rpcEnvVar = string.concat("RPC_", vm.toString(chainId));
            string memory rpcUrl = vm.envString(rpcEnvVar);
            vm.createSelectFork(rpcUrl);

            vm.startBroadcast();

            // Deploy the ExperimentERC20 token
            ExperimentERC20 token = new ExperimentERC20("Experimental Token", "EXP", 1 ether);

            // Mint tokens to the specified address
            token.mint(mintTo, mintAmount);

            // Store the deployed address
            deployedTokens[chainId] = address(token);

            vm.stopBroadcast();

            // Log deployment
            emit TokenDeployed(chainId, address(token), mintTo, mintAmount);
        }
    }

    // Event for tracking deployments
    event TokenDeployed(
        uint256 indexed chainId,
        address indexed tokenAddress,
        address indexed mintTo,
        uint256 amount
    );
}
