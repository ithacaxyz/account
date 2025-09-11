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

    /// @dev A struct to hold the fields for an Intent.
    /// This struct is used for testing and visual purposes only.
    struct Intent {
        address supportedAccountImplementation;
        address eoa;
        uint256 nonce;
        address payer;
        address paymentToken;
        uint256 paymentMaxAmount;
        uint256 combinedGas;
        uint256 expiry;
        uint256 paymentAmount;
        address paymentRecipient;
        uint256 executionDataLength;
        bytes executionData;
        uint256 fundDataLength;
        bytes fundData; // abi.encode(funder, funderSignature, encodedFundTransfers)
        uint256 encodedPreCallsLength;
        bytes encodedPreCalls; // abi.encode(bytes[])
        uint256 signatureLength;
        bytes signature;
        uint256 settlerDataLength;
        bytes settlerData; // To use settler, nonce needs to have `MERKLE_VERIFICATION` prefix. 20b settler + settlerContext
        bytes paymentSignature;
        uint256 paymentSignatureLength; // Instead of prefixed length for paymentSignature, we do a suffix length
    }
}
