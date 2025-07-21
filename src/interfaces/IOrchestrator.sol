// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/// @title IOrchestrator
/// @notice Interface for the Orchestrator contract
interface IOrchestrator is ICommon {
    /// @dev Executes a single encoded intent.
    /// @param encodedIntent The encoded intent
    function execute(bytes calldata encodedIntent) external payable;

    /// @dev Minimal function, to allow hooking into the _execute function with the simulation flags set to true.
    /// When simulationFlags is set to true, all errors are bubbled up. Also signature verification always returns true.
    /// But the codepaths for signature verification are still hit, for correct gas measurement.
    /// @dev If `isStateOverride` is false, then this function will always revert. If the simulation is successful, then it reverts with `SimulationPassed` error.
    /// If `isStateOverride` is true, then this function will not revert if the simulation is successful.
    /// But the balance of msg.sender has to be equal to type(uint256).max, to prove that a state override has been made offchain,
    /// and this is not an onchain call. This mode has been added so that receipt logs can be generated for `eth_simulateV1`
    /// @return gasUsed The amount of gas used by the execution. (Only returned if `isStateOverride` is true)
    function simulateExecute(bool isStateOverride, bytes calldata encodedIntent)
        external
        payable
        returns (uint256 gasUsed);

    /// @dev Allows the orchestrator owner to withdraw tokens.
    /// @param token The token address (0 for native token)
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function withdrawTokens(address token, address recipient, uint256 amount) external;
}
