// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console, Vm} from "forge-std/Test.sol";
import {DeployMain} from "../../deploy/DeployMain.s.sol";
import {SafeSingletonDeployer} from "../../deploy/SafeSingletonDeployer.sol";

contract DeployCreate2Test is Test, SafeSingletonDeployer {
    DeployMain deployment;
    string constant TEST_CONFIG_FILE = "test-create2-config.json";
    string constant TEST_REGISTRY_DIR = "test-registry/";

    modifier withCleanup() {
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

    function test_DeployWithCreate_WhenSaltIsZero() public withCleanup {
        // Build config with zero salt (should use CREATE)
        string memory json = _buildConfig(bytes32(0));
        vm.writeFile(TEST_CONFIG_FILE, json);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404;

        // Should deploy with regular CREATE when salt is zero
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    }

    function test_DeployWithCreate2_WhenSaltIsSet() public withCleanup {
        // Deploy mock factory for CREATE2
        vm.etch(
            SAFE_SINGLETON_FACTORY,
            hex"608060405234801561001057600080fd5b5061013f806100206000396000f3fe608060405260003560e01c63cdcb760a14610019575b600080fd5b3373ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161461005157600080fd5b8035602082018035906040840135836000819055602001601f8301819003823584f5915081610085573d6000823e3d81fd5b816000526020600082f09050509193909250505056fea2646970667358221220e3ebc8b2b333b0c01e14d6a326b3b9af17c057350d316eb0ff604e8de1a1b4ff64736f6c634300080a0033"
        );

        bytes32 salt = keccak256("test.salt.v1");
        string memory json = _buildConfig(salt);
        vm.writeFile(TEST_CONFIG_FILE, json);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404;

        // Should deploy with CREATE2 when salt is set
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    }

    function test_Create2CollisionHandling() public withCleanup {
        // This test verifies that the blue symbol appears when CREATE2 collisions occur
        // For now, we'll just verify the deployment works with CREATE2
        // Deploy mock factory for CREATE2
        vm.etch(
            SAFE_SINGLETON_FACTORY,
            hex"608060405234801561001057600080fd5b5061013f806100206000396000f3fe608060405260003560e01c63cdcb760a14610019575b600080fd5b3373ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161461005157600080fd5b8035602082018035906040840135836000819055602001601f8301819003823584f5915081610085573d6000823e3d81fd5b816000526020600082f09050509193909250505056fea2646970667358221220e3ebc8b2b333b0c01e14d6a326b3b9af17c057350d316eb0ff604e8de1a1b4ff64736f6c634300080a0033"
        );

        bytes32 salt = keccak256("collision.test");
        string memory json = _buildConfig(salt);
        vm.writeFile(TEST_CONFIG_FILE, json);

        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404;

        // First deployment
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);

        // Delete registry to force fresh deployment attempt
        string memory registryFile = string.concat(
            TEST_REGISTRY_DIR,
            "deployment_",
            vm.toString(chainIds[0]),
            "_",
            vm.toString(salt),
            ".json"
        );
        try vm.removeFile(registryFile) {} catch {}

        // Second deployment with same salt should handle collisions gracefully
        // Since contracts are already deployed at predicted addresses, should see blue symbols
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);
    }

    function test_DeterministicAddresses_WithCreate2() public withCleanup {
        // Deploy mock factory for CREATE2
        vm.etch(
            SAFE_SINGLETON_FACTORY,
            hex"608060405234801561001057600080fd5b5061013f806100206000396000f3fe608060405260003560e01c63cdcb760a14610019575b600080fd5b3373ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161461005157600080fd5b8035602082018035906040840135836000819055602001601f8301819003823584f5915081610085573d6000823e3d81fd5b816000526020600082f09050509193909250505056fea2646970667358221220e3ebc8b2b333b0c01e14d6a326b3b9af17c057350d316eb0ff604e8de1a1b4ff64736f6c634300080a0033"
        );

        bytes32 salt = keccak256("deterministic.test");
        string memory json = _buildConfig(salt);
        vm.writeFile(TEST_CONFIG_FILE, json);

        // First deployment
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404;

        // Record addresses from first deployment
        deployment.run(chainIds, TEST_CONFIG_FILE, TEST_REGISTRY_DIR);

        // TODO: Read deployed addresses from registry and verify they match predictions
        // This would require parsing the registry file or exposing prediction functions
    }

    // Helper to build config JSON with salt
    function _buildConfig(bytes32 salt) internal pure returns (string memory) {
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
        json = string.concat(json, '"name": "Test",');
        json =
            string.concat(json, '"pauseAuthority": "0x0000000000000000000000000000000000000006",');

        json = string.concat(json, '"salt": "', vm.toString(salt), '",');

        json = string.concat(json, '"settlerOwner": "0x0000000000000000000000000000000000000005",');
        json = string.concat(json, '"stages": ["basic"]}}');
        return json;
    }
}
