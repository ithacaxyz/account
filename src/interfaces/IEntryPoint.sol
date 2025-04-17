// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/// @title IEntryPoint
/// @notice Interface for the EntryPoint contract
interface IEntryPoint is ICommon {
    /// @dev Executes a single encoded user operation.
    /// @param encodedUserOp The encoded user operation
    /// @return err The error selector (non-zero if there is an error)
    function execute(bytes calldata encodedUserOp) external payable returns (bytes4 err);

    /// @dev Executes an array of encoded user operations.
    /// @param encodedUserOps Array of encoded user operations
    /// @return errs Array of error selectors (non-zero if there are errors)
    function execute(bytes[] calldata encodedUserOps)
        external
        payable
        returns (bytes4[] memory errs);

    // /// @dev Simulates an execution and returns gas estimates
    // /// @param encodedUserOp The encoded user operation
    // /// @return gExecute The recommended amount of gas for execute
    // /// @return gCombined The recommended combined gas
    // /// @return gUsed The amount of gas used
    // function simulateExecute(bytes calldata encodedUserOp)
    //     external
    //     payable
    //     returns (uint256 gExecute, uint256 gCombined, uint256 gUsed);

    /// @dev Return current nonce with sequence key.
    /// @param eoa The EOA address
    /// @param seqKey The sequence key
    /// @return The current nonce
    function getNonce(address eoa, uint192 seqKey) external view returns (uint256);

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to (inclusive) `uint64(nonce)`.
    /// @param nonce The nonce to invalidate
    function invalidateNonce(uint256 nonce) external;

    /// @dev ERC7683 fill.
    /// @param orderId The order ID
    /// @param originData The origin data
    /// @param destData The destination data (unused)
    /// @return The result of the execution
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata destData)
        external
        payable
        returns (bytes4);

    /// @dev Returns true if the order ID has been filled.
    /// @param orderId The order ID
    /// @return Whether the order ID has been filled
    function orderIdIsFilled(bytes32 orderId) external view returns (bool);

    /// @dev Allows the entry point owner to withdraw tokens.
    /// @param token The token address (0 for native token)
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function withdrawTokens(address token, address recipient, uint256 amount) external;
}
