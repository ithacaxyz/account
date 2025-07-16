// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseDeployment} from "./BaseDeployment.sol";
import {console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LayerZeroSettler} from "../src/LayerZeroSettler.sol";

/**
 * @title ConfigureLayerZero
 * @notice Configures LayerZero peer connections between deployed settlers
 * @dev Fourth stage of deployment - only runs if LayerZero settlers were deployed
 *
 * Usage:
 * forge script deploy/ConfigureLayerZero.s.sol:ConfigureLayerZero \
 *   --rpc-url $RPC_URL \
 *   --broadcast \
 *   --sig "run(string)" \
 *   "deploy/config/deployment/mainnet.json"
 */
contract ConfigureLayerZero is BaseDeployment {
    using stdJson for string;

    struct LzSettler {
        uint256 chainId;
        address settler;
        uint32 eid;
        string chainName;
    }

    struct PeerConfiguration {
        uint256 sourceChainId;
        uint256 targetChainId;
        uint32 targetEid;
        address targetSettler;
        bool configured;
        string error;
    }

    // Registry files
    string constant SETTLEMENT_REGISTRY = "deploy/registry/settlement-contracts.json";
    string constant LZ_CONFIG_REGISTRY = "deploy/registry/lz-peer-config.json";

    LzSettler[] lzSettlers;
    PeerConfiguration[] peerConfigs;

    function deploymentType() internal pure override returns (string memory) {
        return "LayerZero Configuration";
    }

    function run(string memory configPath) external {
        initializeDeployment(configPath);

        // Load all LayerZero settlers
        loadLzSettlers();

        if (lzSettlers.length < 2) {
            console.log("\n[!] Less than 2 LayerZero settlers found. Skipping peer configuration.");
            return;
        }

        console.log("\n[>] Found", lzSettlers.length, "LayerZero settlers");

        // Build peer configurations
        buildPeerConfigurations();

        // Execute configuration
        executeConfiguration();
    }

    function loadLzSettlers() internal {
        string memory settlementJson = vm.readFile(SETTLEMENT_REGISTRY);

        for (uint256 i = 0; i < targetChains.length; i++) {
            uint256 chainId = targetChains[i];
            string memory chainKey = vm.toString(chainId);

            // Check if LayerZero settler exists
            string memory typeKey = string.concat(".", chainKey, ".settlerType");
            bytes memory typeData = vm.parseJson(settlementJson, typeKey);

            if (typeData.length > 0) {
                uint256 settlerType = abi.decode(typeData, (uint256));

                if (settlerType == 1) {
                    // LayerZero type
                    LzSettler memory settler;
                    settler.chainId = chainId;
                    settler.chainName = getChainName(chainId);

                    settler.settler =
                        settlementJson.readAddress(string.concat(".", chainKey, ".settler"));

                    settler.eid = uint32(
                        settlementJson.readUint(string.concat(".", chainKey, ".layerZeroEid"))
                    );

                    lzSettlers.push(settler);
                }
            }
        }
    }

    function buildPeerConfigurations() internal {
        // Create bidirectional peer configurations
        for (uint256 i = 0; i < lzSettlers.length; i++) {
            for (uint256 j = 0; j < lzSettlers.length; j++) {
                if (i != j) {
                    PeerConfiguration memory config;
                    config.sourceChainId = lzSettlers[i].chainId;
                    config.targetChainId = lzSettlers[j].chainId;
                    config.targetEid = lzSettlers[j].eid;
                    config.targetSettler = lzSettlers[j].settler;
                    config.configured = false;

                    peerConfigs.push(config);
                }
            }
        }

        console.log("[>] Total peer configurations to set:", peerConfigs.length);
    }

    function executeConfiguration() internal {
        printHeader();

        // Load existing configuration state
        loadConfigurationState();

        uint256 configured = 0;
        uint256 failed = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < peerConfigs.length; i++) {
            if (peerConfigs[i].configured) {
                skipped++;
                continue;
            }

            if (configurePeer(i)) {
                configured++;
                peerConfigs[i].configured = true;
            } else {
                failed++;
            }
        }

        // Save configuration state
        saveConfigurationState();

        console.log("\n========================================");
        console.log("Configuration Summary");
        console.log("========================================");
        console.log("Total peers:", peerConfigs.length);
        console.log("Configured:", configured);
        console.log("Failed:", failed);
        console.log("Skipped:", skipped);

        if (failed > 0) {
            console.log("\n[!] Some peer configurations failed. Run again to retry.");
        }
    }

    function configurePeer(uint256 configIndex) internal returns (bool) {
        PeerConfiguration memory peerConfig = peerConfigs[configIndex];

        // Find source settler info
        LzSettler memory sourceSettler;
        bool found = false;
        for (uint256 i = 0; i < lzSettlers.length; i++) {
            if (lzSettlers[i].chainId == peerConfig.sourceChainId) {
                sourceSettler = lzSettlers[i];
                found = true;
                break;
            }
        }

        if (!found) {
            peerConfigs[configIndex].error = "Source settler not found";
            return false;
        }

        console.log("\n[>] Configuring peer:");
        console.log(
            string.concat(
                "    From: ",
                sourceSettler.chainName,
                " (",
                vm.toString(peerConfig.sourceChainId),
                ")"
            )
        );
        console.log(
            string.concat(
                "    To:   ",
                getChainName(peerConfig.targetChainId),
                " (",
                vm.toString(peerConfig.targetChainId),
                ")"
            )
        );

        // Switch to source chain
        string memory rpcUrl = getRpcUrl(peerConfig.sourceChainId);
        vm.createSelectFork(rpcUrl);

        LayerZeroSettler settler = LayerZeroSettler(payable(sourceSettler.settler));

        // Check if already configured
        try settler.peers(peerConfig.targetEid) returns (bytes32 currentPeer) {
            bytes32 expectedPeer = bytes32(uint256(uint160(peerConfig.targetSettler)));

            if (currentPeer == expectedPeer) {
                console.log(unicode"    [✓] Already configured correctly");
                peerConfigs[configIndex].configured = true;
                return true;
            }
        } catch {}

        // Configure peer
        if (config.dryRun) {
            console.log("    [DRY RUN] Would set peer");
            return true;
        }

        try this.setPeerExternal(
            sourceSettler.settler, peerConfig.targetEid, peerConfig.targetSettler
        ) {
            console.log(unicode"    [✓] Peer configured successfully");
            return true;
        } catch Error(string memory reason) {
            console.log(unicode"    [✗] Failed:", reason);
            peerConfigs[configIndex].error = reason;
            return false;
        } catch {
            console.log(unicode"    [✗] Failed: Unknown error");
            peerConfigs[configIndex].error = "Unknown error";
            return false;
        }
    }

    function setPeerExternal(address settler, uint32 eid, address peer) external {
        require(msg.sender == address(this), "Only callable internally");

        vm.startBroadcast();
        LayerZeroSettler(payable(settler)).setPeer(eid, bytes32(uint256(uint160(peer))));
        vm.stopBroadcast();
    }

    function loadConfigurationState() internal {
        try vm.readFile(LZ_CONFIG_REGISTRY) returns (string memory json) {
            for (uint256 i = 0; i < peerConfigs.length; i++) {
                string memory key = string.concat(
                    ".",
                    vm.toString(peerConfigs[i].sourceChainId),
                    "_",
                    vm.toString(peerConfigs[i].targetChainId)
                );

                // Try to read configured status
                string memory configKey = string.concat(key, ".configured");
                bytes memory configData = vm.parseJson(json, configKey);
                if (configData.length > 0) {
                    peerConfigs[i].configured = abi.decode(configData, (bool));
                }
            }
        } catch {}
    }

    function saveConfigurationState() internal {
        string memory json = "{";

        for (uint256 i = 0; i < peerConfigs.length; i++) {
            if (i > 0) json = string.concat(json, ",");

            string memory key = string.concat(
                vm.toString(peerConfigs[i].sourceChainId),
                "_",
                vm.toString(peerConfigs[i].targetChainId)
            );

            json = string.concat(json, '"', key, '": {');
            json = string.concat(
                json, '"configured": ', peerConfigs[i].configured ? "true" : "false", ","
            );
            json = string.concat(json, '"targetEid": ', vm.toString(peerConfigs[i].targetEid), ",");
            json = string.concat(
                json, '"targetSettler": "', vm.toString(peerConfigs[i].targetSettler), '"'
            );

            if (bytes(peerConfigs[i].error).length > 0) {
                json = string.concat(json, ',"error": "', peerConfigs[i].error, '"');
            }

            json = string.concat(json, "}");
        }

        json = string.concat(json, "}");

        vm.writeFile(LZ_CONFIG_REGISTRY, json);
    }

    // Override base functions that don't apply to configuration
    function deployToChain(uint256) internal override {
        // Not used - configuration handles its own logic
    }
}
