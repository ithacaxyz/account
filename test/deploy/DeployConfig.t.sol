// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {DeployMain} from "../../deploy/DeployMain.s.sol";

contract DeployConfigTest is Test {
    DeployMain deployment;
    string constant TEST_TEMP_DIR = "test/deploy/temp/";
    string constant TEST_CONFIG_FILE = "test/deploy/temp/test-config.json";
    string constant TEST_REGISTRY_DIR = "test/deploy/temp/test-registry/";

    modifier withCleanup() {
        // Ensure temp directory exists
        if (!vm.exists(TEST_TEMP_DIR)) {
            vm.createDir(TEST_TEMP_DIR, false);
        }

        _;

        // Clean up test files after each test
        try vm.removeFile(TEST_CONFIG_FILE) {} catch {}

        // Also clean up any registry directory if it was created
        try vm.removeDir(TEST_REGISTRY_DIR, true) {} catch {}
    }

    function setUp() public {
        deployment = new DeployMain();
        // Set required env vars
        vm.setEnv("RPC_28404", "https://porto-dev.rpc.ithaca.xyz/");
        vm.setEnv(
            "PRIVATE_KEY", "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
        );
    }

    function test_RevertOnMissingConfigFile() public withCleanup {
        uint256[] memory chainIds = new uint256[](0);

        vm.expectRevert();
        deployment.run(chainIds, "non/existent/config.json", TEST_REGISTRY_DIR);
    }

    // TODO: Fix deployment script to fail on empty config
    // See https://github.com/ithacaxyz/account/issues/253
    // function test_RevertOnEmptyConfig() public {
    //     vm.writeFile(TEST_CONFIG_FILE, "{}");
    //
    //     uint256[] memory chainIds = new uint256[](0);
    //     vm.expectRevert();
    //     deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    // }

    // TODO: Fix deployment script to fail on missing chain config
    // See https://github.com/ithacaxyz/account/issues/253
    // function test_RevertOnMissingChainConfig() public {
    //     // Config exists but doesn't have the requested chain
    //     vm.writeFile(TEST_CONFIG_FILE, '{"999": {"name": "Wrong Chain"}}');
    //
    //     uint256[] memory chainIds = new uint256[](1);
    //     chainIds[0] = 28404; // This chain is not in config
    //     vm.expectRevert();
    //     deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    // }

    // TODO: Fix - This test is flaky, sometimes the JSON parser recovers
    // See https://github.com/ithacaxyz/account/issues/253
    // function test_RevertOnInvalidJSON() public {
    //     // Malformed JSON (missing closing brace)
    //     vm.writeFile(TEST_CONFIG_FILE, '{"28404": {"funderOwner": "0x1"');
    //
    //     uint256[] memory chainIds = new uint256[](1);
    //     chainIds[0] = 28404;
    //     vm.expectRevert();
    //     deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    // }

    // TODO: Fix deployment script to fail on invalid data types
    // See https://github.com/ithacaxyz/account/issues/253
    // function test_RevertOnInvalidDataType() public {
    //     string memory json = '{"28404": {';
    //     json = string.concat(json, '"funderOwner": "0x0000000000000000000000000000000000000001",');
    //     json = string.concat(json, '"funderSigner": "0x0000000000000000000000000000000000000002",');
    //     json = string.concat(json, '"isTestnet": "not_a_bool",'); // Should be boolean
    //     json = string.concat(json, '"l0SettlerOwner": "0x0000000000000000000000000000000000000003",');
    //     json = string.concat(json, '"layerZeroEndpoint": "0x0000000000000000000000000000000000000004",');
    //     json = string.concat(json, '"layerZeroEid": 1,');
    //     json = string.concat(json, '"maxRetries": 3,');
    //     json = string.concat(json, '"name": "Test",');
    //     json = string.concat(json, '"pauseAuthority": "0x0000000000000000000000000000000000000006",');
    //     json = string.concat(json, '"retryDelay": 5,');
    //     json = string.concat(json, '"settlerOwner": "0x0000000000000000000000000000000000000005",');
    //     json = string.concat(json, '"stages": ["basic"]}}');
    //
    //     vm.writeFile(TEST_CONFIG_FILE, json);
    //
    //     uint256[] memory chainIds = new uint256[](1);
    //     chainIds[0] = 28404;
    //     vm.expectRevert();
    //     deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    // }

    // TODO: Fix deployment script to fail on invalid chain ID format
    // See https://github.com/ithacaxyz/account/issues/253
    // function test_RevertOnInvalidChainId() public {
    //     // Config has string chain ID instead of number
    //     vm.writeFile(TEST_CONFIG_FILE, '{"not_a_number": {"name": "Test"}}');
    //
    //     uint256[] memory chainIds = new uint256[](0); // Deploy to all
    //     vm.expectRevert();
    //     deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    // }

    function test_ValidConfigDoesNotRevert() public withCleanup {
        string memory json = _buildValidConfig();
        vm.writeFile(TEST_CONFIG_FILE, json);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404;

        // This should not revert during config parsing
        // It will complete the deployment successfully on the test network
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    }

    function test_ValidConfigWithAllChainsDoesNotRevert() public withCleanup {
        string memory json = _buildValidConfig();
        vm.writeFile(TEST_CONFIG_FILE, json);

        uint256[] memory chainIds = new uint256[](0); // Empty array = all chains

        // This should parse all chains from config
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    }

    // Helper to build valid config JSON
    function _buildValidConfig() internal pure returns (string memory) {
        string memory json = '{"28404": {';
        json = string.concat(json, '"funderOwner": "0x0000000000000000000000000000000000000001",');
        json = string.concat(json, '"funderSigner": "0x0000000000000000000000000000000000000002",');
        json = string.concat(json, '"isTestnet": false,');
        json =
            string.concat(json, '"l0SettlerOwner": "0x0000000000000000000000000000000000000003",');
        json = string.concat(
            json, '"layerZeroEndpoint": "0x0000000000000000000000000000000000000004",'
        );
        json = string.concat(json, '"layerZeroEid": 1,');
        json = string.concat(json, '"maxRetries": 3,');
        json = string.concat(json, '"name": "Test",');
        json =
            string.concat(json, '"pauseAuthority": "0x0000000000000000000000000000000000000006",');
        json = string.concat(json, '"retryDelay": 5,');
        json = string.concat(json, '"settlerOwner": "0x0000000000000000000000000000000000000005",');
        json = string.concat(json, '"stages": ["basic"]}}');
        return json;
    }
}
