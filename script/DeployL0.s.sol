// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title DeployL0Script
 * @notice Deploys the LayerZero Settler for cross-chain settlement
 *
 * Usage:
 * forge script script/DeployL0.s.sol:DeployL0Script --rpc-url $RPC_URL --broadcast --verify
 *
 * Required environment variables:
 * - L0_ENDPOINT: LayerZero endpoint address for the current chain
 * - SETTLER_OWNER: Address that will own the settler contract
 * - PRIVATE_KEY: Private key for deployment (or use --ledger)
 *
 * Example:
 * L0_ENDPOINT=0x1a44076050125825900e736c501f859c50fE728c \
 * SETTLER_OWNER=0x... \
 * forge script script/DeployL0.s.sol:DeployL0Script \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --verify
 *
 * After deployment, set peers using cast:
 * cast send $SETTLER_ADDRESS "setPeer(uint32,bytes32)" $EID $(cast to-bytes32 $PEER_ADDRESS) \
 *   --rpc-url $RPC_URL \
 *   --private-key $PRIVATE_KEY
 */
contract DeployL0Script is Script {
    LayerZeroSettler public settler;

    function run() external {
        // Load configuration from environment
        address endpoint = vm.envAddress("L0_ENDPOINT");
        address owner = vm.envAddress("SETTLER_OWNER");

        require(endpoint != address(0), "L0_ENDPOINT not set");
        require(owner != address(0), "SETTLER_OWNER not set");

        vm.startBroadcast();

        // Deploy the LayerZero Settler
        settler = new LayerZeroSettler(endpoint, owner);

        console.log("LayerZero Settler deployed at:", address(settler));
        console.log("Endpoint:", endpoint);
        console.log("Owner:", owner);

        vm.stopBroadcast();
    }
}
