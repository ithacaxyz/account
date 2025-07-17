// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/**
 * @title DeploymentStatus
 * @notice Displays comprehensive deployment status across all chains
 * @dev Reads from registry files and displays in a clean, human-readable format
 *
 * Usage:
 * forge script deploy/DeploymentStatus.s.sol:DeploymentStatus \
 *   --sig "run(string)" \
 *   "mainnet"
 */
contract DeploymentStatus is Script {
    using stdJson for string;

    struct ChainStatus {
        uint256 chainId;
        string chainName;
        bool basicDeployed;
        bool interopDeployed;
        bool settlementDeployed;
        string settlerType;
        bool lzConfigured;
        uint256 totalContracts;
        uint256 deployedContracts;
    }

    struct ContractAddresses {
        // Basic
        address orchestrator;
        address accountImpl;
        address accountProxy;
        address simulator;
        // Interop
        address simpleFunder;
        address escrow;
        // Settlement
        address settler;
        // LZ Config
        uint256 peersConfigured;
        uint256 totalPeers;
    }

    string constant LZ_CONFIG_REGISTRY = "deploy/registry/lz-peer-config.json";

    mapping(uint256 => ChainStatus) chainStatuses;
    mapping(uint256 => ContractAddresses) chainAddresses;
    uint256[] chains;

    function run(string memory environment) external {
        console.log("\n=====================================");
        console.log("   ITHACA DEPLOYMENT STATUS");
        console.log("=====================================");
        console.log("Environment:", environment);
        console.log("Timestamp:", block.timestamp);
        console.log("");

        // Load chains for environment
        uint256[] memory targetChains = loadTargetChains(environment);

        // Collect status for each chain
        for (uint256 i = 0; i < targetChains.length; i++) {
            collectChainStatus(targetChains[i]);
        }

        // Display overview
        displayOverview(targetChains);

        // Display detailed status for each chain
        for (uint256 i = 0; i < targetChains.length; i++) {
            displayChainDetails(targetChains[i]);
        }

        // Display cross-chain configuration
        displayCrossChainConfig(targetChains);

        // Display next steps
        displayNextSteps(targetChains);
    }

    function loadTargetChains(string memory environment) internal view returns (uint256[] memory) {
        string memory chainsPath = string.concat("deploy/config/chains/", environment, ".json");
        string memory fullPath = string.concat(vm.projectRoot(), "/", chainsPath);
        string memory chainsJson = vm.readFile(fullPath);
        return abi.decode(vm.parseJson(chainsJson, ".chains"), (uint256[]));
    }

    function collectChainStatus(uint256 chainId) internal {
        ChainStatus memory status;
        ContractAddresses memory addresses;

        status.chainId = chainId;
        status.chainName = getChainName(chainId);
        status.totalContracts = 7; // Basic(4) + Interop(2) + Settlement(1)

        // Read chain-specific registry file
        string memory registryPath =
            string.concat("deploy/registry/", status.chainName, "-", vm.toString(chainId), ".json");
        string memory registryJson = readRegistry(registryPath);

        if (bytes(registryJson).length > 0) {
            // Read all contract addresses from the unified registry
            addresses.orchestrator = tryReadAddressDirect(registryJson, "Orchestrator");
            addresses.accountImpl = tryReadAddressDirect(registryJson, "AccountImpl");
            addresses.accountProxy = tryReadAddressDirect(registryJson, "AccountProxy");
            addresses.simulator = tryReadAddressDirect(registryJson, "Simulator");
            addresses.simpleFunder = tryReadAddressDirect(registryJson, "SimpleFunder");
            addresses.escrow = tryReadAddressDirect(registryJson, "Escrow");
            addresses.settler = tryReadAddressDirect(registryJson, "Settler");

            // Check deployment status based on which contracts are deployed
            if (addresses.orchestrator != address(0)) {
                status.basicDeployed = true;
                status.deployedContracts = 4;
            }

            if (addresses.simpleFunder != address(0)) {
                status.interopDeployed = true;
                status.deployedContracts += 2;
            }

            if (addresses.settler != address(0)) {
                status.settlementDeployed = true;
                status.deployedContracts += 1;

                // For now, default to Simple settler type
                // In a real deployment, this would be determined from the contract config
                status.settlerType = "Simple";
            }
        }

        // Check LZ configuration
        if (keccak256(bytes(status.settlerType)) == keccak256(bytes("LayerZero"))) {
            string memory lzJson = readRegistry(LZ_CONFIG_REGISTRY);
            if (bytes(lzJson).length > 0) {
                // Count configured peers for this chain
                // This is simplified - in reality would parse the JSON properly
                status.lzConfigured = true;
            }
        }

        chainStatuses[chainId] = status;
        chainAddresses[chainId] = addresses;
    }

    function displayOverview(uint256[] memory targetChains) internal view {
        console.log("DEPLOYMENT OVERVIEW");
        console.log("==================");

        uint256 totalChains = targetChains.length;
        uint256 fullyDeployed = 0;
        uint256 partiallyDeployed = 0;
        uint256 notDeployed = 0;

        for (uint256 i = 0; i < targetChains.length; i++) {
            ChainStatus memory status = chainStatuses[targetChains[i]];

            if (status.deployedContracts == status.totalContracts) {
                fullyDeployed++;
            } else if (status.deployedContracts > 0) {
                partiallyDeployed++;
            } else {
                notDeployed++;
            }
        }

        console.log("");
        console.log("Total chains:", totalChains);
        console.log(unicode"  ✓ Fully deployed:", fullyDeployed);
        console.log(unicode"  ⚠ Partially deployed:", partiallyDeployed);
        console.log(unicode"  ✗ Not deployed:", notDeployed);
        console.log("");
    }

    function displayChainDetails(uint256 chainId) internal view {
        ChainStatus memory status = chainStatuses[chainId];
        ContractAddresses memory addresses = chainAddresses[chainId];

        console.log("=====================================");
        console.log(string.concat(status.chainName, " (", vm.toString(chainId), ")"));
        console.log("=====================================");

        // Progress bar
        string memory progress =
            generateProgressBar(status.deployedContracts, status.totalContracts);
        console.log(
            string.concat(
                "Progress: ",
                progress,
                " ",
                vm.toString(status.deployedContracts),
                "/",
                vm.toString(status.totalContracts)
            )
        );
        console.log("");

        // Basic contracts
        console.log("Basic Contracts:", status.basicDeployed ? unicode"✓" : unicode"✗");
        if (status.basicDeployed) {
            console.log("  Orchestrator:    ", addresses.orchestrator);
            console.log("  Account Impl:    ", addresses.accountImpl);
            console.log("  Account Proxy:   ", addresses.accountProxy);
            console.log("  Simulator:       ", addresses.simulator);
        }
        console.log("");

        // Interop contracts
        console.log("Interop Contracts:", status.interopDeployed ? unicode"✓" : unicode"✗");
        if (status.interopDeployed) {
            console.log("  SimpleFunder:    ", addresses.simpleFunder);
            console.log("  Escrow:          ", addresses.escrow);
        }
        console.log("");

        // Settlement contracts
        console.log("Settlement:", status.settlementDeployed ? unicode"✓" : unicode"✗");
        if (status.settlementDeployed) {
            console.log("  Type:            ", status.settlerType);
            console.log("  Settler:         ", addresses.settler);
            if (keccak256(bytes(status.settlerType)) == keccak256(bytes("LayerZero"))) {
                console.log("  Peers Configured:", status.lzConfigured ? unicode"✓" : unicode"✗");
            }
        }
        console.log("");
    }

    function displayCrossChainConfig(uint256[] memory targetChains) internal view {
        console.log("=====================================");
        console.log("CROSS-CHAIN CONFIGURATION");
        console.log("=====================================");

        uint256 lzChains = 0;
        for (uint256 i = 0; i < targetChains.length; i++) {
            if (
                keccak256(bytes(chainStatuses[targetChains[i]].settlerType))
                    == keccak256(bytes("LayerZero"))
            ) {
                lzChains++;
            }
        }

        if (lzChains < 2) {
            console.log("Not enough LayerZero settlers for cross-chain config");
        } else {
            uint256 expectedPeers = lzChains * (lzChains - 1);
            console.log("LayerZero chains:", lzChains);
            console.log("Expected peer connections:", expectedPeers);
            // In real implementation, would count actual configured peers
            console.log("Status: Run ConfigureLayerZero to set up peers");
        }
        console.log("");
    }

    function displayNextSteps(uint256[] memory targetChains) internal view {
        console.log("=====================================");
        console.log("NEXT STEPS");
        console.log("=====================================");

        bool hasUndeployedBasic = false;
        bool hasUndeployedInterop = false;
        bool hasUndeployedSettlement = false;
        bool hasUnconfiguredLZ = false;

        for (uint256 i = 0; i < targetChains.length; i++) {
            ChainStatus memory status = chainStatuses[targetChains[i]];

            if (!status.basicDeployed) hasUndeployedBasic = true;
            if (!status.interopDeployed && status.basicDeployed) hasUndeployedInterop = true;
            if (!status.settlementDeployed && status.interopDeployed) {
                hasUndeployedSettlement = true;
            }
            if (
                keccak256(bytes(status.settlerType)) == keccak256(bytes("LayerZero"))
                    && !status.lzConfigured
            ) {
                hasUnconfiguredLZ = true;
            }
        }

        uint256 step = 1;

        if (hasUndeployedBasic) {
            console.log(
                string.concat(vm.toString(step), ". Run DeployBasic to deploy core contracts")
            );
            step++;
        }

        if (hasUndeployedInterop) {
            console.log(
                string.concat(
                    vm.toString(step), ". Run DeployInterop to deploy interoperability contracts"
                )
            );
            step++;
        }

        if (hasUndeployedSettlement) {
            console.log(
                string.concat(
                    vm.toString(step), ". Run DeploySettlement to deploy settlement contracts"
                )
            );
            step++;
        }

        if (hasUnconfiguredLZ) {
            console.log(
                string.concat(
                    vm.toString(step), ". Run ConfigureLayerZero to set up cross-chain peers"
                )
            );
            step++;
        }

        if (step == 1) {
            console.log(unicode"✓ All deployments complete!");
        }

        console.log("");
    }

    function generateProgressBar(uint256 completed, uint256 total)
        internal
        pure
        returns (string memory)
    {
        if (total == 0) return "[----------]";

        uint256 filled = (completed * 10) / total;

        bytes memory bar = new bytes(12);
        bar[0] = "[";
        bar[11] = "]";

        for (uint256 i = 1; i <= 10; i++) {
            if (i <= filled) {
                bar[i] = "#";
            } else {
                bar[i] = "-";
            }
        }

        return string(bar);
    }

    function getChainName(uint256 chainId) internal view returns (string memory) {
        string memory fullPath = string.concat(vm.projectRoot(), "/deploy/config/chains.json");
        try vm.readFile(fullPath) returns (string memory chainsJson) {
            return abi.decode(
                vm.parseJson(chainsJson, string.concat(".", vm.toString(chainId), ".name")),
                (string)
            );
        } catch {
            return string.concat("Chain ", vm.toString(chainId));
        }
    }

    function readRegistry(string memory path) internal view returns (string memory) {
        string memory fullPath = string.concat(vm.projectRoot(), "/", path);
        try vm.readFile(fullPath) returns (string memory json) {
            return json;
        } catch {
            return "";
        }
    }

    function tryReadAddress(string memory json, string memory chainKey, string memory field)
        internal
        view
        returns (address)
    {
        string memory key = string.concat(".", chainKey, ".", field);
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (address));
            }
        } catch {}
        return address(0);
    }

    function tryReadAddressDirect(string memory json, string memory field)
        internal
        view
        returns (address)
    {
        string memory key = string.concat(".", field);
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (address));
            }
        } catch {}
        return address(0);
    }

    function tryReadUint(string memory json, string memory chainKey, string memory field)
        internal
        view
        returns (uint256)
    {
        string memory key = string.concat(".", chainKey, ".", field);
        try vm.parseJson(json, key) returns (bytes memory data) {
            if (data.length > 0) {
                return abi.decode(data, (uint256));
            }
        } catch {}
        return 0;
    }
}
