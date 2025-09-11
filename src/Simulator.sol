// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "./interfaces/ICommon.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {console} from "forge-std/console.sol";

/// @title Simulator
/// @notice A separate contract for calling the Orchestrator contract solely for gas simulation.
contract Simulator {
    ////////////////////////////////////////////////////////////////////////
    // EIP-5267 Support
    ////////////////////////////////////////////////////////////////////////

    /// @dev See: https://eips.ethereum.org/EIPS/eip-5267
    /// Returns the fields and values that describe the domain separator used for signing.
    /// Note: This is just for labelling and offchain verification purposes.
    /// This contract does not use EIP712 signatures anywhere else.
    function eip712Domain()
        public
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        fields = hex"0f"; // `0b01111` - has name, version, chainId, verifyingContract
        name = "Simulator";
        version = "0.0.2";
        chainId = block.chainid;
        verifyingContract = address(this);
        salt = bytes32(0);
        extensions = new uint256[](0);
    }
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
        bytes memory u,
        uint256 gas,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas
    ) internal pure {
        uint256 paymentAmount = Math.fullMulDiv(gas, paymentPerGas, 10 ** paymentPerGasPrecision);

        assembly ("memory-safe") {
            // Update paymentAmount at offset 312
            let currentPaymentAmount := mload(add(u, 344)) // 312 + 32 for memory offset
            mstore(add(u, 344), add(currentPaymentAmount, paymentAmount))

            // Update paymentMaxAmount at offset 216
            let currentPaymentMaxAmount := mload(add(u, 248)) // 216 + 32 for memory offset
            mstore(add(u, 248), add(currentPaymentMaxAmount, paymentAmount))
        }
    }

    /// @dev Performs a call to the Orchestrator, and returns the gas used by the Intent.
    /// This function expects that the `data` is correctly encoded.
    function _callOrchestrator(address oc, bool isStateOverride, bytes memory data)
        internal
        returns (uint256 gasUsed)
    {
        assembly ("memory-safe") {
            // Zeroize return slots.
            mstore(0x00, 0)
            mstore(0x20, 0)

            let success := call(gas(), oc, 0, add(data, 0x20), mload(data), 0x00, 0x40)

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

    /// @dev Performs a call to the Orchestrator, and returns the gas used by the Intent.
    /// This function is for directly forwarding the Intent in the calldata.
    function _callOrchestratorCalldata(
        address oc,
        bool isStateOverride,
        uint256 combinedGasOverride,
        bytes calldata encodedIntent
    ) internal freeTempMemory returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "simulateExecute(bool,uint256,bytes)",
            isStateOverride,
            combinedGasOverride,
            encodedIntent
        );
        return _callOrchestrator(oc, isStateOverride, data);
    }

    /// @dev Performs a call to the Orchestrator, and returns the gas used by the Intent.
    /// This function is for forwarding the re-encoded Intent.
    function _callOrchestratorMemory(
        address oc,
        bool isStateOverride,
        uint256 combinedGasOverride,
        bytes memory u
    ) internal freeTempMemory returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "simulateExecute(bool,uint256,bytes)", isStateOverride, combinedGasOverride, u
        );
        return _callOrchestrator(oc, isStateOverride, data);
    }

    /// @dev Simulate the gas usage for a user operation. This function reverts if the simulation fails.
    /// @param oc The orchestrator address
    /// @param overrideCombinedGas Whether to override the combined gas for the intent to type(uint256).max
    /// @param encodedIntent The encoded user operation
    /// @return gasUsed The amount of gas used by the simulation
    function simulateGasUsed(address oc, bool overrideCombinedGas, bytes calldata encodedIntent)
        public
        payable
        virtual
        returns (uint256 gasUsed)
    {
        gasUsed = _callOrchestratorCalldata(
            oc, false, Math.ternary(overrideCombinedGas, type(uint256).max, 0), encodedIntent
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

    /// @dev Simulates the execution of a intent, and finds the combined gas by iteratively increasing it until the simulation passes.
    /// The start value for combinedGas is gasUsed + original combinedGas.
    /// Set u.combinedGas to add some starting offset to the gasUsed value.
    /// @param oc The orchestrator address
    /// @param paymentPerGasPrecision The precision of the payment per gas value.
    /// paymentAmount = gas * paymentPerGas / (10 ** paymentPerGasPrecision)
    /// @param paymentPerGas The amount of `paymentToken` to be added per gas unit.
    /// Total payment is calculated as paymentAmount += gasUsed * paymentPerGas.
    /// @dev Set paymentAmount to include any static offset to the gas value.
    /// @param combinedGasIncrement Basis Points increment to be added for each iteration of searching for combined gas.
    /// @dev The closer this number is to 10_000, the more precise combined gas will be. But more iterations will be needed.
    /// @dev This number should always be > 10_000, to get correct results.
    //// If the increment is too small, the function might run out of gas while finding the combined gas value.
    /// @param calldataIntent The encoded intent
    /// @return gasUsed The gas used in the successful simulation
    /// @return combinedGas The first combined gas value that gives a successful simulation.
    /// This function reverts if the primary simulation run with max combinedGas fails.
    /// If the primary run is successful, it itertively increases u.combinedGas by `combinedGasIncrement` until the simulation passes.
    /// All failing simulations during this run are ignored.
    function simulateCombinedGas(
        address oc,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        bytes calldata calldataIntent
    ) public payable virtual returns (uint256 gasUsed, uint256 combinedGas) {
        // 1. Primary Simulation Run to get initial gasUsed value with combinedGasOverride
        gasUsed = _callOrchestratorCalldata(oc, false, type(uint256).max, calldataIntent);

        // If the simulation failed, bubble up the full revert.
        assembly ("memory-safe") {
            if iszero(gasUsed) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        bytes memory memoryIntent = calldataIntent;

        // Update combinedGas using assembly - offset 248 + 32 for memory = 280
        assembly ("memory-safe") {
            let currentCombinedGas := mload(add(memoryIntent, 280))
            let newCombinedGas := add(currentCombinedGas, gasUsed)
            mstore(add(memoryIntent, 280), newCombinedGas)
            combinedGas := newCombinedGas
        }

        _updatePaymentAmounts(memoryIntent, combinedGas, paymentPerGasPrecision, paymentPerGas);

        console.log("in sim");
        while (true) {
            gasUsed = _callOrchestratorMemory(oc, false, 0, memoryIntent);

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
                // Get current combinedGas from bytes
                assembly ("memory-safe") {
                    combinedGas := mload(add(memoryIntent, 280))
                }
                return (gasUsed, combinedGas);
            }

            // Get current combinedGas and calculate increment
            assembly ("memory-safe") {
                combinedGas := mload(add(memoryIntent, 280))
            }
            uint256 gasIncrement = Math.mulDiv(combinedGas, combinedGasIncrement, 10_000);

            _updatePaymentAmounts(memoryIntent, gasIncrement, paymentPerGasPrecision, paymentPerGas);

            // Update combinedGas with increment using assembly
            assembly ("memory-safe") {
                let currentCombinedGas := mload(add(memoryIntent, 280))
                let newCombinedGas := add(currentCombinedGas, gasIncrement)
                mstore(add(memoryIntent, 280), newCombinedGas)
            }
        }
        console.log("finished sim");
    }

    /// @dev Same as simulateCombinedGas, but with an additional verification run
    /// that generates a successful non reverting state override simulation.
    /// Which can be used in eth_simulateV1 to get the trace.\
    /// @param combinedGasVerificationOffset is a static value that is added after a succesful combinedGas is found.
    /// This can be used to account for variations in sig verification gas, for keytypes like P256.
    /// @param paymentPerGasPrecision The precision of the payment per gas value.
    /// paymentAmount = gas * paymentPerGas / (10 ** paymentPerGasPrecision)
    function simulateV1Logs(
        address oc,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        uint256 combinedGasVerificationOffset,
        bytes calldata encodedIntent
    ) public payable virtual returns (uint256 gasUsed, uint256 combinedGas) {
        (gasUsed, combinedGas) = simulateCombinedGas(
            oc, paymentPerGasPrecision, paymentPerGas, combinedGasIncrement, encodedIntent
        );

        combinedGas += combinedGasVerificationOffset;

        bytes memory encodedIntentCopy = encodedIntent;

        _updatePaymentAmounts(encodedIntentCopy, combinedGas, paymentPerGasPrecision, paymentPerGas);

        // Update combinedGas in the bytes using assembly
        assembly ("memory-safe") {
            mstore(add(encodedIntentCopy, 280), combinedGas)
        }

        // Verification Run to generate the logs with the correct combinedGas and payment amounts.
        gasUsed = _callOrchestratorMemory(oc, true, 0, encodedIntentCopy);

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
