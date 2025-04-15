// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import "../src/LibNonce.sol";

contract LibNonceTest is BaseTest {
    mapping(uint192 => LibStorage.Ref) seqMap;

    function testCheckAndIncrementTypeUint256MaxNonceReverts() public {
        vm.expectRevert(LibNonce.InvalidNonce.selector);
        this.checkAndIncrementTypeUint256MaxNonce();
    }

    function checkAndIncrementTypeUint256MaxNonce() public {
        LibNonce.checkAndIncrement(seqMap, type(uint256).max);
    }
}
