// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import {EntryPoint} from "../src/EntryPoint.sol";

contract EntryPointTest is SoladyTest {
    EntryPoint public ep;

    function setUp() public {
        ep = new EntryPoint();
    }

    struct _TestTemps {
        EntryPoint.UserOp[] userOps;
    }

    function testEntryPointDecode() public {
        _TestTemps memory t;
        t.userOps = new EntryPoint.UserOp[](2);
        t.userOps[0].callGas = 123;
        t.userOps[1].callGas = 456;
        t.userOps[0].signature = "hehe";
        ep.executeUserOps(_encodeUserOps(t.userOps));
    }

    function _encodeUserOps(EntryPoint.UserOp[] memory userOps) internal pure returns (bytes[] memory results) {
        results = new bytes[](userOps.length);
        for (uint i; i < userOps.length; ++i) {
            results[i] = abi.encode(userOps[i]);
        }
    }
}
