// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ICommon} from "./interfaces/ICommon.sol";
import {IMulticall3} from "./interfaces/IMulticall3.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

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
        ICommon.Intent memory u,
        uint256 gas,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas
    ) internal pure {
        uint256 paymentAmount = Math.fullMulDiv(gas, paymentPerGas, 10 ** paymentPerGasPrecision);

        u.paymentAmount += paymentAmount;
        u.paymentMaxAmount += paymentAmount;
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
        ICommon.Intent memory u
    ) internal freeTempMemory returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "simulateExecute(bool,uint256,bytes)",
            isStateOverride,
            combinedGasOverride,
            abi.encode(u)
        );
        return _callOrchestrator(oc, isStateOverride, data);
    }

    /// @dev Performs a call to Multicall3 with calls followed by an orchestrator call.
    /// Returns the gas used parsed from the last Result in the multicall3 response.
    /// If parsing fails (gasUsed == 0), this function stores the orchestrator's error in memory
    /// so the caller can bubble it up using bubbleUpMulticall3Error.
    /// @param multicall3 The multicall3 contract address
    /// @param calls Array of Call3 structs to execute before the orchestrator call
    /// @param oc The orchestrator address
    /// @param isStateOverride Whether to use state override mode for the orchestrator call
    /// @param combinedGasOverride The combined gas override value
    /// @param u The Intent struct to pass to the orchestrator
    /// @return gasUsed The gas used by the orchestrator call (parsed from SimulationPassed or state override result)
    /// @return multicall3Gas The gas spent on the aggregate3 call itself
    /// @return lastReturnData The return data from the orchestrator call
    function _callMulticall3(
        address multicall3,
        IMulticall3.Call3[] memory calls,
        address oc,
        bool isStateOverride,
        uint256 combinedGasOverride,
        ICommon.Intent memory u
    )
        internal
        freeTempMemory
        returns (uint256 gasUsed, uint256 multicall3Gas, bytes memory lastReturnData)
    {
        // Build the orchestrator call data
        bytes memory orchestratorData = abi.encodeWithSignature(
            "simulateExecute(bool,uint256,bytes)",
            isStateOverride,
            combinedGasOverride,
            abi.encode(u)
        );

        // Construct the full Call3[] array: calls + orchestrator call
        IMulticall3.Call3[] memory allCalls = new IMulticall3.Call3[](calls.length + 1);
        for (uint256 i = 0; i < calls.length; i++) {
            allCalls[i] = calls[i];
        }
        // Last call is to the orchestrator
        allCalls[calls.length] =
            IMulticall3.Call3({target: oc, allowFailure: true, callData: orchestratorData});

        // Measure gas before and after aggregate3 call
        uint256 gasBefore = gasleft();
        IMulticall3.Result[] memory results = IMulticall3(multicall3).aggregate3(allCalls);
        multicall3Gas = gasBefore - gasleft();

        // Get the last result (orchestrator call result)
        // Check all calls for failures (all results except the last one, which is the orchestrator call)
        if (results.length > 1) {
            for (uint256 i = 0; i < results.length - 1; i++) {
                // If any call failed, we return gasUsed = 0, multicall3Gas, and the error data from that call
                if (!results[i].success) {
                    return (0, 0, results[i].returnData);
                }
            }
        }
        IMulticall3.Result memory lastResult = results[results.length - 1];
        lastReturnData = lastResult.returnData;

        // Parse gasUsed from the orchestrator's return data
        // Assembly required for low-level parsing of return data
        assembly ("memory-safe") {
            let returnDataPtr := add(lastReturnData, 0x20)

            switch isStateOverride
            case 0 {
                // If `isStateOverride` is false, the orchestrator reverts with SimulationPassed
                // so success will be false in multicall3's Result, but we still need to parse the revert data
                // Check for SimulationPassed selector (0x4f0c028c)
                // The `gasUsed` will be in the revert data at offset 0x04
                if eq(shr(224, mload(returnDataPtr)), 0x4f0c028c) {
                    gasUsed := mload(add(returnDataPtr, 0x04))
                }
            }
            default {
                // If isStateOverride is true and call succeeded, gasUsed is at offset 0x00
                let lastSuccess := mload(lastResult)
                if lastSuccess {
                    gasUsed := mload(returnDataPtr)
                }
            }
        }
    }

    /// @dev Bubbles up the error from the multicall3's last result returnData.
    /// This is called when _callMulticall3 returns gasUsed == 0.
    function _bubbleUpMulticall3Error(bytes memory errorData) internal pure {
        assembly ("memory-safe") {
            revert(add(errorData, 0x20), mload(errorData))
        }
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
    /// @param encodedIntent The encoded user operation
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
        bytes calldata encodedIntent
    ) public payable virtual returns (uint256 gasUsed, uint256 combinedGas) {
        // 1. Primary Simulation Run to get initial gasUsed value with combinedGasOverride
        gasUsed = _callOrchestratorCalldata(oc, false, type(uint256).max, encodedIntent);

        // If the simulation failed, bubble up the full revert.
        assembly ("memory-safe") {
            if iszero(gasUsed) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }

        // Update payment amounts using the gasUsed value
        ICommon.Intent memory u = abi.decode(encodedIntent, (ICommon.Intent));

        u.combinedGas += gasUsed;

        _updatePaymentAmounts(u, u.combinedGas, paymentPerGasPrecision, paymentPerGas);

        while (true) {
            gasUsed = _callOrchestratorMemory(oc, false, 0, u);

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

            _updatePaymentAmounts(u, gasIncrement, paymentPerGasPrecision, paymentPerGas);

            // Step up the combined gas, until we see a simulation passing
            u.combinedGas += gasIncrement;
        }
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

        ICommon.Intent memory u = abi.decode(encodedIntent, (ICommon.Intent));

        _updatePaymentAmounts(u, combinedGas, paymentPerGasPrecision, paymentPerGas);

        u.combinedGas = combinedGas;

        // Verification Run to generate the logs with the correct combinedGas and payment amounts.
        gasUsed = _callOrchestratorMemory(oc, true, 0, u);

        // If the simulation failed, bubble up full revert
        assembly ("memory-safe") {
            if iszero(gasUsed) {
                let m := mload(0x40)
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @dev Simulates the execution of an intent through Multicall3, with calls executed before the orchestrator call.
    /// Finds the combined gas by iteratively increasing it until the simulation passes.
    /// The start value for combinedGas is gasUsed + original combinedGas.
    /// Set u.combinedGas to add some starting offset to the gasUsed value.
    /// @param multicall3 The multicall3 contract address
    /// @param calls Array of Call3 structs to execute before the orchestrator call
    /// @param oc The orchestrator address
    /// @param paymentPerGasPrecision The precision of the payment per gas value.
    /// paymentAmount = gas * paymentPerGas / (10 ** paymentPerGasPrecision)
    /// @param paymentPerGas The amount of `paymentToken` to be added per gas unit.
    /// Total payment is calculated as paymentAmount += gasUsed * paymentPerGas.
    /// @dev Set paymentAmount to include any static offset to the gas value.
    /// @param combinedGasIncrement Basis Points increment to be added for each iteration of searching for combined gas.
    /// @dev The closer this number is to 10_000, the more precise combined gas will be. But more iterations will be needed.
    /// @dev This number should always be > 10_000, to get correct results.
    /// If the increment is too small, the function might run out of gas while finding the combined gas value.
    /// @param encodedIntent The encoded user operation
    /// @return gasUsed The gas used in the successful simulation
    /// @return multicall3Gas The gas spent on the aggregate3 call
    /// @return combinedGas The first combined gas value that gives a successful simulation.
    /// This function reverts if the primary simulation run with max combinedGas fails.
    /// If the primary run is successful, it iteratively increases u.combinedGas by `combinedGasIncrement` until the simulation passes.
    /// All failing simulations during this run are ignored.
    function simulateMulticall3CombinedGas(
        address multicall3,
        IMulticall3.Call3[] memory calls,
        address oc,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        bytes calldata encodedIntent
    ) public payable virtual returns (uint256 gasUsed, uint256 multicall3Gas, uint256 combinedGas) {
        // Decode the intent first
        ICommon.Intent memory u = abi.decode(encodedIntent, (ICommon.Intent));

        bytes memory errorData;

        // 1. Primary Simulation Run to get initial gasUsed value with combinedGasOverride

        (gasUsed, multicall3Gas, errorData) =
            _callMulticall3(multicall3, calls, oc, false, type(uint256).max, u);

        // If the simulation failed, bubble up the orchestrator's error.
        if (gasUsed == 0) {
            _bubbleUpMulticall3Error(errorData);
        }

        u.combinedGas += gasUsed;

        _updatePaymentAmounts(u, u.combinedGas, paymentPerGasPrecision, paymentPerGas);

        while (true) {
            (gasUsed, multicall3Gas, errorData) =
                _callMulticall3(multicall3, calls, oc, false, 0, u);

            // If the simulation failed, check if it's a PaymentError and bubble it up.
            // PaymentError is given special treatment here, as it comes from
            // the account not having enough funds, and cannot be recovered from,
            // since the paymentAmount will keep increasing in this loop.
            if (gasUsed == 0 && errorData.length >= 4) {
                // errorData is a bytes memory containing the revert data from the orchestrator
                // Layout: [length (32 bytes)][selector (4 bytes)][additional data...]
                bytes4 errorSelector;
                assembly ("memory-safe") {
                    // Load 32 bytes starting from errorData+32
                    // bytes4 values are already right-aligned, no shift needed
                    errorSelector := mload(add(errorData, 32))
                }
                if (errorSelector == 0xabab8fc9) {
                    // PaymentError()

                    // Revert with just the selector (0x20 bytes = 4 bytes selector + 28 bytes padding)
                    assembly ("memory-safe") {
                        mstore(0x00, errorSelector)
                        revert(0x00, 0x20)
                    }
                }
            }

            if (gasUsed != 0) {
                return (gasUsed, multicall3Gas, u.combinedGas);
            }

            uint256 gasIncrement = Math.mulDiv(u.combinedGas, combinedGasIncrement, 10_000);

            _updatePaymentAmounts(u, gasIncrement, paymentPerGasPrecision, paymentPerGas);

            // Step up the combined gas, until we see a simulation passing
            u.combinedGas += gasIncrement;
        }
    }

    /// @dev Same as simulateMulticall3CombinedGas, but with an additional verification run
    /// that generates a successful non reverting state override simulation.
    /// Which can be used in eth_simulateV1 to get the trace.
    /// @param multicall3 The multicall3 contract address
    /// @param calls Array of Call3 structs to execute before the orchestrator call
    /// @param oc The orchestrator address
    /// @param paymentPerGasPrecision The precision of the payment per gas value.
    /// paymentAmount = gas * paymentPerGas / (10 ** paymentPerGasPrecision)
    /// @param paymentPerGas The amount of `paymentToken` to be added per gas unit.
    /// @param combinedGasIncrement Basis Points increment to be added for each iteration of searching for combined gas.
    /// @param combinedGasVerificationOffset is a static value that is added after a successful combinedGas is found.
    /// This can be used to account for variations in sig verification gas, for keytypes like P256.
    /// @param encodedIntent The encoded user operation
    /// @return gasUsed The gas used in the successful simulation
    /// @return multicall3Gas The gas spent on the aggregate3 call
    /// @return combinedGas The combined gas value including the verification offset
    function simulateMulticall3V1Logs(
        address multicall3,
        IMulticall3.Call3[] memory calls,
        address oc,
        uint8 paymentPerGasPrecision,
        uint256 paymentPerGas,
        uint256 combinedGasIncrement,
        uint256 combinedGasVerificationOffset,
        bytes calldata encodedIntent
    ) public payable virtual returns (uint256 gasUsed, uint256 multicall3Gas, uint256 combinedGas) {
        (gasUsed, multicall3Gas, combinedGas) = simulateMulticall3CombinedGas(
            multicall3,
            calls,
            oc,
            paymentPerGasPrecision,
            paymentPerGas,
            combinedGasIncrement,
            encodedIntent
        );

        combinedGas += combinedGasVerificationOffset;

        ICommon.Intent memory u = abi.decode(encodedIntent, (ICommon.Intent));

        _updatePaymentAmounts(u, combinedGas, paymentPerGasPrecision, paymentPerGas);

        u.combinedGas = combinedGas;

        bytes memory errorData;

        // Verification Run to generate the logs with the correct combinedGas and payment amounts.
        (gasUsed, multicall3Gas, errorData) = _callMulticall3(multicall3, calls, oc, true, 0, u);

        // If the simulation failed, bubble up the orchestrator's error
        if (gasUsed == 0) {
            _bubbleUpMulticall3Error(errorData);
        }
    }
}
