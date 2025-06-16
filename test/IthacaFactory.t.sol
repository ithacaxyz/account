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

    function setUp() public {
        // Deploy the factory
        factory = new IthacaFactory();
    }

    function testDeployOrchestrator() public {
        address deployed = factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT);

        // Verify contract was deployed
        assertTrue(deployed.code.length > 0, "Orchestrator not deployed");

        // Verify it's an Orchestrator
        Orchestrator orchestrator = Orchestrator(payable(deployed));
        (address authority,) = orchestrator.getPauseConfig();
        assertEq(authority, PAUSE_AUTHORITY, "Wrong pause authority");
    }

    function testDeployAccountImplementation() public {
        // First deploy orchestrator
        address orchestrator = factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT);

        // Deploy account implementation
        bytes32 accountSalt = keccak256("account.salt");
        address deployed = factory.deployAccountImplementation(orchestrator, accountSalt);

        // Verify contract was deployed
        assertTrue(deployed.code.length > 0, "Account implementation not deployed");

        // Verify it's an IthacaAccount
        IthacaAccount account = IthacaAccount(payable(deployed));
        assertEq(account.ORCHESTRATOR(), orchestrator, "Wrong orchestrator");
    }

    function testDeployAll() public {
        (address orchestrator, address accountImpl, address accountProxy, address simulator) =
            factory.deployAll(PAUSE_AUTHORITY, TEST_SALT);

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
        ) = factory.predictAddresses(PAUSE_AUTHORITY, TEST_SALT);

        // Deploy contracts
        (
            address deployedOrchestrator,
            address deployedAccountImpl,
            address deployedAccountProxy,
            address deployedSimulator
        ) = factory.deployAll(PAUSE_AUTHORITY, TEST_SALT);

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
            factory.deployAll(PAUSE_AUTHORITY, salt);

        // Simulate deployment on "chain 2" with same salt
        // In reality, the addresses should be the same due to CREATE2
        (
            address predictedOrchestrator2,
            address predictedAccountImpl2,
            address predictedAccountProxy2,
            address predictedSimulator2
        ) = factory.predictAddresses(PAUSE_AUTHORITY, salt);

        // Since we're on the same chain in test, predictions should match deployed
        assertEq(orchestrator1, predictedOrchestrator2, "Orchestrator not deterministic");
        assertEq(accountImpl1, predictedAccountImpl2, "Account implementation not deterministic");
        assertEq(accountProxy1, predictedAccountProxy2, "Account proxy not deterministic");
        assertEq(simulator1, predictedSimulator2, "Simulator not deterministic");
    }

    function testCannotDeployToSameAddressTwice() public {
        // Deploy once
        factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT);

        // Try to deploy again with same salt - should revert
        vm.expectRevert();
        factory.deployOrchestrator(PAUSE_AUTHORITY, TEST_SALT);
    }

    function testCannotDeployProxyWithoutImplementation() public {
        // Try to deploy proxy with non-existent implementation - should revert
        address fakeImplementation = address(0x1234);
        vm.expectRevert(IthacaFactory.ImplementationNotDeployed.selector);
        factory.deployAccountProxy(fakeImplementation, TEST_SALT);
    }

    function testCannotDeployAccountWithoutOrchestrator() public {
        // Try to deploy account with non-existent orchestrator - should revert
        address fakeOrchestrator = address(0x5678);
        vm.expectRevert(IthacaFactory.OrchestratorNotDeployed.selector);
        factory.deployAccountImplementation(fakeOrchestrator, TEST_SALT);
    }
}
