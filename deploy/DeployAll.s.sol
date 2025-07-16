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
 *   "deploy/config/deployment/mainnet.json" \
 *   '["basic","interop","settlement","lz-config"]'
 *
 * Or to run all stages:
 * forge script deploy/DeployAll.s.sol:DeployAll \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "deploy/config/deployment/mainnet.json"
 */
contract DeployAll is Script {
    enum Stage {
        BASIC,
        INTEROP,
        SETTLEMENT,
        LZ_CONFIG
    }

    string[] ALL_STAGES = ["basic", "interop", "settlement", "lz-config"];

    function run(string memory configPath) external {
        runWithStages(configPath, ALL_STAGES);
    }

    function runWithStages(string memory configPath, string[] memory stages) public {
        console.log("\n========================================");
        console.log("    ITHACA MULTI-STAGE DEPLOYMENT");
        console.log("========================================");
        console.log("Config:", configPath);
        console.log("Stages:", stages.length);
        console.log("");

        // Parse environment from config path
        string memory environment = parseEnvironment(configPath);

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

            bool success = executeStage(stage, configPath);

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

    function executeStage(Stage stage, string memory configPath) internal returns (bool) {
        try this.executeStageExternal(stage, configPath) {
            return true;
        } catch {
            return false;
        }
    }

    function executeStageExternal(Stage stage, string memory configPath) external {
        require(msg.sender == address(this), "Only callable internally");

        if (stage == Stage.BASIC) {
            DeployBasic deploy = new DeployBasic();
            deploy.run(configPath);
        } else if (stage == Stage.INTEROP) {
            DeployInterop deploy = new DeployInterop();
            deploy.run(configPath);
        } else if (stage == Stage.SETTLEMENT) {
            DeploySettlement deploy = new DeploySettlement();
            deploy.run(configPath);
        } else if (stage == Stage.LZ_CONFIG) {
            ConfigureLayerZero deploy = new ConfigureLayerZero();
            deploy.run(configPath);
        }
    }

    function hasBasicDeployments(string memory environment) internal view returns (bool) {
        try vm.readFile("deploy/registry/basic-contracts.json") returns (string memory json) {
            // Check if any chain has basic deployments
            string memory chainsPath = string.concat("deploy/config/chains/", environment, ".json");
            string memory chainsJson = vm.readFile(chainsPath);
            uint256[] memory chains = chainsJson.readUintArray(".chains");

            for (uint256 i = 0; i < chains.length; i++) {
                string memory chainKey = vm.toString(chains[i]);
                try json.readAddress(string.concat(".", chainKey, ".orchestrator")) returns (
                    address
                ) {
                    return true;
                } catch {}
            }
        } catch {}

        return false;
    }

    function hasLayerZeroSettlers(string memory environment) internal view returns (bool) {
        try vm.readFile("deploy/registry/settlement-contracts.json") returns (string memory json) {
            string memory chainsPath = string.concat("deploy/config/chains/", environment, ".json");
            string memory chainsJson = vm.readFile(chainsPath);
            uint256[] memory chains = chainsJson.readUintArray(".chains");

            uint256 lzSettlers = 0;
            for (uint256 i = 0; i < chains.length; i++) {
                string memory chainKey = vm.toString(chains[i]);
                try json.readUint(string.concat(".", chainKey, ".settlerType")) returns (
                    uint256 settlerType
                ) {
                    if (settlerType == 1) {
                        // LayerZero
                        lzSettlers++;
                    }
                } catch {}
            }

            return lzSettlers >= 2;
        } catch {}

        return false;
    }

    function parseEnvironment(string memory configPath) internal pure returns (string memory) {
        // Extract environment from path like "deploy/config/deployment/mainnet.json"
        bytes memory pathBytes = bytes(configPath);
        uint256 lastSlash = 0;
        uint256 dotPos = pathBytes.length;

        // Find last slash
        for (uint256 i = 0; i < pathBytes.length; i++) {
            if (pathBytes[i] == "/") {
                lastSlash = i;
            } else if (pathBytes[i] == ".") {
                dotPos = i;
            }
        }

        // Extract filename between last slash and dot
        bytes memory envBytes = new bytes(dotPos - lastSlash - 1);
        for (uint256 i = 0; i < envBytes.length; i++) {
            envBytes[i] = pathBytes[lastSlash + 1 + i];
        }

        return string(envBytes);
    }
}
