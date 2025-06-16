// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {IthacaFactory} from "../src/IthacaFactory.sol";
import {Orchestrator} from "../src/Orchestrator.sol";
import {IthacaAccount} from "../src/IthacaAccount.sol";
import {Simulator} from "../src/Simulator.sol";

contract IthacaFactoryTest is Test {
    IthacaFactory public factory;
    address constant PAUSE_AUTHORITY = address(0xdead);
    bytes32 constant TEST_SALT = keccak256("test.salt.v1");

    // Store creation codes for testing
    bytes orchestratorCreationCode;
    bytes accountCreationCode;
    bytes simulatorCreationCode;

    function setUp() public {
        // Deploy the factory
        factory = new IthacaFactory();

        // Store creation codes
        orchestratorCreationCode = type(Orchestrator).creationCode;
        accountCreationCode = type(IthacaAccount).creationCode;
        simulatorCreationCode = type(Simulator).creationCode;
    }

    function testDeployOrchestrator() public {
        address deployed =
            factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT, orchestratorCreationCode);

        // Verify contract was deployed
        assertTrue(deployed.code.length > 0, "Orchestrator not deployed");

        // Verify it's an Orchestrator
        Orchestrator orchestrator = Orchestrator(payable(deployed));
        (address authority,) = orchestrator.getPauseConfig();
        assertEq(authority, PAUSE_AUTHORITY, "Wrong pause authority");
    }

    function testDeployAccountImplementation() public {
        // First deploy orchestrator
        address orchestrator =
            factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT, orchestratorCreationCode);

        // Deploy account implementation
        bytes32 accountSalt = keccak256("account.salt");
        address deployed =
            factory.deployAccountImplementation(orchestrator, accountSalt, accountCreationCode);

        // Verify contract was deployed
        assertTrue(deployed.code.length > 0, "Account implementation not deployed");

        // Verify it's an IthacaAccount
        IthacaAccount account = IthacaAccount(payable(deployed));
        assertEq(account.ORCHESTRATOR(), orchestrator, "Wrong orchestrator");
    }

    function testDeployAll() public {
        (address orchestrator, address accountImpl, address accountProxy, address simulator) =
        factory.deployAll(
            PAUSE_AUTHORITY,
            TEST_SALT,
            orchestratorCreationCode,
            accountCreationCode,
            simulatorCreationCode
        );

        // Verify all contracts deployed
        assertTrue(orchestrator.code.length > 0, "Orchestrator not deployed");
        assertTrue(accountImpl.code.length > 0, "Account implementation not deployed");
        assertTrue(accountProxy.code.length > 0, "Account proxy not deployed");
        assertTrue(simulator.code.length > 0, "Simulator not deployed");

        // Verify orchestrator
        (address authority,) = Orchestrator(payable(orchestrator)).getPauseConfig();
        assertEq(authority, PAUSE_AUTHORITY, "Wrong pause authority");

        // Verify account implementation
        assertEq(
            IthacaAccount(payable(accountImpl)).ORCHESTRATOR(),
            orchestrator,
            "Wrong orchestrator in account"
        );
    }

    function testPredictAddresses() public {
        // Get predicted addresses
        (
            address predictedOrchestrator,
            address predictedAccountImpl,
            address predictedAccountProxy,
            address predictedSimulator
        ) = factory.predictAddresses(
            PAUSE_AUTHORITY,
            TEST_SALT,
            orchestratorCreationCode,
            accountCreationCode,
            simulatorCreationCode
        );

        // Deploy contracts
        (
            address deployedOrchestrator,
            address deployedAccountImpl,
            address deployedAccountProxy,
            address deployedSimulator
        ) = factory.deployAll(
            PAUSE_AUTHORITY,
            TEST_SALT,
            orchestratorCreationCode,
            accountCreationCode,
            simulatorCreationCode
        );

        // Verify predictions match deployments
        assertEq(deployedOrchestrator, predictedOrchestrator, "Orchestrator address mismatch");
        assertEq(
            deployedAccountImpl, predictedAccountImpl, "Account implementation address mismatch"
        );
        assertEq(deployedAccountProxy, predictedAccountProxy, "Account proxy address mismatch");
        assertEq(deployedSimulator, predictedSimulator, "Simulator address mismatch");
    }

    function testDeterministicAcrossChains() public {
        // Deploy on "chain 1"
        bytes32 salt = keccak256("deterministic.test");

        (address orchestrator1, address accountImpl1, address accountProxy1, address simulator1) =
        factory.deployAll(
            PAUSE_AUTHORITY,
            salt,
            orchestratorCreationCode,
            accountCreationCode,
            simulatorCreationCode
        );

        // Deploy another factory (simulating different chain)
        IthacaFactory factory2 = new IthacaFactory();

        // Get predicted addresses from factory2
        (
            address predictedOrchestrator2,
            address predictedAccountImpl2,
            address predictedAccountProxy2,
            address predictedSimulator2
        ) = factory2.predictAddresses(
            PAUSE_AUTHORITY,
            salt,
            orchestratorCreationCode,
            accountCreationCode,
            simulatorCreationCode
        );

        // The predicted addresses should be different because factories have different addresses
        assertTrue(
            orchestrator1 != predictedOrchestrator2, "Addresses should differ across factories"
        );
    }

    function testCannotDeployAccountWithoutOrchestrator() public {
        vm.expectRevert(IthacaFactory.OrchestratorNotDeployed.selector);
        factory.deployAccountImplementation(
            address(0x1234), // non-existent orchestrator
            TEST_SALT,
            accountCreationCode
        );
    }

    function testCannotDeployProxyWithoutImplementation() public {
        vm.expectRevert(IthacaFactory.ImplementationNotDeployed.selector);
        factory.deployAccountProxy(address(0x1234), TEST_SALT); // non-existent implementation
    }

    function testCannotDeployWithSameSaltTwice() public {
        // Deploy once
        factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT, orchestratorCreationCode);

        // Try to deploy again with same salt - should revert with DeploymentFailed
        vm.expectRevert(IthacaFactory.DeploymentFailed.selector);
        factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT, orchestratorCreationCode);
    }

    function testInvalidCreationCode() public {
        // Test with wrong creation code for Orchestrator
        bytes memory wrongCode = hex"deadbeef";

        vm.expectRevert(IthacaFactory.InvalidCreationCode.selector);
        factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT, wrongCode);

        // Test with wrong creation code for Account
        address orchestrator =
            factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT, orchestratorCreationCode);

        vm.expectRevert(IthacaFactory.InvalidCreationCode.selector);
        factory.deployAccountImplementation(orchestrator, TEST_SALT, wrongCode);

        // Test with wrong creation code for Simulator
        vm.expectRevert(IthacaFactory.InvalidCreationCode.selector);
        factory.deploySimulator(TEST_SALT, wrongCode);
    }

    function testGetCreationCodeHashes() public {
        (bytes32 orchestratorHash, bytes32 accountHash, bytes32 simulatorHash) =
            factory.getCreationCodeHashes();

        // Verify hashes match
        assertEq(orchestratorHash, keccak256(orchestratorCreationCode), "Wrong orchestrator hash");
        assertEq(accountHash, keccak256(accountCreationCode), "Wrong account hash");
        assertEq(simulatorHash, keccak256(simulatorCreationCode), "Wrong simulator hash");
    }
}
