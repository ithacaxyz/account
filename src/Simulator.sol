// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "./interfaces/ICommon.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title Simulator
/// @notice A separate contract for calling the Orchestrator contract solely for gas simulation.
contract Simulator {
    /// @dev This modifier is used to free up memory after a function call.
    modifier freeTempMemory() {
        uint256 m;
        assembly ("memory-safe") {
            m := mload(0x40)
        }
        _;
        // Restore the free memory pointer.
        // We do this so that `abi.encode` doesn't keep expanding memory, when used in a loop
        assembly ("memory-safe") {
            mstore(0x40, m)
        }
    }

    /// @dev Updates the payment amounts for the Intent passed in.
    function _updatePaymentAmounts(
        ICommon.Intent memory u,
        bool isPrePayment,
        uint256 gas,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas
    ) internal pure {
        uint256 paymentAmount = Math.fullMulDiv(gas, paymentPerGas, 10 ** paymentPerGasPrecision);

        if (isPrePayment) {
            u.prePaymentAmount += paymentAmount;
            u.prePaymentMaxAmount += paymentAmount;
        }

        u.totalPaymentAmount += paymentAmount;
        u.totalPaymentMaxAmount += paymentAmount;
    }

    /// @dev Performs a call to the Orchestrator, and returns the gas used by the Intent.
    /// This function expects that the `data` is correctly encoded.
    function _callOrchestrator(address oc, bool isRevert, bytes memory data)
        internal
        returns (uint256 gasUsed, uint256 accountExecuteGas)
    {
        assembly ("memory-safe") {
            // Zeroize return slots.
            mstore(0x00, 0)
            mstore(0x20, 0)

            gasUsed := gasleft()

            let success :=
                call(combinedGasOverride, oc, 0, add(data, 0x20), mload(data), 0x00, 0x40)

            gasUsed := sub(gasUsed, gasleft())

            switch isRevert
            case 0 {
                // If `isRevert` is false, the call reverts, and we check for
                // the `SimulationPassed` selector instead of `success`.
                // The `accountExecuteGas` will be returned by the revert, at 0x04 in the return data.
                if eq(shr(224, mload(0x00)), 0x4f0c028c) { accountExecuteGas := mload(0x04) }
            }
            default {
                // If the call is successful, the `accountExecuteGas` is at 0x00 in the return data.
                if success { accountExecuteGas := mload(0x00) }
            }
        }
    }

    /// @dev Performs a call to the Orchestrator, and returns the gas used by the Intent.
    /// This function is for directly forwarding the Intent in the calldata.
    function _callOrchestratorCalldata(
        address oc,
        bool isRevert,
        uint256 combinedGasOverride,
        bytes calldata encodedIntent
    ) internal freeTempMemory returns (uint256, uint256) {
        bytes memory data =
            abi.encodeWithSignature("simulateExecute(bool,bytes)", isRevert, encodedIntent);

        return _callOrchestrator(oc, combinedGasOverride, isRevert, data);
    }

    /// @dev Performs a call to the Orchestrator, and returns the gas used by the Intent.
    /// This function is for forwarding the re-encoded Intent.
    function _callOrchestratorMemory(
        address oc,
        bool isRevert,
        uint256 combinedGasOverride,
        ICommon.Intent memory u
    ) internal freeTempMemory returns (uint256, uint256) {
        bytes memory data =
            abi.encodeWithSignature("simulateExecute(bool,bytes)", isRevert, abi.encode(u));
        return _callOrchestrator(oc, combinedGasOverride, isRevert, data);
    }

    function simulateAccountExecuteGas(
        address oc,
        uint256 accountExecuteGasIncrement,
        ICommon.Intent memory i
    ) public payable virtual returns (uint256 accountExecuteGas) {
        uint256 accountExecuteGasPreOffset = i.accountExecuteGas;
        i.accountExecuteGas = type(uint256).max;

        // 1. Primary Simulation Run to get initial gasUsed value with combinedGasOverride
        (gasUsed, accountExecuteGas) = _callOrchestratorMemory(oc, false, type(uint256).max, i);

        // If the simulation failed, bubble up the full revert.
        assembly ("memory-safe") {
            if iszero(accountExecuteGas) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        i.accountExecuteGas = accountExecuteGas + accountExecuteGasPreOffset;

        while (true) {
            accountExecuteGas = _callOrchestratorMemory(oc, false, 0, i);

            if (accountExecuteGas != 0) {
                return (i.accountExecuteGas);
            }

            i.accountExecuteGas +=
                Math.mulDiv(i.accountExecuteGas, accountExecuteGasIncrement, 10_000);
        }
    }

    /// @dev Simulates the execution of a intent, and finds the combined gas by iteratively increasing it until the simulation passes.
    /// The start value for combinedGas is gasUsed + original combinedGas.
    /// Set u.combinedGas to add some starting offset to the gasUsed value.
    /// @param oc The orchestrator address
    /// @param isPrePayment Whether to add gas amount to prePayment or postPayment
    /// @param paymentPerGasPrecision The precision of the payment per gas value.
    /// paymentAmount = gas * paymentPerGas / (10 ** paymentPerGasPrecision)
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
    /// This function reverts if the primary simulation run with max combinedGas fails.
    /// If the primary run is successful, it itertively increases u.combinedGas by `combinedGasIncrement` until the simulation passes.
    /// All failing simulations during this run are ignored.
    function simulateCombinedGas(
        address oc,
        bool isPrePayment,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        ICommon.Intent memory i
    ) public payable virtual returns (uint256 gasUsed, uint256 combinedGas) {
        i.executeGas = type(uint256).max;

        uint256 accountExecuteGas;

        // 1. Primary Simulation Run to get initial gasUsed value with combinedGasOverride
        (gasUsed, accountExecuteGas) = _callOrchestratorMemory(oc, false, type(uint256).max, i);

        // If the simulation failed, bubble up the full revert.
        assembly ("memory-safe") {
            if iszero(accountExecuteGas) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        // Update payment amounts using the gasUsed value
        ICommon.Intent memory i = abi.decode(encodedIntent, (ICommon.Intent));

        i.combinedGas += gasUsed;

        _updatePaymentAmounts(i, isPrePayment, i.combinedGas, paymentPerGasPrecision, paymentPerGas);

        while (true) {
            (gasUsed, accountExecuteGas) = _callOrchestratorMemory(oc, false, 0, i);

            // If the simulation failed, bubble up the full revert.
            assembly ("memory-safe") {
                if iszero(accountExecuteGas) {
                    let m := mload(0x40)
                    returndatacopy(m, 0x00, returndatasize())
                    // `PaymentError` is given special treatment here, as it comes from
                    // the account not having enough funds, and cannot be recovered from,
                    // since the paymentAmount will keep increasing in this loop.
                    if eq(shr(224, mload(m)), 0xabab8fc9) { revert(m, 0x20) }
                }
            }

            if (accountExecuteGas != 0) {
                return (gasUsed, i.combinedGas);
            }

            uint256 gasIncrement = Math.mulDiv(i.combinedGas, combinedGasIncrement, 10_000);

            _updatePaymentAmounts(
                i, isPrePayment, gasIncrement, paymentPerGasPrecision, paymentPerGas
            );

            // Step up the combined gas, until we see a simulation passing
            i.combinedGas += gasIncrement;
        }
    }

    /// @dev Same as simulateCombinedGas, but with an additional verification run
    /// that generates a successful non reverting state override simulation.
    /// Which can be used in eth_simulateV1 to get the trace.\
    /// @param accountExecuteGasOffset is a static value that is added after a succesful combinedGas is found.
    /// @param combinedGasOffset is a static value that is added after a succesful accountExecuteGas is found.
    /// This can be used to account for variations in sig verification gas, for keytypes like P256.
    /// @param paymentPerGasPrecision The precision of the payment per gas value.
    /// paymentAmount = gas * paymentPerGas / (10 ** paymentPerGasPrecision)
    function simulateV1Logs(
        address oc,
        bool isPrePayment,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        uint256 combinedGasOffset,
        uint256 accountExecuteGasIncrement,
        uint256 accountExecuteGasOffset,
        bytes calldata encodedIntent
    ) public payable virtual returns (uint256, /*accountExecuteGas*/ uint256 /*combinedGas*/ ) {
        ICommon.Intent memory i = abi.decode(encodedIntent, (ICommon.Intent));

        i.accountExecuteGas =
            simulateAccountExecuteGas(oc, accountExecuteGasIncrement, encodedIntent);
        i.accountExecuteGas += accountExecuteGasOffset;

        i.combinedGas = simulateCombinedGas(
            oc,
            isPrePayment,
            paymentPerGasPrecision,
            paymentPerGas,
            combinedGasIncrement,
            encodedIntent
        );

        i.combinedGas += combinedGasOffset;

        _updatePaymentAmounts(i, isPrePayment, i.combinedGas, paymentPerGasPrecision, paymentPerGas);

        // Verification Run to generate the logs with the correct combinedGas and payment amounts.
        (, accountExecuteGas) = _callOrchestratorMemory(oc, true, 0, i);

        // If the simulation failed, bubble up full revert
        assembly ("memory-safe") {
            if iszero(accountExecuteGas) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        return (i.accountExecuteGas, i.combinedGas);
    }
}
