// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ICommon {
    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////
    /// @dev A struct to hold the intent fields.
    /// Since L2s already include calldata compression with savings forwarded to users,
    /// we don't need to be too concerned about calldata overhead
    struct Intent {
        ////////////////////////////////////////////////////////////////////////
        // EIP-712 Fields
        ////////////////////////////////////////////////////////////////////////
        /// @dev The user's address.
        address eoa;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData;
        /// @dev Per delegated EOA.
        /// This nonce is a 4337-style 2D nonce with some specializations:
        /// - Upper 192 bits are used for the `seqKey` (sequence key).
        ///   The upper 16 bits of the `seqKey` is `MULTICHAIN_NONCE_PREFIX`,
        ///   then the Intent EIP712 hash will exclude the chain ID.
        /// - Lower 64 bits are used for the sequential nonce corresponding to the `seqKey`.
        uint256 nonce;
        /// @dev The account paying the payment token.
        /// If this is `address(0)`, it defaults to the `eoa`.
        address payer;
        /// @dev The ERC20 or native token used to pay for gas.
        address paymentToken;
        /// @dev The maximum amount of the token to pay.
        uint256 paymentMaxAmount;
        /// @dev The combined gas limit for payment, verification, and calling the EOA.
        uint256 combinedGas;
        /// @dev Optional array of encoded SignedCalls that will be verified and executed
        /// before the validation of the overall Intent.
        /// A PreCall will NOT have its gas limit or payment applied.
        /// The overall Intent's gas limit and payment will be applied, encompassing all its PreCalls.
        /// The execution of a PreCall will check and increment the nonce in the PreCall.
        /// If at any point, any PreCall cannot be verified to be correct, or fails in execution,
        /// the overall Intent will revert before validation, and execute will return a non-zero error.
        bytes[] encodedPreCalls;
        /// @dev Only relevant for multi chain intents.
        /// There should not be any duplicate token addresses. Use address(0) for native token.
        /// If native token is used, the first transfer should be the native token transfer.
        /// If encodedFundTransfers is not empty, then the intent is considered the output intent.
        bytes[] encodedFundTransfers;
        /// @dev The settler address.
        address settler;
        /// @dev The expiry timestamp for the intent. The intent is invalid after this timestamp.
        /// If expiry timestamp is set to 0, then expiry is considered to be infinite.
        uint256 expiry;
        ////////////////////////////////////////////////////////////////////////
        // Additional Fields (Not included in EIP-712)
        ////////////////////////////////////////////////////////////////////////
        /// @dev Whether the intent should use the multichain mode - i.e verify with merkle sigs
        /// and send the cross chain message.
        bool isMultichain;
        /// @dev The funder address.
        address funder;
        /// @dev The funder signature.
        bytes funderSignature;
        /// @dev The settler context data to be passed to the settler.
        bytes settlerContext;
        /// @dev The actual payment amount, requested by the filler. MUST be less than or equal to `paymentMaxAmount`
        uint256 paymentAmount;
        /// @dev The payment recipient for the ERC20 token.
        /// Excluded from signature. The filler can replace this with their own address.
        /// This enables multiple fillers, allowing for competitive filling, better uptime.
        address paymentRecipient;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
        /// @dev Optional payment signature to be passed into the `compensate` function
        /// on the `payer`. This signature is NOT included in the EIP712 signature.
        bytes paymentSignature;
        /// @dev Optional. If non-zero, the EOA must use `supportedAccountImplementation`.
        /// Otherwise, if left as `address(0)`, any EOA implementation will be supported.
        /// This field is NOT included in the EIP712 signature.
        address supportedAccountImplementation;
    }

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
