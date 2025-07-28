// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// This contract provides access to UlnOptions for testing
contract UlnOptionsTestHelper {
    error LZ_ULN_InvalidWorkerOptions(uint256 cursor);

    // Minimal decode function that mimics UlnOptions.decode behavior
    // This verifies that options of at least 2 bytes are valid
    function decodeOptions(bytes calldata _options)
        external
        pure
        returns (uint16 optionType, bool hasWorkerOptions)
    {
        // Check minimum length requirement (same as UlnOptions)
        if (_options.length < 2) revert LZ_ULN_InvalidWorkerOptions(0);

        // Extract option type
        optionType = uint16(bytes2(_options[0:2]));

        // Check if there are worker options after the type header
        hasWorkerOptions = _options.length > 2;
    }
}
