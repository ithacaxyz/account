// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title DeploySettlement
 * @notice Deploys settlement contracts with composable options (SimpleSettler or LayerZeroSettler)
 * @dev Third stage of deployment - settler type is determined by configuration
 *
 * Usage:
 * forge script deploy/DeploySettlement.s.sol:DeploySettlement \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "mainnet"
 */
contract DeploySettlement is BaseDeployment {
    using stdJson for string;

    function deploymentType() internal pure override returns (string memory) {
        return "Settlement";
    }

    function run(string memory environment) external {
        initializeDeployment(environment);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying settlement contracts...");

        // Get configuration
        ContractConfig memory contractConfig = getContractConfig();
        ChainConfig memory chainConfig = getChainConfig(chainId);
        DeployedContracts memory existing = getDeployedContracts(chainId);

        // Determine settler type from configuration
        SettlerType settlerType = getSettlerType();
        console.log(
            "Settler type:",
            settlerType == SettlerType.SIMPLE ? "SimpleSettler" : "LayerZeroSettler"
        );

        if (existing.settler == address(0)) {
            // Deploy appropriate settler
            if (settlerType == SettlerType.SIMPLE) {
                address settler = deploySimpleSettler(contractConfig.settlerOwner);
                console.log("SimpleSettler deployed:", settler);
                saveDeployedContract(chainId, "Settler", settler);
            } else {
                address settler =
                    deployLayerZeroSettler(chainConfig.endpoint, contractConfig.l0SettlerOwner);
                console.log("LayerZeroSettler deployed:", settler);
                console.log("  Endpoint:", chainConfig.endpoint);
                console.log("  EID:", chainConfig.eid);
                saveDeployedContract(chainId, "Settler", settler);
            }
        } else {
            console.log("Settler already deployed:", existing.settler);
        }

        // Verify deployments
        verifyDeployments(chainId, settlerType);

        console.log(unicode"\n[✓] Settlement contracts deployment completed");

        if (settlerType == SettlerType.LAYERZERO) {
            console.log("\n[!] Remember to run ConfigureLayerZero to set up cross-chain peers");
        }
    }

    function getSettlerType() internal view returns (SettlerType) {
        ContractConfig memory contractConfig = getContractConfig();
        return parseSettlerType(contractConfig.settlerType);
    }

    function parseSettlerType(string memory settlerTypeStr) internal pure returns (SettlerType) {
        if (keccak256(bytes(settlerTypeStr)) == keccak256(bytes("simple"))) {
            return SettlerType.SIMPLE;
        } else if (keccak256(bytes(settlerTypeStr)) == keccak256(bytes("layerzero"))) {
            return SettlerType.LAYERZERO;
        } else {
            revert(string.concat("Invalid settler type: ", settlerTypeStr));
        }
    }

    function deploySimpleSettler(address settlerOwner) internal returns (address) {
        SimpleSettler settler = new SimpleSettler(settlerOwner);
        return address(settler);
    }

    function deployLayerZeroSettler(address endpoint, address l0SettlerOwner)
        internal
        returns (address)
    {
        require(endpoint != address(0), "LayerZero endpoint not configured for chain");
        LayerZeroSettler lzSettler = new LayerZeroSettler(endpoint, l0SettlerOwner);
        return address(lzSettler);
    }

    function verifyDeployments(uint256 chainId, SettlerType settlerType) internal view {
        console.log("\n[>] Verifying deployments...");

        DeployedContracts memory contracts = getDeployedContracts(chainId);
        ContractConfig memory contractConfig = getContractConfig();
        ChainConfig memory chainConfig = getChainConfig(chainId);

        require(contracts.settler.code.length > 0, "Settler not deployed");

        if (settlerType == SettlerType.SIMPLE) {
            // Verify SimpleSettler
            SimpleSettler settler = SimpleSettler(contracts.settler);
            require(settler.owner() == contractConfig.settlerOwner, "Invalid settler owner");
        } else {
            // Verify LayerZeroSettler
            LayerZeroSettler settler = LayerZeroSettler(payable(contracts.settler));
            require(settler.owner() == contractConfig.l0SettlerOwner, "Invalid L0 settler owner");

            // Verify endpoint
            require(address(settler.endpoint()) == chainConfig.endpoint, "Invalid endpoint");
        }

        console.log(unicode"[✓] All verifications passed");
    }
}
