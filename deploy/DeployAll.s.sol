// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {DeployBasic} from "./DeployBasic.s.sol";
import {DeployInterop} from "./DeployInterop.s.sol";
import {DeploySettlement} from "./DeploySettlement.s.sol";
import {ConfigureLayerZero} from "./ConfigureLayerZero.s.sol";
import {DeploymentStatus} from "./DeploymentStatus.s.sol";

/**
 * @title DeployAll
 * @notice Master deployment script that orchestrates all deployment stages
 * @dev Runs each deployment stage in sequence with proper error handling
 *
 * Usage:
 * forge script deploy/DeployAll.s.sol:DeployAll \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "runWithStages(string,string[])" \
 *   "mainnet" \
 *   '["basic","interop","settlement","lz-config"]'
 *
 * Or to run all stages:
 * forge script deploy/DeployAll.s.sol:DeployAll \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "mainnet"
 */
contract DeployAll is Script {
    enum Stage {
        BASIC,
        INTEROP,
        SETTLEMENT,
        LZ_CONFIG
    }

    string[] ALL_STAGES = ["basic", "interop", "settlement", "lz-config"];

    function run(string memory environment) external {
        runWithStages(environment, ALL_STAGES);
    }

    function runWithStages(string memory environment, string[] memory stages) public {
        console.log("\n========================================");
        console.log("    ITHACA MULTI-STAGE DEPLOYMENT");
        console.log("========================================");
        console.log("Environment:", environment);
        console.log("Stages:", stages.length);
        console.log("");

        // Show initial status
        console.log("Initial deployment status:");
        DeploymentStatus status = new DeploymentStatus();
        status.run(environment);

        // Execute each stage
        for (uint256 i = 0; i < stages.length; i++) {
            Stage stage = parseStage(stages[i]);

            if (!shouldRunStage(stage, environment)) {
                console.log("\n[>] Skipping stage:", stages[i]);
                continue;
            }

            console.log("\n========================================");
            console.log("Running stage:", stages[i]);
            console.log("========================================");

            bool success = executeStage(stage, environment);

            if (!success) {
                console.log("\n[!] Stage failed:", stages[i]);
                console.log("[!] Fix the issue and run again");

                // Show current status
                console.log("\nCurrent deployment status:");
                status.run(environment);

                revert(string.concat("Deployment failed at stage: ", stages[i]));
            }

            console.log(unicode"\n[✓] Stage completed:", stages[i]);
        }

        // Show final status
        console.log("\n========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("\nFinal deployment status:");
        status.run(environment);
    }

    function parseStage(string memory stageStr) internal pure returns (Stage) {
        if (keccak256(bytes(stageStr)) == keccak256(bytes("basic"))) {
            return Stage.BASIC;
        } else if (keccak256(bytes(stageStr)) == keccak256(bytes("interop"))) {
            return Stage.INTEROP;
        } else if (keccak256(bytes(stageStr)) == keccak256(bytes("settlement"))) {
            return Stage.SETTLEMENT;
        } else if (keccak256(bytes(stageStr)) == keccak256(bytes("lz-config"))) {
            return Stage.LZ_CONFIG;
        } else {
            revert(string.concat("Invalid stage: ", stageStr));
        }
    }

    function shouldRunStage(Stage stage, string memory environment) internal view returns (bool) {
        // Check if prerequisites are met
        if (stage == Stage.INTEROP) {
            // Interop requires Basic to be deployed
            return hasBasicDeployments(environment);
        } else if (stage == Stage.SETTLEMENT) {
            // Settlement requires Basic to be deployed
            return hasBasicDeployments(environment);
        } else if (stage == Stage.LZ_CONFIG) {
            // LZ Config requires LayerZero settlers
            return hasLayerZeroSettlers(environment);
        }

        return true;
    }

    function executeStage(Stage stage, string memory environment) internal returns (bool) {
        // Execute stage directly - errors will revert the transaction
        if (stage == Stage.BASIC) {
            DeployBasic deploy = new DeployBasic();
            deploy.run(environment);
        } else if (stage == Stage.INTEROP) {
            DeployInterop deploy = new DeployInterop();
            deploy.run(environment);
        } else if (stage == Stage.SETTLEMENT) {
            DeploySettlement deploy = new DeploySettlement();
            deploy.run(environment);
        } else if (stage == Stage.LZ_CONFIG) {
            ConfigureLayerZero deploy = new ConfigureLayerZero();
            deploy.run(environment);
        }
        return true;
    }

    function hasBasicDeployments(string memory environment) internal view returns (bool) {
        // Check for any chain registry files with basic deployments
        string memory chainsPath = string.concat("deploy/config/chains/", environment, ".json");
        string memory fullChainsPath = string.concat(vm.projectRoot(), "/", chainsPath);

        try vm.readFile(fullChainsPath) returns (string memory chainsJson) {
            uint256[] memory chains = chainsJson.readUintArray(".chains");

            // Look for any chain with orchestrator deployed
            for (uint256 i = 0; i < chains.length; i++) {
                string memory registryFile = string.concat(
                    "deploy/registry/",
                    getChainName(chains[i]),
                    "-",
                    vm.toString(chains[i]),
                    ".json"
                );
                string memory registryPath = string.concat(vm.projectRoot(), "/", registryFile);

                try vm.readFile(registryPath) returns (string memory registry) {
                    try registry.readAddress(".Orchestrator") returns (address) {
                        return true;
                    } catch {}
                } catch {}
            }
        } catch {}

        return false;
    }

    function hasLayerZeroSettlers(string memory environment) internal view returns (bool) {
        // Check contract config to see if LayerZero settlers are expected
        string memory contractsPath =
            string.concat("deploy/config/contracts/", environment, ".json");
        string memory fullContractsPath = string.concat(vm.projectRoot(), "/", contractsPath);

        try vm.readFile(fullContractsPath) returns (string memory contractsJson) {
            string memory settlerType = contractsJson.readString(".settlerType");

            // Only run LZ config if settler type is layerzero and we have at least 2 chains
            if (keccak256(bytes(settlerType)) == keccak256(bytes("layerzero"))) {
                string memory chainsPath =
                    string.concat("deploy/config/chains/", environment, ".json");
                string memory fullChainsPath = string.concat(vm.projectRoot(), "/", chainsPath);
                string memory chainsJson = vm.readFile(fullChainsPath);
                uint256[] memory chains = chainsJson.readUintArray(".chains");

                return chains.length >= 2;
            }
        } catch {}

        return false;
    }

    function getChainName(uint256 chainId) internal view returns (string memory) {
        string memory chainsPath = "deploy/config/chains.json";
        string memory fullPath = string.concat(vm.projectRoot(), "/", chainsPath);
        string memory chainsJson = vm.readFile(fullPath);

        return chainsJson.readString(string.concat(".", vm.toString(chainId), ".name"));
    }
}
