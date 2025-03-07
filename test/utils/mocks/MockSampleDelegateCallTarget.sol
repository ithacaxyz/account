// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.
contract MockSampleDelegateCallTarget {
    uint256 public immutable version;

    error ErrorWithData(bytes data);

    constructor(uint256 version_) {
        version = version_;
    }

    function setStorage(bytes32 sslot, bytes32 value) public {
        assembly ("memory-safe") {
            sstore(sslot, value)
        }
    }

    function revertWithData(bytes memory data) public pure {
        revert ErrorWithData(data);
    }
}
