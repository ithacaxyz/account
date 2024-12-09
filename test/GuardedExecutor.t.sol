// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {GuardedExecutor} from "../src/GuardedExecutor.sol";

contract EntryPointTest is SoladyTest, GuardedExecutor {
    function testHash(bytes32 keyHash, address target, bytes4 fnSel) public pure {
        bytes32 expected = keccak256(abi.encodePacked(fnSel, keyHash, target));
        assertEq(_hash(keyHash, target, fnSel), expected);
    }

    function testIsSelfExecute(address target, bytes4 fnSel) public view {
        bool expected = target == address(this) && fnSel == 0xe9ae5c53;
        assertEq(_isSelfExecute(_brutalized(target), fnSel), expected);
    }
}
