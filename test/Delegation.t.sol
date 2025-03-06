// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";

contract DelegationTest is BaseTest {
    function testSignatureCheckerApproval(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = _randomChance(32);

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        address[] memory checkers = new address[](_bound(_random(), 1, 3));
        for (uint256 i; i < checkers.length; ++i) {
            checkers[i] = _randomUniqueHashedAddress();
            vm.prank(d.eoa);
            d.d.setSignatureCheckerApproval(k.keyHash, checkers[i], true);
        }
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, checkers.length);

        bytes32 digest = bytes32(_randomUniform());
        bytes memory sig = _sig(k, digest);
        assertEq(
            d.d.isValidSignature(digest, sig) == Delegation.isValidSignature.selector,
            k.k.isSuperAdmin
        );

        vm.prank(checkers[_randomUniform() % checkers.length]);
        assertEq(d.d.isValidSignature(digest, sig), Delegation.isValidSignature.selector);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k.k));

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        d.d.isValidSignature(digest, sig);

        if (k.k.isSuperAdmin) k.k.isSuperAdmin = _randomChance(2);
        vm.prank(d.eoa);
        d.d.authorize(k.k);

        assertEq(
            d.d.isValidSignature(digest, sig) == Delegation.isValidSignature.selector,
            k.k.isSuperAdmin
        );
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, 0);
    }

    function testExecuteDelegateCall(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        address implementation = address(new MockSampleDelegateCallTarget(0));
        address[] memory callers = new address[](_bound(_random(), 1, 3));

        vm.startPrank(d.eoa);
        d.d.setImplementationApproval(implementation, true);
        for (uint256 i; i < callers.length; ++i) {
            callers[i] = _randomUniqueHashedAddress();
            d.d.setImplementationCallerApproval(implementation, callers[i], true);
        }
        vm.stopPrank();

        if (_randomChance(8)) {
            assertEq(d.d.approvedImplementations().length, 1);
            assertEq(d.d.approvedImplementations()[0], implementation);
            assertEq(d.d.approvedImplementationCallers(implementation).length, callers.length);
        }

        if (_randomChance(32)) {
            vm.prank(d.eoa);
            d.d.setImplementationApproval(implementation, false);

            assertEq(d.d.approvedImplementations().length, 0);
            assertEq(d.d.approvedImplementationCallers(implementation).length, 0);
            vm.prank(d.eoa);
            d.d.setImplementationApproval(implementation, true);
            assertEq(d.d.approvedImplementations().length, 1);
            assertEq(d.d.approvedImplementationCallers(implementation).length, 0);
            return;
        }

        bytes32 specialStorageValue = bytes32(_randomUniform());
        bytes memory executionData = abi.encodePacked(
            implementation,
            abi.encodeWithSignature(
                "setStorage(bytes32,bytes32)", keccak256("hehe"), specialStorageValue
            )
        );

        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(_randomUniqueHashedAddress());
        d.d.execute(_ERC7579_DELEGATE_CALL_MODE, executionData);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        d.d.execute(_ERC7579_DELEGATE_CALL_MODE, executionData);

        do {
            vm.prank(callers[_randomUniform() % callers.length]);
            d.d.execute(_ERC7579_DELEGATE_CALL_MODE, executionData);
            assertEq(vm.load(d.eoa, keccak256("hehe")), specialStorageValue);
        } while (_randomChance(64));

        if (_randomChance(2)) {
            vm.prank(d.eoa);
            d.d.setImplementationApproval(implementation, false);

            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            vm.prank(callers[_randomUniform() % callers.length]);
            d.d.execute(_ERC7579_DELEGATE_CALL_MODE, executionData);
        } else {
            address caller = callers[_randomUniform() % callers.length];
            vm.prank(d.eoa);
            d.d.setImplementationCallerApproval(implementation, caller, false);

            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            vm.prank(caller);
            d.d.execute(_ERC7579_DELEGATE_CALL_MODE, executionData);
        }
    }

    function testApproveAndRevokeKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        Delegation.Key memory k;
        Delegation.Key memory kRetrieved;

        k.keyType = Delegation.KeyType(_randomUniform() & 1);
        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));
        k.publicKey = _truncateBytes(_randomBytes(), 0x1ff);

        assertEq(d.d.keyCount(), 0);

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        kRetrieved = d.d.getKey(_hash(k));
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k));

        assertEq(d.d.keyCount(), 0);

        vm.expectRevert(bytes4(keccak256("IndexOutOfBounds()")));
        d.d.keyAt(0);

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        kRetrieved = d.d.getKey(_hash(k));
    }
}
