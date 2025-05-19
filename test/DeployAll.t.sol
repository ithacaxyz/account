// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import "../src/DeployAll.sol";

contract LibPREPTest is SoladyTest {
    function testDeployAll() public {
        DeployAll deployAll = new DeployAll();

        address orchestrator = deployAll.orchestrator();

        assertEq(
            PortoAccount(payable(deployAll.accountImplementation())).ORCHESTRATOR(), orchestrator
        );

        address eoa = _randomUniqueHashedAddress();

        vm.etch(eoa, abi.encodePacked(hex"ef0100", deployAll.accountImplementation()));
        assertEq(PortoAccount(payable(eoa)).ORCHESTRATOR(), orchestrator);

        vm.etch(eoa, abi.encodePacked(hex"ef0100", deployAll.accountProxy()));
        assertEq(PortoAccount(payable(eoa)).ORCHESTRATOR(), orchestrator);
    }
}
