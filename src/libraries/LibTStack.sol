// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

library LibTStack {
    struct TStack {
        uint256 slot;
    }

    function tStack(uint256 tSlot) internal pure returns (TStack memory t) {
        t.slot = tSlot;
    }

    function top(TStack memory t) internal view returns (bytes32) {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)
            if iszero(len) {
                mstore(0x00, 0x00)
                return(0x00, 0x20)
            }

            mstore(0x00, tload(add(tSlot, len)))

            return(0x00, 0x20)
        }
    }

    function get(TStack memory t, uint256 index) internal view returns (bytes32) {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)

            if lt(index, len) {
                mstore(0x00, tload(add(tSlot, add(index, 1))))
                return(0x00, 0x20)
            }

            mstore(0x00, 0xb4120f14) // `OutOfBounds()`
            revert(0x1c, 0x04)
        }
    }

    function set(TStack memory t, uint256 index, bytes32 val) internal {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)

            if lt(index, len) {
                tstore(add(tSlot, add(index, 1)), val)
                return(0x00, 0x00)
            }

            mstore(0x00, 0xb4120f14) // `OutOfBounds()`
            revert(0x1c, 0x04)
        }
    }

    function size(TStack memory t) internal view returns (uint256) {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            mstore(0x00, tload(tSlot))
            return(0x00, 0x20)
        }
    }

    function push(TStack memory t, bytes32 val) internal {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)
            tstore(add(tSlot, len), val)
            tstore(tSlot, add(len, 1))
        }
    }

    function pop(TStack memory t) internal {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)
            tstore(tSlot, sub(len, 1))
        }
    }
}
