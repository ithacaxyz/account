// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {LibPREP} from "../src/libraries/LibPREP.sol";

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
        uint256 x;
        bytes32 saltAndDelegation;
    }

    function testPREP() public {
        _TestTemps memory t;
        UserOp memory u;

        PassKey memory k = _randomSecp256r1PassKey();
        k.k.isSuperAdmin = true;

        ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
        initCalls[0].data = abi.encodeWithSelector(Delegation.authorize.selector, k.k);

        (t.saltAndDelegation, u.eoa) = _minePREP(_computePREPDigest(initCalls));
        u.initData = abi.encode(initCalls, abi.encodePacked(t.saltAndDelegation));

        t.x = _randomUniform();
        ERC7821.Call[] memory calls = new ERC7821.Call[](1);
        calls[0].to = address(sampleTarget);
        calls[0].data = abi.encodeWithSelector(SampleTarget.setX.selector, t.x);

        u.nonce = 0xc1d0 << 240;
        u.paymentToken = address(paymentToken);
        u.paymentAmount = 1 ether;
        u.paymentMaxAmount = type(uint128).max;
        u.combinedGas = 10000000;
        u.executionData = abi.encode(calls);
        u.signature = _sig(k, u);

        paymentToken.mint(u.eoa, type(uint128).max);

        vm.etch(u.eoa, abi.encodePacked(hex"ef0100", delegation));
        assertEq(ep.execute(abi.encode(u)), 0);

        assertEq(sampleTarget.x(), t.x);

        assertTrue(LibPREP.isPREP(u.eoa, Delegation(payable(u.eoa)).rPREP()));
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
