// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibTStack} from "../src/libraries/LibTStack.sol";
import {BaseTest} from "./Base.t.sol";

contract LibTStackTest is BaseTest {
    using LibTStack for LibTStack.TStack;

    function _fillStack(LibTStack.TStack memory t) public {
        uint256 len = _bound(_random(), 0, 256);

        for (uint256 i; i < len; ++i) {
            bytes32 val = bytes32(_random());
            t.push(val);

            assertEq(t.top(), val);
            assertEq(t.size(), i + 1);
        }

        assertEq(t.size(), len);
    }

    function test_push(bytes32) public {
        LibTStack.TStack memory t = LibTStack.tStack(_random());

        _fillStack(t);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_top(bytes32) public {
        LibTStack.TStack memory t = LibTStack.tStack(_random());

        bytes32 top = bytes32(_random());
        t.push(top);

        assertEq(t.top(), top);

        bytes32 topCache = top;
        top = bytes32(_random());
        t.push(top);

        assertEq(t.top(), top);

        t.pop();

        assertEq(t.top(), topCache);

        t.pop();

        assertEq(t.size(), 0);
        vm.expectRevert(bytes4(keccak256("EmptyStack()")));
        LibTStack.top(t);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_pop(bytes32) public {
        LibTStack.TStack memory t = LibTStack.tStack(_random());

        _fillStack(t);

        if (t.size() == 0) {
            vm.expectRevert(bytes4(keccak256("EmptyStack()")));
            t.pop();
        } else {
            uint256 len = t.size();
            for (uint256 i; i < len; ++i) {
                t.pop();
                assertEq(t.size(), len - i - 1);
            }

            assertEq(t.size(), 0);
            vm.expectRevert(bytes4(keccak256("EmptyStack()")));
            t.pop();
        }
    }
}
