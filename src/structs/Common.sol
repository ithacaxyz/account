// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

////////////////////////////////////////////////////////////////////////
// Data Structures
////////////////////////////////////////////////////////////////////////
/// @dev A struct to hold the user operation fields.
/// Since L2s already include calldata compression with savings forwarded to users,
/// we don't need to be too concerned about calldata overhead
struct UserOp {
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
    /// @dev The payment recipient for the ERC20 token.
    /// Excluded from signature. The filler can replace this with their own address.
    /// This enables multiple fillers, allowing for competitive filling, better uptime.
    /// If `address(0)`, the payment will be accrued by the entry point.
    address paymentRecipient;
    /// @dev The amount of the token to pay.
    /// Excluded from signature. This will be required to be less than `paymentMaxAmount`.
    uint256 paymentAmount;
    /// @dev The maximum amount of the token to pay.
    uint256 paymentMaxAmount;
    /// @dev The amount of ERC20 to pay per gas spent. For calculation of refunds.
    /// If this is left at zero, it will be treated as infinity (i.e. no refunds).
    uint256 paymentPerGas;
    /// @dev The combined gas limit for payment, verification, and calling the EOA.
    uint256 combinedGas;
    /// @dev The wrapped signature.
    /// `abi.encodePacked(innerSignature, keyHash, prehash)`.
    bytes signature;
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
    /// @dev Optional payment signature to be passed into the `compensate` function
    /// on the `payer`. This signature is NOT included in the EIP712 signature.
    bytes paymentSignature;
}

/// @dev This has the same layout as the ERC7579's execution struct.
struct Call {
    /// @dev The call target.
    address to;
    /// @dev Amount of native value to send to the target.
    uint256 value;
    /// @dev The calldata bytes.
    bytes data;
}
