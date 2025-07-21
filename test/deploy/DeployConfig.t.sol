// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {DeployMain} from "../../deploy/DeployMain.s.sol";

contract DeployConfigTest is Test {
    DeployMain deployment;
    string constant TEST_REGISTRY_DIR = "deploy/registry/test/";

    modifier withCleanup() {
        _;

        // Clean up any registry directory if it was created
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

    function test_DeployToSpecificChain() public withCleanup {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404; // Porto Devnet

        // This should not revert - it uses the default config
        deployment.run(chainIds);
    }

    function test_DeployWithCustomRegistry() public withCleanup {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 28404;

        // Deploy with custom registry path
        deployment.run(chainIds, TEST_REGISTRY_DIR);
    }

    function test_RevertOnInvalidChainId() public withCleanup {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 999999; // Non-existent chain

        vm.expectRevert("Chain ID not found in config: 999999");
        deployment.run(chainIds);
    }
}
