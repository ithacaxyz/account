// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Delegation} from "../src/Delegation.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {GasBurnerLib} from "solady/utils/GasBurnerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {Delegation} from "../src/Delegation.sol";
import {EntryPoint, MockEntryPoint} from "./utils/mocks/MockEntryPoint.sol";
import {ERC20, MockPaymentToken} from "./utils/mocks/MockPaymentToken.sol";


contract SampleTarget {
    uint256 public x;

    function setX(uint256 newX) public {
        x = newX;
    }
}

contract LibPREPTest is SoladyTest {
    MockEntryPoint ep;
    MockPaymentToken paymentToken;
    address delegation;
    SampleTarget sampleTarget;

    function setUp() public {
        sampleTarget = new SampleTarget();
        Delegation tempDelegation = new Delegation();
        ep = MockEntryPoint(payable(tempDelegation.ENTRY_POINT()));
        MockEntryPoint tempMockEntryPoint = new MockEntryPoint();
        vm.etch(tempDelegation.ENTRY_POINT(), address(tempMockEntryPoint).code);
        delegation = LibClone.clone(address(new Delegation()));
        paymentToken = new MockPaymentToken();
    }

    function testPREP(bytes32) public {
        Delegation.Call[] memory calls = new Delegation.Call[](1);
        calls[0].target = address(sampleTarget);
        calls[0].data = abi.encodeWithSelector(SampleTarget.setX.selector, uint256(123));
    }
    
}
