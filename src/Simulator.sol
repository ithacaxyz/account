// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "./interfaces/ICommon.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title Simulator
/// @notice A separate contract for calling the EntryPoint contract solely for gas simulation.
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

    /// @dev Updates the payment amounts for the UserOp passed in.
    function _updatePaymentAmounts(
        ICommon.UserOp memory u,
        bool isPrePayment,
        uint256 gas,
        uint256 paymentPerGas
    ) internal pure {
        uint256 paymentAmount = gas * paymentPerGas;

        if (isPrePayment) {
            u.prePaymentAmount += paymentAmount;
            u.prePaymentMaxAmount += paymentAmount;
        }

        u.totalPaymentAmount += paymentAmount;
        u.totalPaymentMaxAmount += paymentAmount;
    }

    /// @dev Performs a call to the EntryPoint, and returns the gas used by the UserOp.
    /// This function expects that the `data` is correctly encoded.
    function _callEntryPoint(address ep, bool isStateOverride, bytes memory data)
        internal
        returns (uint256 gasUsed)
    {
        assembly ("memory-safe") {
            // Zeroize return slots.
            mstore(0x00, 0)
            mstore(0x20, 0)

            let success := call(gas(), ep, 0, add(data, 0x20), mload(data), 0x00, 0x40)

            switch isStateOverride
            case 0 {
                // If `isStateOverride` is false, the call reverts, and we check for
                // the `SimulationPassed` selector instead of `success`.
                // The `gasUsed` will be returned by the revert, at 0x04 in the return data.
                if eq(shr(224, mload(0x00)), 0x4f0c028c) { gasUsed := mload(0x04) }
            }
            default {
                // If the call is successful, the `gasUsed` is at 0x00 in the return data.
                if success { gasUsed := mload(0x00) }
            }
        }
    }

    /// @dev Performs a call to the EntryPoint, and returns the gas used by the UserOp.
    /// This function is for directly forwarding the UserOp in the calldata.
    function _callEntryPointCalldata(
        address ep,
        bool isStateOverride,
        uint256 combinedGasOverride,
        bytes calldata encodedUserOp
    ) internal freeTempMemory returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "simulateExecute(bool,uint256,bytes)",
            isStateOverride,
            combinedGasOverride,
            encodedUserOp
        );
        return _callEntryPoint(ep, isStateOverride, data);
    }

    /// @dev Performs a call to the EntryPoint, and returns the gas used by the UserOp.
    /// This function is for forwarding the re-encoded UserOp.
    function _callEntryPointMemory(
        address ep,
        bool isStateOverride,
        uint256 combinedGasOverride,
        ICommon.UserOp memory u
    ) internal freeTempMemory returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "simulateExecute(bool,uint256,bytes)",
            isStateOverride,
            combinedGasOverride,
            abi.encode(u)
        );
        return _callEntryPoint(ep, isStateOverride, data);
    }

    /// @dev Simulate the gas usage for a user operation. This function reverts if the simulation fails.
    /// @param ep The entry point address
    /// @param overrideCombinedGas Whether to override the combined gas for the userOp to type(uint256).max
    /// @param encodedUserOp The encoded user operation
    /// @return gasUsed The amount of gas used by the simulation
    function simulateGasUsed(address ep, bool overrideCombinedGas, bytes calldata encodedUserOp)
        public
        payable
        virtual
        returns (uint256 gasUsed)
    {
        gasUsed = _callEntryPointCalldata(
            ep, false, Math.ternary(overrideCombinedGas, type(uint256).max, 0), encodedUserOp
        );

        // If the simulation failed, bubble up full revert.
        assembly ("memory-safe") {
            if iszero(gasUsed) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @dev Simulates the execution of a userOp, and finds the combined gas by iteratively increasing it until the simulation passes.
    /// The start value for combinedGas is gasUsed + original combinedGas.
    /// Set u.combinedGas to add some starting offset to the gasUsed value.
    /// @param ep The entry point address
    /// @param isPrePayment Whether to add gas amount to prePayment or postPayment
    /// @param paymentPerGas The amount of `paymentToken` to be added per gas unit.
    /// Total payment is calculated as pre/postPaymentAmount += gasUsed * paymentPerGas.
    /// @dev Set prePayment or totalPaymentAmount to include any static offset to the gas value.
    /// @param combinedGasIncrement Basis Points increment to be added for each iteration of searching for combined gas.
    /// @dev The closer this number is to 10_000, the more precise combined gas will be. But more iterations will be needed.
    /// @dev This number should always be > 10_000, to get correct results.
    //// If the increment is too small, the function might run out of gas while finding the combined gas value.
    /// @param encodedUserOp The encoded user operation
    /// @return gasUsed The gas used in the successful simulation
    /// @return combinedGas The first combined gas value that gives a successful simulation.
    /// This function reverts if the primary simulation run with max combinedGas fails.
    /// If the primary run is successful, it itertively increases u.combinedGas by `combinedGasIncrement` until the simulation passes.
    /// All failing simulations during this run are ignored.
    function simulateCombinedGas(
        address ep,
        bool isPrePayment,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        bytes calldata encodedUserOp
    ) public payable virtual returns (uint256 gasUsed, uint256 combinedGas) {
        // 1. Primary Simulation Run to get initial gasUsed value with combinedGasOverride
        gasUsed = _callEntryPointCalldata(ep, false, type(uint256).max, encodedUserOp);

        // If the simulation failed, bubble up the full revert.
        assembly ("memory-safe") {
            if iszero(gasUsed) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        // Update payment amounts using the gasUsed value
        ICommon.UserOp memory u = abi.decode(encodedUserOp, (ICommon.UserOp));

        u.combinedGas += gasUsed;

        _updatePaymentAmounts(u, isPrePayment, u.combinedGas, paymentPerGas);

        while (true) {
            gasUsed = _callEntryPointMemory(ep, false, 0, u);

            // If the simulation failed, bubble up the full revert.
            assembly ("memory-safe") {
                if iszero(gasUsed) {
                    let m := mload(0x40)
                    returndatacopy(m, 0x00, returndatasize())
                    // `PaymentError` is given special treatment here, as it comes from
                    // the account not having enough funds, and cannot be recovered from,
                    // since the paymentAmount will keep increasing in this loop.
                    if eq(shr(224, mload(m)), 0xabab8fc9) { revert(m, 0x20) }
                }
            }

            if (gasUsed != 0) {
                return (gasUsed, u.combinedGas);
            }

            uint256 gasIncrement = Math.mulDiv(u.combinedGas, combinedGasIncrement, 10_000);

            _updatePaymentAmounts(u, isPrePayment, gasIncrement, paymentPerGas);

            // Step up the combined gas, until we see a simulation passing
            u.combinedGas += gasIncrement;
        }
    }

    /// @dev Same as simulateCombinedGas, but with an additional verification run
    /// that generates a successful non reverting state override simulation.
    /// Which can be used in eth_simulateV1 to get the trace.\
    /// @dev combinedGasVerificationOffset is a static value that is added after a succesful combinedGas is found.
    /// This can be used to account for variations in sig verification gas, for keytypes like P256.
    function simulateV1Logs(
        address ep,
        bool isPrePayment,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        uint256 combinedGasVerificationOffset,
        bytes calldata encodedUserOp
    ) public payable virtual returns (uint256 gasUsed, uint256 combinedGas) {
        (gasUsed, combinedGas) = simulateCombinedGas(
            ep, isPrePayment, paymentPerGas, combinedGasIncrement, encodedUserOp
        );

        combinedGas += combinedGasVerificationOffset;

        ICommon.UserOp memory u = abi.decode(encodedUserOp, (ICommon.UserOp));

        _updatePaymentAmounts(u, isPrePayment, combinedGas, paymentPerGas);

        u.combinedGas = combinedGas;

        // Verification Run to generate the logs with the correct combinedGas and payment amounts.
        gasUsed = _callEntryPointMemory(ep, true, 0, u);

        // If the simulation failed, bubble up full revert
        assembly ("memory-safe") {
            if iszero(gasUsed) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }
}
