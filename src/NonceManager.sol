// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBit} from "solady/utils/LibBit.sol";
import {LibStorage} from "solady/utils/LibStorage.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title NonceManager
/// @notice Mixin for ERC4337 style 2D nonces.
contract NonceManager {
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
    function _getNonce(mapping(uint192 => LibStorage.Ref) storage map, uint192 seqKey)
        internal
        view
        virtual
        returns (uint256)
    {
        return map[seqKey].value | (uint256(seqKey) << 64);
    }

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to (inclusive) `uint64(nonce)`.
    function _invalidateNonce(mapping(uint192 => LibStorage.Ref) storage map, uint256 nonce)
        internal
        virtual
    {
        LibStorage.Ref storage $ = map[uint192(nonce >> 64)];
        if (uint64(nonce) < $.value) revert NewSequenceMustBeLarger();
        $.value = Math.rawAdd(Math.min(uint64(nonce), 2 ** 64 - 2), 1);
    }

    /// @dev Checks that the nonce matches the current sequence.
    function _checkNonce(mapping(uint192 => LibStorage.Ref) storage map, uint256 nonce)
        internal
        view
        virtual
        returns (LibStorage.Ref storage $, uint256 seq)
    {
        $ = map[uint192(nonce >> 64)];
        seq = $.value;
        if (!LibBit.and(seq < type(uint64).max, seq == uint64(nonce))) revert InvalidNonce();
    }

    /// @dev Checks and increment the nonce.
    function _checkAndIncrementNonce(mapping(uint192 => LibStorage.Ref) storage map, uint256 nonce)
        internal
    {
        (LibStorage.Ref storage $, uint256 seq) = _checkNonce(map, nonce);
        unchecked {
            $.value = seq + 1;
        }
    }
}
