// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ICommon {
    /// @dev A struct to hold the fields for a SignedCall.
    /// A SignedCall is a struct that contains a signed execution batch along with the nonce
    // and address of the user.
    struct SignedCall {
        /// @dev The user's address.
        /// This can be set to `address(0)`, which allows it to be
        /// coalesced to the parent Intent's EOA.
        address eoa;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData;
        /// @dev Per delegated EOA. Same logic as the `nonce` in Intent.
        uint256 nonce;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
    }

    struct Transfer {
        address token;
        uint256 amount;
    }
}
