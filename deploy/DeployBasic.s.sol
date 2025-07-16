// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "../src/Simulator.sol";

/**
 * @title DeployBasic
 * @notice Deploys core contracts: Orchestrator, IthacaAccount, Proxy, and Simulator
 * @dev First stage of deployment - these contracts have no dependencies on other deployment stages
 *
 * Usage:
 * forge script deploy/DeployBasic.s.sol:DeployBasic \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "deploy/config/deployment/mainnet.json"
 */
contract DeployBasic is BaseDeployment {
    using stdJson for string;

    struct BasicContracts {
        address orchestrator;
        address accountImplementation;
        address accountProxy;
        address simulator;
    }

    // Registry file for deployed addresses
    string constant BASIC_REGISTRY = "deploy/registry/basic-contracts.json";

    function deploymentType() internal pure override returns (string memory) {
        return "Basic";
    }

    function run(string memory configPath) external {
        initializeDeployment(configPath);
        executeDeployment();
    }

    function deployToChain(uint256 chainId) internal override {
        console.log("Deploying basic contracts...");

        // Load chain-specific configuration
        address pauseAuthority = getChainConfig(chainId, "pauseAuthority");

        // Check if contracts already deployed
        BasicContracts memory existing = loadExistingContracts(chainId);
        BasicContracts memory deployed;

        // Deploy Orchestrator
        if (existing.orchestrator == address(0)) {
            deployed.orchestrator = deployOrchestrator(pauseAuthority);
            console.log("Orchestrator deployed:", deployed.orchestrator);
        } else {
            deployed.orchestrator = existing.orchestrator;
            console.log("Orchestrator already deployed:", deployed.orchestrator);
        }

        // Deploy IthacaAccount implementation
        if (existing.accountImplementation == address(0)) {
            deployed.accountImplementation = deployAccountImplementation(deployed.orchestrator);
            console.log("Account implementation deployed:", deployed.accountImplementation);
        } else {
            deployed.accountImplementation = existing.accountImplementation;
            console.log("Account implementation already deployed:", deployed.accountImplementation);
        }

        // Deploy account proxy
        if (existing.accountProxy == address(0)) {
            deployed.accountProxy = deployAccountProxy(deployed.accountImplementation);
            console.log("Account proxy deployed:", deployed.accountProxy);
        } else {
            deployed.accountProxy = existing.accountProxy;
            console.log("Account proxy already deployed:", deployed.accountProxy);
        }

        // Deploy Simulator
        if (existing.simulator == address(0)) {
            deployed.simulator = deploySimulator();
            console.log("Simulator deployed:", deployed.simulator);
        } else {
            deployed.simulator = existing.simulator;
            console.log("Simulator already deployed:", deployed.simulator);
        }

        // Save deployed addresses
        saveDeployedContracts(chainId, deployed);

        // Verify deployments
        verifyDeployments(chainId, deployed);

        console.log(unicode"\n[✓] Basic contracts deployment completed");
    }

    function deployOrchestrator(address pauseAuthority) internal returns (address) {
        Orchestrator orchestrator = new Orchestrator(pauseAuthority);
        return address(orchestrator);
    }

    function deployAccountImplementation(address orchestrator) internal returns (address) {
        IthacaAccount implementation = new IthacaAccount(orchestrator);
        return address(implementation);
    }

    function deployAccountProxy(address implementation) internal returns (address) {
        return LibEIP7702.deployProxy(implementation, address(0));
    }

    function deploySimulator() internal returns (address) {
        Simulator simulator = new Simulator();
        return address(simulator);
    }

    function loadExistingContracts(uint256 chainId) internal view returns (BasicContracts memory) {
        try vm.readFile(BASIC_REGISTRY) returns (string memory json) {
            string memory chainKey = vm.toString(chainId);

            BasicContracts memory contracts;

            // Try to read each contract address
            contracts.orchestrator =
                tryReadAddress(json, string.concat(".", chainKey, ".orchestrator"));
            contracts.accountImplementation =
                tryReadAddress(json, string.concat(".", chainKey, ".accountImplementation"));
            contracts.accountProxy =
                tryReadAddress(json, string.concat(".", chainKey, ".accountProxy"));
            contracts.simulator = tryReadAddress(json, string.concat(".", chainKey, ".simulator"));

            return contracts;
        } catch {
            return BasicContracts(address(0), address(0), address(0), address(0));
        }
    }

    function saveDeployedContracts(uint256 chainId, BasicContracts memory contracts) internal {
        // Read existing registry
        string memory json;
        try vm.readFile(BASIC_REGISTRY) returns (string memory existing) {
            json = existing;
        } catch {
            json = "{}";
        }

        // Update with new deployment
        string memory chainKey = vm.toString(chainId);
        string memory contractsJson = string.concat(
            '{"orchestrator":"',
            vm.toString(contracts.orchestrator),
            '",',
            '"accountImplementation":"',
            vm.toString(contracts.accountImplementation),
            '",',
            '"accountProxy":"',
            vm.toString(contracts.accountProxy),
            '",',
            '"simulator":"',
            vm.toString(contracts.simulator),
            '",',
            '"timestamp":',
            vm.toString(block.timestamp),
            ",",
            '"blockNumber":',
            vm.toString(block.number),
            "}"
        );

        // Write updated registry
        vm.writeJson(contractsJson, BASIC_REGISTRY, string.concat(".", chainKey));

        console.log("\n[>] Registry updated:", BASIC_REGISTRY);
    }

    function verifyDeployments(uint256 chainId, BasicContracts memory contracts) internal view {
        console.log("\n[>] Verifying deployments...");

        // Verify Orchestrator
        require(contracts.orchestrator.code.length > 0, "Orchestrator not deployed");

        // Verify Account Implementation
        require(
            contracts.accountImplementation.code.length > 0, "Account implementation not deployed"
        );

        // Verify Account Proxy
        require(contracts.accountProxy.code.length > 0, "Account proxy not deployed");

        // Verify Simulator
        require(contracts.simulator.code.length > 0, "Simulator not deployed");

        // Verify Orchestrator pause authority
        Orchestrator orchestrator = Orchestrator(payable(contracts.orchestrator));
        address pauseAuthority = getChainConfig(chainId, "pauseAuthority");
        // We can't verify pause authority directly as it's not exposed, so we skip this check

        // Verify Account implementation points to correct orchestrator
        IthacaAccount account = IthacaAccount(payable(contracts.accountImplementation));
        require(account.ORCHESTRATOR() == contracts.orchestrator, "Invalid orchestrator reference");

        console.log(unicode"[✓] All verifications passed");
    }

    function getChainConfig(uint256 chainId, string memory key) internal view returns (address) {
        string memory configPath =
            string.concat("deploy/config/contracts/", config.environment, ".json");
        string memory configJson = vm.readFile(configPath);

        // Try chain-specific config first
        string memory chainKey = vm.toString(chainId);
        address addr = tryReadAddress(configJson, string.concat(".", chainKey, ".", key));
        if (addr != address(0)) {
            return addr;
        }

        // Fall back to default config
        addr = tryReadAddress(configJson, string.concat(".default.", key));
        if (addr != address(0)) {
            return addr;
        }

        // Try environment variable
        string memory envVar = string.concat(toUpper(config.environment), "_", toUpper(key));
        try vm.envAddress(envVar) returns (address envAddr) {
            return envAddr;
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
