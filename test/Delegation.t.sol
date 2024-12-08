// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Delegation} from "../src/Delegation.sol";

contract DelegationTest is SoladyTest {
    Delegation public delegation;

    function setUp() public {
        delegation = new Delegation();
    }

    struct _TestTemps {
        Delegation.Key key;
        Delegation.Key retrievedKey;
        bytes32 keyHash;
    }

    function testApproveAndRevokeKey(bytes32) public {
        _TestTemps memory t;
        t.key;

        t.key.keyType = Delegation.KeyType(_randomUniform() & 1);
        t.key.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));
        t.key.publicKey = _truncateBytes(_randomBytes(), 0x1ff);

        assertEq(delegation.keyCount(), 0);

        vm.prank(address(delegation));
        delegation.authorize(t.key);

        assertEq(delegation.keyCount(), 1);

        t.retrievedKey = delegation.keyAt(0);
        assertEq(uint8(t.retrievedKey.keyType), uint8(t.key.keyType));
        assertEq(t.retrievedKey.expiry, t.key.expiry);
        assertEq(t.retrievedKey.publicKey, t.key.publicKey);

        t.key.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));

        vm.prank(address(delegation));
        delegation.authorize(t.key);

        assertEq(delegation.keyCount(), 1);

        t.retrievedKey = delegation.keyAt(0);
        assertEq(uint8(t.retrievedKey.keyType), uint8(t.key.keyType));
        assertEq(t.retrievedKey.expiry, t.key.expiry);
        assertEq(t.retrievedKey.publicKey, t.key.publicKey);

        t.keyHash = delegation.hash(t.key);
        t.retrievedKey = delegation.getKey(t.keyHash);
        assertEq(uint8(t.retrievedKey.keyType), uint8(t.key.keyType));
        assertEq(t.retrievedKey.expiry, t.key.expiry);
        assertEq(t.retrievedKey.publicKey, t.key.publicKey);

        vm.prank(address(delegation));
        delegation.revoke(t.keyHash);

        assertEq(delegation.keyCount(), 0);

        vm.expectRevert(bytes4(keccak256("IndexOutOfBounds()")));
        delegation.keyAt(0);

        t.keyHash = delegation.hash(t.key);
        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        t.retrievedKey = delegation.getKey(t.keyHash);
    }
}
