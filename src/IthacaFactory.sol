// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Orchestrator} from "./Orchestrator.sol";
import {IthacaAccount} from "./IthacaAccount.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {Simulator} from "./Simulator.sol";

contract IthacaFactory {
    address private constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

    function deployOrchestrator(address pauseAuthority, bytes32 salt) public returns (address) {
        bytes memory creationCode = type(Orchestrator).creationCode;
        bytes memory args = abi.encode(pauseAuthority);
        return _deploy(creationCode, args, salt);
    }

    function deployAccountImplementation(address orchestrator, bytes32 salt)
        public
        returns (address)
    {
        bytes memory creationCode = type(IthacaAccount).creationCode;
        bytes memory args = abi.encode(orchestrator);
        return _deploy(creationCode, args, salt);
    }

    function deployAccountProxy(address implementation, bytes32 salt) public returns (address) {
        bytes memory proxyCode = LibEIP7702.proxyInitCode(implementation, address(0));
        return _deploy(proxyCode, "", salt);
    }

    function deploySimulator(bytes32 salt) public returns (address) {
        bytes memory creationCode = type(Simulator).creationCode;
        return _deploy(creationCode, "", salt);
    }

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

    function predictOrchestratorAddress(address pauseAuthority, bytes32 salt)
        external
        pure
        returns (address)
    {
        bytes memory creationCode = type(Orchestrator).creationCode;
        bytes memory args = abi.encode(pauseAuthority);
        return _computeAddress(creationCode, args, salt);
    }

    function predictAccountImplementationAddress(address orchestrator, bytes32 salt)
        external
        pure
        returns (address)
    {
        bytes memory creationCode = type(IthacaAccount).creationCode;
        bytes memory args = abi.encode(orchestrator);
        return _computeAddress(creationCode, args, salt);
    }

    function predictAccountProxyAddress(address implementation, bytes32 salt)
        external
        pure
        returns (address)
    {
        bytes memory proxyCode = LibEIP7702.proxyInitCode(implementation, address(0));
        return _computeAddress(proxyCode, "", salt);
    }

    function predictSimulatorAddress(bytes32 salt) external pure returns (address) {
        bytes memory creationCode = type(Simulator).creationCode;
        return _computeAddress(creationCode, "", salt);
    }

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

    function _deploy(bytes memory creationCode, bytes memory args, bytes32 salt)
        private
        returns (address deployed)
    {
        bytes memory callData = abi.encodePacked(salt, creationCode, args);

        (bool success, bytes memory result) = SAFE_SINGLETON_FACTORY.call(callData);
        require(success, "IthacaFactory: deployment failed");

        deployed = address(bytes20(result));
        require(deployed != address(0), "IthacaFactory: deployment returned zero address");
    }

    function _computeAddress(bytes memory creationCode, bytes memory args, bytes32 salt)
        private
        pure
        returns (address)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                SAFE_SINGLETON_FACTORY,
                salt,
                keccak256(abi.encodePacked(creationCode, args))
            )
        );
        return address(uint160(uint256(hash)));
    }
}
