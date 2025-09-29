// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBit} from "solady/utils/LibBit.sol";
import {LibStorage} from "solady/utils/LibStorage.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title LibNonce
/// @notice Helper library for ERC4337 style 2D nonces.
library LibNonce {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev The nonce is invalid.
    error InvalidNonce();

    /// @dev When invalidating a nonce sequence, the new sequence must be larger than the current.
    error NewSequenceMustBeLarger();

    ////////////////////////////////////////////////////////////////////////
    // Operations
    ////////////////////////////////////////////////////////////////////////

    /// @dev Return current nonce with sequence key.
    function get(mapping(uint192 => LibStorage.Ref) storage seqMap, uint192 seqKey)
        internal
        view
        returns (uint256)
    {
        return seqMap[seqKey].value | (uint256(seqKey) << 64);
    }

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to (inclusive) `uint64(nonce)`.
    function invalidate(mapping(uint192 => LibStorage.Ref) storage seqMap, uint256 nonce) internal {
        LibStorage.Ref storage s = seqMap[uint192(nonce >> 64)];
        if (uint64(nonce) < s.value) revert NewSequenceMustBeLarger();
        s.value = Math.rawAdd(Math.min(uint64(nonce), 2 ** 64 - 2), 1);
    }

    /// @dev Checks that the nonce matches the current sequence.
    function check(mapping(uint192 => LibStorage.Ref) storage seqMap, uint256 nonce)
        internal
        view
        returns (LibStorage.Ref storage s, uint256 seq)
    {
        s = seqMap[uint192(nonce >> 64)];
        seq = s.value;
        if (!LibBit.and(seq < type(uint64).max, seq == uint64(nonce))) revert InvalidNonce();
    }

    /// @dev Checks and increment the nonce.
    function checkAndIncrement(mapping(uint192 => LibStorage.Ref) storage seqMap, uint256 nonce)
        internal
    {
        (LibStorage.Ref storage s, uint256 seq) = check(seqMap, nonce);
        unchecked {
            s.value = seq + 1;
        }
    }
}
