// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";

contract DelegationTest is BaseTest {
    struct _TestExecuteWithSignatureTemps {
        TargetFunctionPayload[] targetFunctionPayloads;
        ERC7821.Call[] calls;
        uint256 n;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testExecuteWithSignature(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        _TestExecuteWithSignatureTemps memory t;
        t.n = _bound(_randomUniform(), 1, 5);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.n);
        t.calls = new ERC7821.Call[](t.n);
        for (uint256 i; i < t.n; ++i) {
            uint256 value = _random() % 0.1 ether;
            bytes memory data = _truncateBytes(_randomBytes(), 0xff);
            t.calls[i] = _thisTargetFunctionCall(value, data);
            t.targetFunctionPayloads[i].value = value;
            t.targetFunctionPayloads[i].data = data;
        }
        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        if (_randomChance(32)) {
            signature = _sig(_randomEIP7702DelegatedEOA(), d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        if (_randomChance(32)) {
            vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
        }

        if (_randomChance(32)) {
            t.nonce = d.d.getNonce(0);
            signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        for (uint256 i; i < t.n; ++i) {
            assertEq(targetFunctionPayloads[i].by, d.eoa);
            assertEq(targetFunctionPayloads[i].value, t.targetFunctionPayloads[i].value);
            assertEq(targetFunctionPayloads[i].data, t.targetFunctionPayloads[i].data);
        }
    }

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

    struct _TestUpgradeDelegationWithPassKeyTemps {
        uint256 randomVersion;
        address implementation;
        ERC7821.Call[] calls;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testUpgradeDelegationWithPassKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _TestUpgradeDelegationWithPassKeyTemps memory t;
        t.randomVersion = _randomUniform();
        t.implementation = address(new MockSampleDelegateCallTarget(t.randomVersion));

        t.calls = new ERC7821.Call[](1);
        t.calls[0].data =
            abi.encodeWithSignature("upgradeProxyDelegation(address)", t.implementation);

        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        assertEq(MockSampleDelegateCallTarget(d.eoa).version(), t.randomVersion);
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

        if (_randomChance(8)) {
            bytes memory data = _truncateBytes(_randomBytes(), 0xff);
            vm.prank(callers[_randomUniform() % callers.length]);
            (bool success, bytes memory result) = d.eoa.call(
                abi.encodeWithSignature(
                    "execute(bytes32,bytes)",
                    _ERC7579_DELEGATE_CALL_MODE,
                    abi.encodePacked(
                        implementation, abi.encodeWithSignature("revertWithData(bytes)", data)
                    )
                )
            );
            assertFalse(success);
            assertEq(result, abi.encodeWithSignature("ErrorWithData(bytes)", data));
        } else if (_randomChance(2)) {
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
