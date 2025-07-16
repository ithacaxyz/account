// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
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
 *   "deploy/config/deployment/mainnet.json"
 */
contract DeploySettlement is BaseDeployment {
    enum SettlerType {
        SIMPLE,
        LAYERZERO
    }

    struct SettlementContracts {
        SettlerType settlerType;
        address settler;
        address layerZeroEndpoint; // Only for L0 settler
        uint32 layerZeroEid; // Only for L0 settler
    }

    // Registry file
    string constant SETTLEMENT_REGISTRY = "deploy/registry/settlement-contracts.json";

    function deploymentType() internal pure override returns (string memory) {
        return "Settlement";
    }

    function run(string memory configPath) external {
        initializeDeployment(configPath);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying settlement contracts...");

        // Determine settler type from configuration
        SettlerType settlerType = getSettlerType(chainId);
        console.log(
            "Settler type:",
            settlerType == SettlerType.SIMPLE ? "SimpleSettler" : "LayerZeroSettler"
        );

        // Check if already deployed
        SettlementContracts memory existing = loadExistingContracts(chainId);
        SettlementContracts memory deployed;

        deployed.settlerType = settlerType;

        if (existing.settler != address(0)) {
            // Verify existing settler matches expected type
            require(existing.settlerType == settlerType, "Existing settler type mismatch");
            deployed = existing;
            console.log("Settler already deployed:", deployed.settler);
        } else {
            // Deploy appropriate settler
            if (settlerType == SettlerType.SIMPLE) {
                deployed.settler = deploySimpleSettler(chainId);
                console.log("SimpleSettler deployed:", deployed.settler);
            } else {
                (deployed.settler, deployed.layerZeroEndpoint, deployed.layerZeroEid) =
                    deployLayerZeroSettler(chainId);
                console.log("LayerZeroSettler deployed:", deployed.settler);
                console.log("  Endpoint:", deployed.layerZeroEndpoint);
                console.log("  EID:", deployed.layerZeroEid);
            }
        }

        // Save deployed addresses
        saveDeployedContracts(chainId, deployed);

        // Verify deployments
        verifyDeployments(chainId, deployed);

        console.log("\n[✓] Settlement contracts deployment completed");

        if (settlerType == SettlerType.LAYERZERO) {
            console.log("\n[!] Remember to run ConfigureLayerZero to set up cross-chain peers");
        }
    }

    function getSettlerType(uint256 chainId) internal view returns (SettlerType) {
        string memory configPath =
            string.concat("deploy/config/contracts/", config.environment, ".json");
        string memory configJson = vm.readFile(configPath);

        // Check chain-specific settler type
        string memory chainKey = vm.toString(chainId);
        try configJson.readString(string.concat(".", chainKey, ".settlerType")) returns (
            string memory settlerTypeStr
        ) {
            return parseSettlerType(settlerTypeStr);
        } catch {}

        // Fall back to default settler type
        try configJson.readString(".default.settlerType") returns (string memory settlerTypeStr) {
            return parseSettlerType(settlerTypeStr);
        } catch {}

        // Default based on environment
        if (keccak256(bytes(config.environment)) == keccak256(bytes("devnet"))) {
            return SettlerType.SIMPLE;
        } else {
            return SettlerType.LAYERZERO;
        }
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

    function deploySimpleSettler(uint256 chainId) internal returns (address) {
        address settlerOwner = getChainConfig(chainId, "settlerOwner");
        SimpleSettler settler = new SimpleSettler(settlerOwner);
        return address(settler);
    }

    function deployLayerZeroSettler(uint256 chainId)
        internal
        returns (address settler, address endpoint, uint32 eid)
    {
        address settlerOwner = getChainConfig(chainId, "l0SettlerOwner");

        // Get LayerZero endpoint and EID from chain config
        string memory chainsPath = "deploy/config/chains.json";
        string memory chainsJson = vm.readFile(chainsPath);
        string memory chainKey = vm.toString(chainId);

        endpoint = chainsJson.readAddress(string.concat(".", chainKey, ".layerZeroEndpoint"));
        require(endpoint != address(0), "LayerZero endpoint not configured for chain");

        eid = uint32(chainsJson.readUint(string.concat(".", chainKey, ".layerZeroEid")));
        require(eid != 0, "LayerZero EID not configured for chain");

        LayerZeroSettler lzSettler = new LayerZeroSettler(endpoint, settlerOwner);
        settler = address(lzSettler);
    }

    function loadExistingContracts(uint256 chainId)
        internal
        view
        returns (SettlementContracts memory)
    {
        try vm.readFile(SETTLEMENT_REGISTRY) returns (string memory json) {
            string memory chainKey = vm.toString(chainId);

            SettlementContracts memory contracts;

            try json.readUint(string.concat(".", chainKey, ".settlerType")) returns (
                uint256 typeInt
            ) {
                contracts.settlerType = SettlerType(typeInt);
            } catch {
                return contracts; // Return empty if no settler type found
            }

            try json.readAddress(string.concat(".", chainKey, ".settler")) returns (address addr) {
                contracts.settler = addr;
            } catch {}

            if (contracts.settlerType == SettlerType.LAYERZERO) {
                try json.readAddress(string.concat(".", chainKey, ".layerZeroEndpoint")) returns (
                    address addr
                ) {
                    contracts.layerZeroEndpoint = addr;
                } catch {}

                try json.readUint(string.concat(".", chainKey, ".layerZeroEid")) returns (
                    uint256 eid
                ) {
                    contracts.layerZeroEid = uint32(eid);
                } catch {}
            }

            return contracts;
        } catch {
            return SettlementContracts(SettlerType.SIMPLE, address(0), address(0), 0);
        }
    }

    function saveDeployedContracts(uint256 chainId, SettlementContracts memory contracts)
        internal
    {
        // Read existing registry
        string memory json;
        try vm.readFile(SETTLEMENT_REGISTRY) returns (string memory existing) {
            json = existing;
        } catch {
            json = "{}";
        }

        // Build contract JSON
        string memory contractsJson = string.concat(
            '{"settlerType":',
            vm.toString(uint256(contracts.settlerType)),
            ",",
            '"settler":"',
            vm.toString(contracts.settler),
            '"'
        );

        if (contracts.settlerType == SettlerType.LAYERZERO) {
            contractsJson = string.concat(
                contractsJson,
                ',"layerZeroEndpoint":"',
                vm.toString(contracts.layerZeroEndpoint),
                '",',
                '"layerZeroEid":',
                vm.toString(contracts.layerZeroEid)
            );
        }

        contractsJson = string.concat(
            contractsJson,
            ',"timestamp":',
            vm.toString(block.timestamp),
            ",",
            '"blockNumber":',
            vm.toString(block.number),
            "}"
        );

        // Write updated registry
        string memory chainKey = vm.toString(chainId);
        vm.writeJson(contractsJson, SETTLEMENT_REGISTRY, string.concat(".", chainKey));

        console.log("\n[>] Registry updated:", SETTLEMENT_REGISTRY);
    }

    function verifyDeployments(uint256 chainId, SettlementContracts memory contracts)
        internal
        view
    {
        console.log("\n[>] Verifying deployments...");

        require(contracts.settler.code.length > 0, "Settler not deployed");

        if (contracts.settlerType == SettlerType.SIMPLE) {
            // Verify SimpleSettler
            SimpleSettler settler = SimpleSettler(contracts.settler);
            address expectedOwner = getChainConfig(chainId, "settlerOwner");
            require(settler.owner() == expectedOwner, "Invalid settler owner");
        } else {
            // Verify LayerZeroSettler
            LayerZeroSettler settler = LayerZeroSettler(payable(contracts.settler));
            address expectedOwner = getChainConfig(chainId, "l0SettlerOwner");
            require(settler.owner() == expectedOwner, "Invalid L0 settler owner");

            // Verify endpoint
            require(address(settler.endpoint()) == contracts.layerZeroEndpoint, "Invalid endpoint");
        }

        console.log("[✓] All verifications passed");
    }

    function getChainConfig(uint256 chainId, string memory key) internal view returns (address) {
        string memory configPath =
            string.concat("deploy/config/contracts/", config.environment, ".json");
        string memory configJson = vm.readFile(configPath);

        // Try chain-specific config first
        string memory chainKey = vm.toString(chainId);
        try configJson.readAddress(string.concat(".", chainKey, ".", key)) returns (address addr) {
            return addr;
        } catch {}

        // Fall back to default config
        try configJson.readAddress(string.concat(".default.", key)) returns (address addr) {
            return addr;
        } catch {}

        // Try environment variable
        string memory envVar = string.concat(toUpper(config.environment), "_", toUpper(key));
        try vm.envAddress(envVar) returns (address addr) {
            return addr;
        } catch {}

        revert(string.concat("Config not found: ", key));
    }

    function toUpper(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(strBytes.length);

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] >= 0x61 && strBytes[i] <= 0x7A) {
                result[i] = bytes1(uint8(strBytes[i]) - 32);
            } else {
                result[i] = strBytes[i];
            }
        }

        return string(result);
    }
}
