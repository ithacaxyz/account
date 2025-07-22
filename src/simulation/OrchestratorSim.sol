// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Orchestrator} from "../Orchestrator.sol";

contract OrchestratorSim is Orchestrator {
    /// @dev The simulate execute run has failed. Try passing in more gas to the simulation.
    error SimulateExecuteFailed();

    /// @dev The simulation has passed.
    error SimulationPassed(uint256 gUsed);

    constructor(address pauseAuthority) Orchestrator(pauseAuthority) {}

    /// @dev Minimal function, to allow hooking into the _execute function with the simulation flags set to true.
    /// When flags is set to true, all errors are bubbled up. Also signature verification always returns true.
    /// But the codepaths for signature verification are still hit, for correct gas measurement.
    /// @dev If `isStateOverride` is false, then this function will always revert. If the simulation is successful, then it reverts with `SimulationPassed` error.
    /// If `isStateOverride` is true, then this function will not revert if the simulation is successful.
    /// But the balance of msg.sender has to be equal to type(uint256).max, to prove that a state override has been made offchain,
    /// and this is not an onchain call. This mode has been added so that receipt logs can be generated for `eth_simulateV1`
    /// @return gasUsed The amount of gas used by the execution. (Only returned if `isStateOverride` is true)
    function simulateExecute(bool isStateOverride, bytes calldata encodedIntent)
        external
        payable
        returns (uint256)
    {
        // If Simulation Fails, then it will revert here.
        (uint256 gUsed) = _execute(encodedIntent);

        if (isStateOverride) {
            return gUsed;
        } else {
            // If Simulation Passes, then it will revert here.
            revert SimulationPassed(gUsed);
        }
    }
}
