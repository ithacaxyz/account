// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/// @title IOrchestrator
/// @notice Interface for the Orchestrator contract
interface IOrchestrator is ICommon {
    /// @dev Executes a single encoded intent.
    /// @param encodedIntent The encoded intent
    function execute(bytes calldata encodedIntent) external payable returns (uint256 gUsed);

    /// @dev Allows the orchestrator owner to withdraw tokens.
    /// @param token The token address (0 for native token)
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function withdrawTokens(address token, address recipient, uint256 amount) external;
}
