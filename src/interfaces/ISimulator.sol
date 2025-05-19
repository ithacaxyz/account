// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title ISimulator
/// @notice Interface for the Simulator contract
interface ISimulator {
    /// @dev Simulate the gas usage for a user operation.
    /// @param ep The Orchestrator address
    /// @param overrideCombinedGas Whether to override the combined gas for the intent to type(uint256).max
    /// @param encodedIntent The encoded user operation
    /// @return gasUsed The amount of gas used by the simulation
    function simulateGasUsed(address ep, bool overrideCombinedGas, bytes calldata encodedIntent)
        external
        payable
        returns (uint256 gasUsed);

    /// @dev Simulates the execution of a intent, and finds the combined gas by iteratively increasing it until the simulation passes.
    /// The start value for combinedGas is gasUsed + original combinedGas.
    /// Set u.combinedGas to add some starting offset to the gasUsed value.
    /// @param ep The Orchestrator address
    /// @param isPrePayment Whether to add gas amount to prePayment or postPayment
    /// @param paymentPerGas The amount of `paymentToken` to be added per gas unit.
    /// Total payment is calculated as pre/postPaymentAmount += gasUsed * paymentPerGas.
    /// @dev Set prePayment or totalPaymentAmount to include any static offset to the gas value.
    /// @param combinedGasIncrement Basis Points increment to be added for each iteration of searching for combined gas.
    /// @dev The closer this number is to 10_000, the more precise combined gas will be. But more iterations will be needed.
    /// @dev This number should always be > 10_000, to get correct results.
    //// If the increment is too small, the function might run out of gas while finding the combined gas value.
    /// @param encodedIntent The encoded user operation
    /// @return gasUsed The gas used in the successful simulation
    /// @return combinedGas The first combined gas value that gives a successful simulation.
    function simulateCombinedGas(
        address ep,
        bool isPrePayment,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        bytes calldata encodedIntent
    ) external payable returns (uint256 gasUsed, uint256 combinedGas);
}
