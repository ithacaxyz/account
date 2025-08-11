// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

error EmptyStack();

/// @notice A minimal bytes32 stack implementation in transient storage.
library LibTStack {
    /// @dev Helper struct to store the base slot of the stack.
    struct TStack {
        uint256 slot;
    }

    function tStack(uint256 tSlot) internal pure returns (TStack memory t) {
        t.slot = tSlot;
    }

    /// @dev Returns the top-most value of the stack.
    /// Throws an `EmptyStack()` error if the stack is empty.
    function top(TStack memory t) internal view returns (bytes32 val) {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)
            if iszero(len) {
                mstore(0x00, 0xbc7ec779) // `EmptyStack()`
                revert(0x1c, 0x04)
            }

            val := tload(add(tSlot, len))
        }
    }

    /// @dev Returns the size of the stack.
    function size(TStack memory t) internal view returns (uint256 len) {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            len := tload(tSlot)
        }
    }

    /// @dev Pushes a bytes32 value to the top of the stack.
    function push(TStack memory t, bytes32 val) internal {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := add(tload(tSlot), 1)
            tstore(add(tSlot, len), val)
            tstore(tSlot, len)
        }
    }

    /// @dev Pops the top-most value from the stack.
    /// Throws an `EmptyStack()` error if the stack is empty.
    /// @dev Does NOT clean the value on top of the stack automatically.
    function pop(TStack memory t) internal {
        uint256 tSlot = t.slot;

        assembly ("memory-safe") {
            let len := tload(tSlot)
            if iszero(len) {
                mstore(0x00, 0xbc7ec779) // `EmptyStack()`
                revert(0x1c, 0x04)
            }

            tstore(tSlot, sub(len, 1))
        }
    }
}
