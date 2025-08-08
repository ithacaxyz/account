// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Orchestrator} from "../Orchestrator.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

contract OrchestratorSim is Orchestrator {
    /// @dev The simulate execute run has failed. Try passing in more gas to the simulation.
    error SimulateExecuteFailed();

    /// @dev The simulation has passed.
    error SimulationPassed(uint256 gAccountExecute);

    bool transient _checkAccountExecuteGas;

    uint256 transient _gAccountExecute;

    address constant ORCHESTRATOR = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;

    constructor(address pauseAuthority) Orchestrator(pauseAuthority) {}

    /// @dev Minimal function, to allow hooking into the _execute function with the simulation flags set to true.
    /// When flags is set to true, all errors are bubbled up. Also signature verification always returns true.
    /// But the codepaths for signature verification are still hit, for correct gas measurement.
    /// @dev If `isRevert` is false, then this function will always revert.
    /// If the simulation is successful, then it reverts with `SimulationPassed` error.
    /// If `isRevert` is true, then this function will not revert if the simulation is successful.
    /// This mode has been added so that receipt logs can be generated for `eth_simulateV1`
    /// @return gasUsed The amount of gas used by the execution. (Only returned if `isRevert` is true)
    /// gAccountExecute is the amount of gas used by the account.execute function.
    /// (Includes the gas cost, to make the call)
    function simulateExecute(
        bool isRevert,
        bool checkAccountExecuteGas,
        bytes calldata encodedIntent
    ) external payable returns (uint256 /*gAccountExecute*/ ) {
        _checkAccountExecuteGas = checkAccountExecuteGas;
        // If Simulation fails, then it will revert here.
        execute(encodedIntent);

        if (isRevert) {
            // If Simulation Passes, then it will revert here.
            revert SimulationPassed(_gAccountExecute);
        } else {
            return (_gAccountExecute);
        }
    }

    function _checkCallDepth(uint256 accountExecuteGas) internal override {
        if (_checkAccountExecuteGas) {
            super._checkCallDepth(accountExecuteGas);
        }
    }

    function _accountExecute(address eoa, bytes memory data, uint256 executeGas)
        internal
        override
    {
        if (_checkAccountExecuteGas) {
            if (((gasleft() * 63) >> 6) < Math.saturatingAdd(executeGas, 1000)) {
                revert InsufficientAccountExecuteGas();
            }
        }
        uint256 gStart = gasleft();

        assembly ("memory-safe") {
            mstore(0x00, 0) // Zeroize the return slot.
            if iszero(call(executeGas, eoa, 0, add(0x20, data), mload(data), 0x00, 0x20)) {
                returndatacopy(mload(0x40), 0x00, returndatasize())
                revert(mload(0x40), returndatasize())
            }
        }

        _gAccountExecute = Math.rawSub(gStart, gasleft());
    }

    function _selfCall(bytes32 keyHash, bytes32 digest, bytes calldata encodedIntent)
        internal
        virtual
        override
    {
        assembly ("memory-safe") {
            let m := mload(0x40) // Load the free memory pointer
            mstore(0x00, 0) // Zeroize the return slot.
            mstore(m, 0x00000001) // `selfCallExecutePay1395256087()`
            mstore(add(m, 0x20), keyHash) // Add keyHash as second param
            mstore(add(m, 0x40), digest) // Add digest as third param
            mstore(add(m, 0x60), 0x80) // Add offset of encoded Intent as third param
            let encodedIntentLength := sub(calldatasize(), 0x44)
            mstore(add(m, 0x80), encodedIntentLength) // Add length of encoded Intent at offset.
            calldatacopy(add(m, 0xa0), 0x44, encodedIntentLength) // Add actual intent data.

            // We don't revert if the selfCallExecutePay reverts,
            // Because we don't want to return the prePayment, since the relay has already paid for the gas.
            if iszero(
                call(gas(), ORCHESTRATOR, 0, add(m, 0x1c), add(0x84, encodedIntentLength), m, 0x20)
            ) {
                // TODO: We should not revert here.
                // returndatacopy(mload(0x40), 0x00, returndatasize())
                // revert(mload(0x40), returndatasize())
            }
        }
    }

    /// @dev Guards a function such that it can only be called by `address(this)`.
    modifier onlyThis() virtual override {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }
}
