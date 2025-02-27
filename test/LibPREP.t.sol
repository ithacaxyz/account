// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {Delegation} from "../src/Delegation.sol";
import {LibPREP} from "../src/LibPREP.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
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
    using LibRLP for LibRLP.List;

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
        delegation = address(new Delegation());
        paymentToken = new MockPaymentToken();
    }

    struct _TestTemps {
        bytes32 digest;
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint256 x;
    }

    function testPREP() public {
        _TestTemps memory t;
        EntryPoint.UserOp memory u;

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

        t.digest = ep.computePREPDigest(u);
        (t.r, t.s, t.v, u.eoa) = _mine(t.digest);
        u.signature = abi.encodePacked(t.r, t.s, t.v, delegation);
        assertNotEq(this.getCompactPREPSignature(u.signature, t.digest, u.eoa), 0);

        paymentToken.mint(u.eoa, type(uint128).max);

        vm.etch(u.eoa, abi.encodePacked(hex"ef0100", delegation));
        assertEq(ep.execute(abi.encode(u)), 0);

        assertEq(sampleTarget.x(), t.x);

        assertTrue(Delegation(payable(u.eoa)).isPREP());
    }

    function getCompactPREPSignature(bytes calldata signature, bytes32 digest, address eoa)
        public
        view
        returns (bytes32)
    {
        if (!LibPREP.signatureMaybeForPREP(signature)) return 0;
        return LibPREP.getCompactPREPSignature(signature, digest, eoa);
    }

    function _mine(bytes32 digest) internal returns (bytes32 r, bytes32 s, uint8 v, address eoa) {
        bytes32 h = keccak256(abi.encodePacked(hex"05", LibRLP.p(0).p(delegation).p(0).encode()));

        for (uint256 i;; ++i) {
            r = bytes32(uint256(uint160(uint256(EfficientHashLib.hash(digest, bytes32(i))))));
            uint256 q = _randomUniform();
            s = bytes32(uint256(uint96(q)));
            v = 27;
            eoa = ecrecover(h, v, r, s);
            if (eoa != address(0)) break;
            v = 28;
            eoa = ecrecover(h, v, r, s);
            if (eoa != address(0)) break;
        }
        assert(uint256(r) <= 2 ** 160 - 1);
        assert(uint256(s) <= 2 ** 96 - 1);
    }
}
