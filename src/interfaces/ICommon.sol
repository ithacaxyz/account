// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ICommon {
    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////
    /// @dev A struct to hold the user operation fields.
    /// Since L2s already include calldata compression with savings forwarded to users,
    /// we don't need to be too concerned about calldata overhead
    struct UserOp {
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
        ///   then the UserOp EIP712 hash will exclude the chain ID.
        /// - Lower 64 bits are used for the sequential nonce corresponding to the `seqKey`.
        uint256 nonce;
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
        /// @dev Optional data for `initPREP` on the delegation.
        /// This is encoded using ERC7821 style batch execution encoding.
        /// (ERC7821 is a variant of ERC7579).
        /// `abi.encode(calls, abi.encodePacked(bytes32(saltAndDelegation)))`,
        /// where `calls` is of type `Call[]`,
        /// and `saltAndDelegation` is `bytes32((uint256(salt) << 160) | uint160(delegation))`.
        bytes initData;
        /// @dev Optional array of encoded UserOps that will be verified and executed
        /// after PREP (if any) and before the validation of the overall UserOp.
        /// A PreOp will NOT have its gas limit or payment applied.
        /// The overall UserOp's gas limit and payment will be applied, encompassing all its PreOps.
        /// The execution of a PreOp will check and increment the nonce in the PreOp.
        /// If at any point, any PreOp cannot be verified to be correct, or fails in execution,
        /// the overall UserOp will revert before validation, and execute will return a non-zero error.
        /// A PreOp can contain PreOps, forming a tree structure.
        /// The `executionData` tree will be executed in post-order (i.e. left -> right -> current).
        /// The `encodedPreOps` are included in the EIP712 signature, which enables execution order
        /// to be enforced on-the-fly even if the nonces are from different sequences.
        bytes[] encodedPreOps;
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
        // TODO: Payment recipient is not substituted with address(entrypoint), if you send address(0). This is a breaking change, add to changeset.
        address paymentRecipient;
        /// @dev The wrapped signature.
        /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
        bytes signature;
        /// @dev Optional payment signature to be passed into the `compensate` function
        /// on the `payer`. This signature is NOT included in the EIP712 signature.
        bytes paymentSignature;
    }
}
