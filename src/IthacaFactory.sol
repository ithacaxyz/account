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
    error InvalidCreationCode();

    // Creation code hashes for verification
    bytes32 private immutable ORCHESTRATOR_CREATION_CODE_HASH;
    bytes32 private immutable ACCOUNT_CREATION_CODE_HASH;
    bytes32 private immutable SIMULATOR_CREATION_CODE_HASH;

    constructor() {
        // Store hashes of creation codes at deployment time
        ORCHESTRATOR_CREATION_CODE_HASH = keccak256(type(Orchestrator).creationCode);
        ACCOUNT_CREATION_CODE_HASH = keccak256(type(IthacaAccount).creationCode);
        SIMULATOR_CREATION_CODE_HASH = keccak256(type(Simulator).creationCode);
    }

    /// @notice Deploys the Orchestrator contract with CREATE2
    /// @param pauseAuthority The pause authority address
    /// @param salt The salt for CREATE2
    /// @param creationCode The creation code for Orchestrator (must match stored hash)
    function deployOrchestrator(address pauseAuthority, bytes32 salt, bytes calldata creationCode)
        public
        returns (address)
    {
        // Verify creation code
        if (keccak256(creationCode) != ORCHESTRATOR_CREATION_CODE_HASH) {
            revert InvalidCreationCode();
        }

        bytes memory bytecode = abi.encodePacked(creationCode, abi.encode(pauseAuthority));
        return _deploy(bytecode, salt);
    }

    /// @notice Deploys the IthacaAccount implementation contract with CREATE2
    /// @dev Requires orchestrator to be deployed first
    /// @param orchestrator The orchestrator address
    /// @param salt The salt for CREATE2
    /// @param creationCode The creation code for IthacaAccount (must match stored hash)
    function deployAccountImplementation(
        address orchestrator,
        bytes32 salt,
        bytes calldata creationCode
    ) public returns (address) {
        if (orchestrator.code.length == 0) revert OrchestratorNotDeployed();

        // Verify creation code
        if (keccak256(creationCode) != ACCOUNT_CREATION_CODE_HASH) {
            revert InvalidCreationCode();
        }

        bytes memory bytecode = abi.encodePacked(creationCode, abi.encode(orchestrator));
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
    /// @param salt The salt for CREATE2
    /// @param creationCode The creation code for Simulator (must match stored hash)
    function deploySimulator(bytes32 salt, bytes calldata creationCode) public returns (address) {
        // Verify creation code
        if (keccak256(creationCode) != SIMULATOR_CREATION_CODE_HASH) {
            revert InvalidCreationCode();
        }

        return _deploy(creationCode, salt);
    }

    /// @notice Deploys all contracts in the correct order
    /// @dev Convenient function to deploy everything with a single transaction
    /// @param pauseAuthority The pause authority address
    /// @param salt The salt for CREATE2
    /// @param orchestratorCreationCode The creation code for Orchestrator
    /// @param accountCreationCode The creation code for IthacaAccount
    /// @param simulatorCreationCode The creation code for Simulator
    function deployAll(
        address pauseAuthority,
        bytes32 salt,
        bytes calldata orchestratorCreationCode,
        bytes calldata accountCreationCode,
        bytes calldata simulatorCreationCode
    )
        external
        returns (
            address orchestrator,
            address accountImplementation,
            address accountProxy,
            address simulator
        )
    {
        orchestrator = deployOrchestrator(pauseAuthority, salt, orchestratorCreationCode);
        accountImplementation = deployAccountImplementation(orchestrator, salt, accountCreationCode);
        accountProxy = deployAccountProxy(accountImplementation, salt);
        simulator = deploySimulator(salt, simulatorCreationCode);
    }

    /// @notice Predicts the Orchestrator deployment address
    /// @dev Call this before deployment to know the address in advance
    /// @param pauseAuthority The pause authority address
    /// @param salt The salt for CREATE2
    /// @param creationCode The creation code for Orchestrator
    function predictOrchestratorAddress(
        address pauseAuthority,
        bytes32 salt,
        bytes calldata creationCode
    ) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(creationCode, abi.encode(pauseAuthority));
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts the IthacaAccount implementation deployment address
    /// @param orchestrator The orchestrator address
    /// @param salt The salt for CREATE2
    /// @param creationCode The creation code for IthacaAccount
    function predictAccountImplementationAddress(
        address orchestrator,
        bytes32 salt,
        bytes calldata creationCode
    ) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(creationCode, abi.encode(orchestrator));
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts the account proxy deployment address
    /// @param implementation The implementation address
    /// @param salt The salt for CREATE2
    function predictAccountProxyAddress(address implementation, bytes32 salt)
        external
        view
        returns (address)
    {
        bytes memory bytecode = LibEIP7702.proxyInitCode(implementation, address(0));
        return _computeAddress(bytecode, salt);
    }

    /// @notice Predicts the Simulator deployment address
    /// @param salt The salt for CREATE2
    /// @param creationCode The creation code for Simulator
    function predictSimulatorAddress(bytes32 salt, bytes calldata creationCode)
        external
        view
        returns (address)
    {
        return _computeAddress(creationCode, salt);
    }

    /// @notice Predicts all contract addresses at once
    /// @dev Useful for verifying addresses before deployment
    /// @param pauseAuthority The pause authority address
    /// @param salt The salt for CREATE2
    /// @param orchestratorCreationCode The creation code for Orchestrator
    /// @param accountCreationCode The creation code for IthacaAccount
    /// @param simulatorCreationCode The creation code for Simulator
    function predictAddresses(
        address pauseAuthority,
        bytes32 salt,
        bytes calldata orchestratorCreationCode,
        bytes calldata accountCreationCode,
        bytes calldata simulatorCreationCode
    )
        external
        view
        returns (
            address orchestrator,
            address accountImplementation,
            address accountProxy,
            address simulator
        )
    {
        orchestrator =
            this.predictOrchestratorAddress(pauseAuthority, salt, orchestratorCreationCode);
        accountImplementation =
            this.predictAccountImplementationAddress(orchestrator, salt, accountCreationCode);
        accountProxy = this.predictAccountProxyAddress(accountImplementation, salt);
        simulator = this.predictSimulatorAddress(salt, simulatorCreationCode);
    }

    /// @notice Get the stored creation code hashes
    function getCreationCodeHashes()
        external
        view
        returns (bytes32 orchestratorHash, bytes32 accountHash, bytes32 simulatorHash)
    {
        return (
            ORCHESTRATOR_CREATION_CODE_HASH,
            ACCOUNT_CREATION_CODE_HASH,
            SIMULATOR_CREATION_CODE_HASH
        );
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
