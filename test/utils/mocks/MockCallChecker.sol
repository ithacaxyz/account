// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev WARNING! This mock is strictly intended for testing purposes only.
/// Do NOT copy anything here into production code unless you really know what you are doing.

contract MockCallChecker {
    bytes32 public authorizedKeyHash;
    address public authorizedTarget;
    bytes public authorizedData;

    function setAuthorized(bytes32 keyHash, address target, bytes calldata data) public {
        authorizedKeyHash = keyHash;
        authorizedTarget = target;
        authorizedData = data;
    }

    function canExecute(bytes32 keyHash, address target, bytes calldata data)
        public
        view
        returns (bool)
    {
        return (keyHash == authorizedKeyHash && target == authorizedTarget
                && keccak256(data) == keccak256(authorizedData));
    }
}
