// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Orchestrator} from "./Orchestrator.sol";
import {IthacaAccount} from "./IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "./Simulator.sol";

/// @title IthacaFactory
/// @notice Factory contract for deterministic deployment of Ithaca Account contracts using CREATE2
/// @dev Deploy this factory first via Safe Singleton Factory, then use it to deploy all other contracts
contract IthacaFactory {
    // Custom errors
    error OrchestratorNotDeployed();
    error ImplementationNotDeployed();
    error DeploymentFailed();

    /// @notice Deploys the Orchestrator contract with CREATE2
    function deployOrchestrator(address pauseAuthority, bytes32 salt) public returns (address) {
        bytes memory bytecode =
            abi.encodePacked(type(Orchestrator).creationCode, abi.encode(pauseAuthority));
        return _deploy(bytecode, salt);
    }

    /// @notice Deploys the IthacaAccount implementation contract with CREATE2
    /// @dev Requires orchestrator to be deployed first
    function deployAccountImplementation(address orchestrator, bytes32 salt)
        public
        returns (address)
    {
        if (orchestrator.code.length == 0) revert OrchestratorNotDeployed();

        bytes memory bytecode =
            abi.encodePacked(type(IthacaAccount).creationCode, abi.encode(orchestrator));
        return _deploy(bytecode, salt);
    }

    /// @notice Deploys an EIP-7702 proxy for the account implementation
    /// @dev Requires implementation to be deployed first
    function deployAccountProxy(address implementation, bytes32 salt) public returns (address) {
        if (implementation.code.length == 0) revert ImplementationNotDeployed();

        bytes memory bytecode = LibEIP7702.proxyInitCode(implementation, address(0));
        return _deploy(bytecode, salt);
    }

    /// @notice Deploys the Simulator contract with CREATE2
    function deploySimulator(bytes32 salt) public returns (address) {
        bytes memory bytecode = type(Simulator).creationCode;
        return _deploy(bytecode, salt);
    }

    /// @notice Deploys all contracts in the correct order
    /// @dev Convenient function to deploy everything with a single transaction
    function deployAll(address pauseAuthority, bytes32 salt)
        external
        returns (
            address orchestrator,
            address accountImplementation,
            address accountProxy,
            address simulator
        )
    {
        orchestrator = deployOrchestrator(pauseAuthority, salt);
        accountImplementation = deployAccountImplementation(orchestrator, salt);
        accountProxy = deployAccountProxy(accountImplementation, salt);
        simulator = deploySimulator(salt);
    }

    /// @notice Predicts the Orchestrator deployment address
    /// @dev Call this before deployment to know the address in advance
    function predictOrchestratorAddress(address pauseAuthority, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory bytecode =
            abi.encodePacked(type(Orchestrator).creationCode, abi.encode(pauseAuthority));
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts the IthacaAccount implementation deployment address
    function predictAccountImplementationAddress(address orchestrator, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory bytecode =
            abi.encodePacked(type(IthacaAccount).creationCode, abi.encode(orchestrator));
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts the account proxy deployment address
    function predictAccountProxyAddress(address implementation, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory bytecode = LibEIP7702.proxyInitCode(implementation, address(0));
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts the Simulator deployment address
    function predictSimulatorAddress(bytes32 salt) external view returns (address) {
        bytes memory bytecode = type(Simulator).creationCode;
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts all contract addresses at once
    /// @dev Useful for verifying addresses before deployment
    function predictAddresses(address pauseAuthority, bytes32 salt)
        external
        view
        returns (
            address orchestrator,
            address accountImplementation,
            address accountProxy,
            address simulator
        )
    {
        orchestrator = this.predictOrchestratorAddress(pauseAuthority, salt);
        accountImplementation = this.predictAccountImplementationAddress(orchestrator, salt);
        accountProxy = this.predictAccountProxyAddress(accountImplementation, salt);
        simulator = this.predictSimulatorAddress(salt);
    }

    function _deploy(bytes memory bytecode, bytes32 salt) private returns (address deployed) {
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }

    function _computeAddress(bytes memory bytecode, bytes32 salt) private view returns (address) {
        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}
