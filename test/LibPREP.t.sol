// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {LibPREP} from "../src/LibPREP.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";

contract SampleTarget {
    uint256 public x;

    function setX(uint256 newX) public {
        x = newX;
    }
}

contract LibPREPTest is BaseTest {
    using LibRLP for LibRLP.List;

    SampleTarget sampleTarget;

    function setUp() public override {
        super.setUp();
        sampleTarget = new SampleTarget();
    }

    struct _TestTemps {
        bytes32 digest;
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint256 x;
        uint256 privateKey;
        bytes32 keyHash;
        bytes32 saltAndDelegation;
    }

    function testPREP() public {
        _TestTemps memory t;
        EntryPoint.UserOp memory u;

        {
            Delegation.Key memory k;
            k.keyType = Delegation.KeyType.P256;
            t.privateKey = _randomUniform() & type(uint192).max;
            (uint256 x, uint256 y) = vm.publicKeyP256(t.privateKey);
            k.publicKey = abi.encode(x, y);
            k.isSuperAdmin = true;
            t.keyHash = _hash(k);

            Delegation.Call[] memory initCalls = new Delegation.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, k);

            (t.saltAndDelegation, u.eoa) = _mine(_computePREPDigest(initCalls));
            u.initData = abi.encode(initCalls, abi.encodePacked(t.saltAndDelegation));
        }

        t.x = _randomUniform();
        Delegation.Call[] memory calls = new Delegation.Call[](1);
        calls[0].target = address(sampleTarget);
        calls[0].data = abi.encodeWithSelector(SampleTarget.setX.selector, t.x);

        u.nonce = 0xc1d0 << 240;
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 1 ether;
        u.paymentMaxAmount = type(uint128).max;
        u.combinedGas = 10000000;
        u.executionData = abi.encode(calls);
        u.signature = _secp256r1Sig(t.privateKey, t.keyHash, u);

        paymentToken.mint(u.eoa, type(uint128).max);

        vm.etch(u.eoa, abi.encodePacked(hex"ef0100", delegation));
        assertEq(ep.execute(abi.encode(u)), 0);

        assertEq(sampleTarget.x(), t.x);

        assertTrue(LibPREP.isPREP(u.eoa, Delegation(payable(u.eoa)).rPREP()));
    }

    function _secp256r1Sig(uint256 privateKey, bytes32 keyHash, EntryPoint.UserOp memory u)
        internal
        view
        returns (bytes memory)
    {
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, ep.computeDigest(u));
        s = P256.normalized(s);
        return abi.encodePacked(abi.encode(r, s), keyHash, uint8(0));
    }

    function _computePREPDigest(Delegation.Call[] memory calls) internal pure returns (bytes32) {
        bytes32[] memory a = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            a[i] = keccak256(
                abi.encode(
                    keccak256("Call(address target,uint256 value,bytes data)"),
                    bytes32(uint256(uint160(calls[i].target))),
                    bytes32(calls[i].value),
                    keccak256(calls[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(a));
    }

    function _mine(bytes32 digest) internal returns (bytes32 saltAndDelegation, address eoa) {
        address dele = address(delegation);
        bytes32 saltRandomnessSeed = bytes32(_randomUniform());
        bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(dele).p(0).encode()));
        uint96 salt;
        while (true) {
            salt = uint96(uint256(saltRandomnessSeed));
            bytes32 r =
                EfficientHashLib.hash(uint256(digest), salt) & bytes32(uint256(2 ** 160 - 1));
            bytes32 s = EfficientHashLib.hash(r);
            eoa = ecrecover(h, 27, r, s);
            if (eoa != address(0)) break;
            saltRandomnessSeed = EfficientHashLib.hash(saltRandomnessSeed);
        }
        saltAndDelegation = bytes32((uint256(salt) << 160) | uint160(dele));
    }

    function testEIP7702StructHash(address dele) public pure {
        bytes32 expected = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(dele).p(0).encode()));
        bytes32 result;
        assembly ("memory-safe") {
            mstore(0x20, 0x80)
            mstore(0x1f, dele)
            mstore(0x0b, 0x05d78094)
            result := keccak256(0x27, 0x19)
        }
        assertEq(result, expected);
    }
}
