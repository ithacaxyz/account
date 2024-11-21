// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {ExperimentalDelegation} from "../src/ExperimentalDelegation.sol";

contract ExperimentalDelegationTest is SoladyTest {
    ExperimentalDelegation public ed;

    function setUp() public {
        ed = new ExperimentalDelegation();
    }

    struct _TestTemps {
        ExperimentalDelegation.Key key;
        ExperimentalDelegation.Key retrievedKey;
        bytes32 keyHash;
    }

    function testApproveAndRevokeKey(bytes32) public {
        _TestTemps memory t;
        t.key;

        t.key.keyType = ExperimentalDelegation.KeyType(_randomUniform() & 1);
        t.key.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));
        t.key.publicKey = _truncateBytes(_randomBytes(), 0x1ff);

        assertEq(ed.keyCount(), 0);

        vm.prank(address(ed));
        ed.authorize(t.key);

        assertEq(ed.keyCount(), 1);

        t.retrievedKey = ed.keyAt(0);
        assertEq(uint8(t.retrievedKey.keyType), uint8(t.key.keyType));
        assertEq(t.retrievedKey.expiry, t.key.expiry);
        assertEq(t.retrievedKey.publicKey, t.key.publicKey);

        t.key.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));

        vm.prank(address(ed));
        ed.authorize(t.key);

        assertEq(ed.keyCount(), 1);

        t.retrievedKey = ed.keyAt(0);
        assertEq(uint8(t.retrievedKey.keyType), uint8(t.key.keyType));
        assertEq(t.retrievedKey.expiry, t.key.expiry);
        assertEq(t.retrievedKey.publicKey, t.key.publicKey);

        t.keyHash = ed.hash(t.key);
        t.retrievedKey = ed.getKey(t.keyHash);
        assertEq(uint8(t.retrievedKey.keyType), uint8(t.key.keyType));
        assertEq(t.retrievedKey.expiry, t.key.expiry);
        assertEq(t.retrievedKey.publicKey, t.key.publicKey);

        vm.prank(address(ed));
        ed.revoke(t.keyHash);

        assertEq(ed.keyCount(), 0);

        vm.expectRevert(bytes4(keccak256("IndexOutOfBounds()")));
        ed.keyAt(0);

        t.keyHash = ed.hash(t.key);
        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        t.retrievedKey = ed.getKey(t.keyHash);
    }
}
