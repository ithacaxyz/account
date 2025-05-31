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
        /// @dev The account paying the payment token.
        /// If this is `address(0)`, it defaults to the `eoa`.
        address payer;
        /// @dev The ERC20 or native token used to pay for gas.
        address paymentToken;
        /// @dev The amount of the token to pay, before the call batch is executed
        /// This will be required to be less than `totalPaymentMaxAmount`.
        uint256 prePaymentMaxAmount;
        /// @dev The maximum amount of the token to pay.
        uint256 totalPaymentMaxAmount;
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
        /// Use the encoded structs, to save gas.
        /// @dev Origin Chain Inputs
        Payload[] inputs;
        /// @dev Destination Chain Output
        Payload output;
        address eoa;
        ////////////////////////////////////////////////////////////////////////
        // Additional Fields (Not included in EIP-712)
        ////////////////////////////////////////////////////////////////////////
        /// @dev The actual pre payment amount, requested by the filler. MUST be less than or equal to `prePaymentMaxAmount`
        uint256 prePaymentAmount;
        /// @dev The actual total payment amount, requested by the filler. MUST be less than or equal to `totalPaymentMaxAmount`
        uint256 totalPaymentAmount;
        /// @dev The payment recipient for the ERC20 token.
        /// Excluded from signature. The filler can replace this with their own address.
        /// This enables multiple fillers, allowing for competitive filling, better uptime.
        address paymentRecipient;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        /// TODO: Having only one signature, means that all chains must have a synced key.
        /// Other options -
        /// 1. Each payload has a signature. Leads to duplicated calldata
        /// if all accounts are synced across chains.
        /// 2. Update signature encoding to <chainId,signature,keyHash,preHash> (RECOMMENDED),
        /// This prevents duplication of calldata in synced cases, as chainId can be set to 0.
        bytes signature;
        /// @dev Optional payment signature to be passed into the `compensate` function
        /// on the `payer`. This signature is NOT included in the EIP712 signature.
        bytes paymentSignature;
        /// @dev Optional. If non-zero, the EOA must use `supportedAccountImplementation`.
        /// Otherwise, if left as `address(0)`, any EOA implementation will be supported.
        /// This field is NOT included in the EIP712 signature.
        address supportedAccountImplementation;
    }

    /// TODO: SignedCall is just the payload without tokenTransfers, with a signature.
    /// Maybe we just remove this?
    /// @dev A struct to hold the fields for a SignedCall.
    /// A SignedCall is a struct that contains a signed execution batch along with the nonce
    // and address of the user.
    struct SignedCall {
        /// @dev Chain ID for the SignedCall. Use 0 for multichain.
        uint256 chainId;
        /// @dev The user's address.
        /// This can be set to `address(0)`, which allows it to be
        /// coalesced to the parent Intent's EOA.
        address eoa;
        uint256 nonce;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
    }

    struct Transfer {
        address token;
        uint256 amount;
    }

    struct Payload {
        /// @dev Chain ID for the SignedCall. Use 0 for multichain.
        uint256 chainId;
        uint256 nonce;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        /// `abi.encode(calls)`, where `calls` is of type `Call[]`.
        /// This allows for more efficient safe forwarding to the EOA.
        bytes executionData;
        /// <token,value> pairs to pull/push for successful execution
        Transfer[] transfers;
    }
}
