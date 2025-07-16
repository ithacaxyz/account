// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {Escrow} from "../src/Escrow.sol";

/**
 * @title DeployInterop
 * @notice Deploys interoperability contracts: SimpleFunder and Escrow
 * @dev Second stage of deployment - depends on Basic contracts being deployed first
 *
 * Usage:
 * forge script deploy/DeployInterop.s.sol:DeployInterop \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "deploy/config/deployment/mainnet.json"
 */
contract DeployInterop is BaseDeployment {
    using stdJson for string;

    struct InteropContracts {
        address simpleFunder;
        address escrow;
    }

    // Registry files
    string constant BASIC_REGISTRY = "deploy/registry/basic-contracts.json";
    string constant INTEROP_REGISTRY = "deploy/registry/interop-contracts.json";

    function deploymentType() internal pure override returns (string memory) {
        return "Interop";
    }

    function run(string memory configPath) external {
        initializeDeployment(configPath);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying interoperability contracts...");

        // Load basic contracts (required dependencies)
        address orchestrator = loadBasicContract(chainId, "orchestrator");
        require(orchestrator != address(0), "Orchestrator not found - run DeployBasic first");

        // Load chain-specific configuration
        address funderSigner = getChainConfig(chainId, "funderSigner");
        address funderOwner = getChainConfig(chainId, "funderOwner");

        // Check if contracts already deployed
        InteropContracts memory existing = loadExistingContracts(chainId);
        InteropContracts memory deployed;

        // Deploy SimpleFunder
        if (existing.simpleFunder == address(0)) {
            deployed.simpleFunder = deploySimpleFunder(funderSigner, orchestrator, funderOwner);
            console.log("SimpleFunder deployed:", deployed.simpleFunder);
        } else {
            deployed.simpleFunder = existing.simpleFunder;
            console.log("SimpleFunder already deployed:", deployed.simpleFunder);
        }

        // Deploy Escrow
        if (existing.escrow == address(0)) {
            deployed.escrow = deployEscrow();
            console.log("Escrow deployed:", deployed.escrow);
        } else {
            deployed.escrow = existing.escrow;
            console.log("Escrow already deployed:", deployed.escrow);
        }

        // Save deployed addresses
        saveDeployedContracts(chainId, deployed);

        // Verify deployments
        verifyDeployments(chainId, deployed, orchestrator, funderSigner, funderOwner);

        console.log(unicode"\n[✓] Interop contracts deployment completed");
    }

    function deploySimpleFunder(address funderSigner, address orchestrator, address funderOwner)
        internal
        returns (address)
    {
        SimpleFunder funder = new SimpleFunder(funderSigner, orchestrator, funderOwner);
        return address(funder);
    }

    function deployEscrow() internal returns (address) {
        Escrow escrow = new Escrow();
        return address(escrow);
    }

    function loadBasicContract(uint256 chainId, string memory contractName)
        internal
        view
        returns (address)
    {
        try vm.readFile(BASIC_REGISTRY) returns (string memory json) {
            string memory key = string.concat(".", vm.toString(chainId), ".", contractName);

            try json.readAddress(key) returns (address addr) {
                return addr;
            } catch {
                return address(0);
            }
        } catch {
            return address(0);
        }
    }

    function loadExistingContracts(uint256 chainId)
        internal
        view
        returns (InteropContracts memory)
    {
        try vm.readFile(INTEROP_REGISTRY) returns (string memory json) {
            string memory chainKey = vm.toString(chainId);

            InteropContracts memory contracts;

            try json.readAddress(string.concat(".", chainKey, ".simpleFunder")) returns (
                address addr
            ) {
                contracts.simpleFunder = addr;
            } catch {}

            try json.readAddress(string.concat(".", chainKey, ".escrow")) returns (address addr) {
                contracts.escrow = addr;
            } catch {}

            return contracts;
        } catch {
            return InteropContracts(address(0), address(0));
        }
    }

    function saveDeployedContracts(uint256 chainId, InteropContracts memory contracts) internal {
        // Read existing registry
        string memory json;
        try vm.readFile(INTEROP_REGISTRY) returns (string memory existing) {
            json = existing;
        } catch {
            json = "{}";
        }

        // Update with new deployment
        string memory chainKey = vm.toString(chainId);
        string memory contractsJson = string.concat(
            '{"simpleFunder":"',
            vm.toString(contracts.simpleFunder),
            '",',
            '"escrow":"',
            vm.toString(contracts.escrow),
            '",',
            '"timestamp":',
            vm.toString(block.timestamp),
            ",",
            '"blockNumber":',
            vm.toString(block.number),
            "}"
        );

        // Write updated registry
        vm.writeJson(contractsJson, INTEROP_REGISTRY, string.concat(".", chainKey));

        console.log("\n[>] Registry updated:", INTEROP_REGISTRY);
    }

    function verifyDeployments(
        uint256 chainId,
        InteropContracts memory contracts,
        address orchestrator,
        address funderSigner,
        address funderOwner
    ) internal view {
        console.log("\n[>] Verifying deployments...");

        // Verify SimpleFunder
        require(contracts.simpleFunder.code.length > 0, "SimpleFunder not deployed");
        SimpleFunder funder = SimpleFunder(contracts.simpleFunder);
        require(funder.funder() == funderSigner, "Invalid funder signer");
        require(funder.ORCHESTRATOR() == orchestrator, "Invalid orchestrator reference");
        require(funder.owner() == funderOwner, "Invalid funder owner");

        // Verify Escrow
        require(contracts.escrow.code.length > 0, "Escrow not deployed");

        console.log(unicode"[✓] All verifications passed");
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
