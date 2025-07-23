// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrchestrator} from "./interfaces/IOrchestrator.sol";

/// @title Batcher
/// @notice Contract for executing multiple intents through the orchestrator in a single transaction
/// @dev Individual intent failures do not revert the entire batch
contract Batcher {
    /// @notice Emitted when an intent execution fails
    event IntentFailed(uint256 indexed index, bytes reason);

    error InvalidArrayLength();
    error ArrayLengthMismatch();

    /// @notice Execute multiple intents through the orchestrator
    /// @param orchestrator The orchestrator contract address
    /// @param encodedIntents Array of encoded intents
    /// @param intentGas Array of gas amounts for each intent
    function batchExecute(
        address orchestrator,
        bytes[] calldata encodedIntents,
        uint256[] calldata intentGas
    ) external {
        uint256 length = encodedIntents.length;

        if (length == 0) revert InvalidArrayLength();
        if (length != intentGas.length) revert ArrayLengthMismatch();

        // Execute each intent
        for (uint256 i = 0; i < length; ++i) {
            // Encode the function call
            bytes memory data =
                abi.encodeWithSelector(IOrchestrator.execute.selector, encodedIntents[i]);

            // Make the call with specified gas
            (bool success, bytes memory returnData) = orchestrator.call{gas: intentGas[i]}(data);

            if (!success) {
                emit IntentFailed(i, returnData);
            }
        }
    }
}
