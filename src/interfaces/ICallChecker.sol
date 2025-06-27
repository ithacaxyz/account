// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title ICallChecker
/// @notice An interface for a third party call checker, for implementing custom execution guards.
interface ICallChecker {
    /// @dev Returns if the `keyHash` can call `target` with `data`.
    function canExecute(bytes32 keyHash, address target, bytes calldata data)
        external
        view
        returns (bool);
}
