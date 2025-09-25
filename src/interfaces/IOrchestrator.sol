// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "../interfaces/ICommon.sol";

/// @title IOrchestrator
/// @notice Interface for the Orchestrator contract
interface IOrchestrator is ICommon {
    /// @dev Executes a single encoded intent.
    /// @param encodedIntent The encoded intent
    /// @return err The error selector (non-zero if there is an error)
    function execute(bytes calldata encodedIntent) external payable returns (bytes4 err);

    /// @dev Executes an array of encoded intents.
    /// @param encodedIntents Array of encoded intents
    /// @return errs Array of error selectors (non-zero if there are errors)
    function execute(bytes[] calldata encodedIntents)
        external
        payable
        returns (bytes4[] memory errs);

    /// @dev Minimal function, to allow hooking into the _execute function with the simulation flags set to true.
    /// When simulationFlags is set to true, all errors are bubbled up. Also signature verification always returns true.
    /// But the codepaths for signature verification are still hit, for correct gas measurement.
    /// @dev If `isStateOverride` is false, then this function will always revert. If the simulation is successful, then it reverts with `SimulationPassed` error.
    /// If `isStateOverride` is true, then this function will not revert if the simulation is successful.
    /// But the balance of tx.origin has to be greater than or equal to uint192.max, to prove that a state override has been made offchain,
    /// and this is not an onchain call. This mode has been added so that receipt logs can be generated for `eth_simulateV1`
    /// @return gasUsed The amount of gas used by the execution. (Only returned if `isStateOverride` is true)
    function simulateExecute(
        bool isStateOverride,
        uint256 combinedGasOverride,
        bytes calldata encodedIntent
    ) external payable returns (uint256 gasUsed);

    /// @dev Allows the orchestrator owner to withdraw tokens.
    /// @param token The token address (0 for native token)
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function withdrawTokens(address token, address recipient, uint256 amount) external;
}
