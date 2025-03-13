// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibStorage} from "solady/utils/LibStorage.sol";
import {CallContextChecker} from "solady/utils/CallContextChecker.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";
import {LibPREP} from "./LibPREP.sol";
import {LibNonce} from "./LibNonce.sol";

/// @title EntryPoint
/// @notice Enables atomic verification, gas compensation and execution across eoas.
/// @dev
/// The EntryPoint allows relayers to submit payloads on one or more eoas,
/// and get compensated for the gas spent in an atomic transaction.
/// It serves the following purposes:
/// - Facilitate fair gas compensation to the relayer.
///   This means capping the amount of gas consumed,
///   such that it will not exceed the signed gas stipend,
///   and ensuring the relayer gets compensated even if the call to the eoa reverts.
///   This also means minimizing the risk of griefing the relayer, in areas where
///   we cannot absolutely guarantee compensation for gas spent.
/// - Ensures that the eoa can safely compensate the relayer.
///   This means ensuring that the eoa cannot be drained.
///   This means ensuring that the compensation is capped by the signed max amount.
///   Tokens can only be deducted from an eoa once per signed nonce.
/// - Minimize chance of censorship.
///   This means once an UserOp is signed, it is infeasible to
///   alter or rearrange it to force it to fail.
contract EntryPoint is EIP712, Ownable, CallContextChecker, ReentrancyGuardTransient {
    using LibERC7579 for bytes32[];
    using EfficientHashLib for bytes32[];
    using LibBitmap for LibBitmap.Bitmap;

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    /// @dev This has the same layout as the ERC7579's execution struct.
    struct Call {
        /// @dev The call target.
        address target;
        /// @dev Amount of native value to send to the target.
        uint256 value;
        /// @dev The calldata bytes.
        bytes data;
    }

    /// @dev A struct to hold the user operation fields.
    /// Since L2s already include calldata compression with savings forwarded to users,
    /// we don't need to be too concerned about calldata overhead.
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
        ///   then the UserOp EIP-712 hash will exclude the chain ID.
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
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Unable to perform the payment.
    error PaymentError();

    /// @dev Unable to verify the user op. The user op may be invalid.
    error VerificationError();

    /// @dev Unable to perform the call.
    error CallError();

    /// @dev Unable to perform the verification and the call.
    error VerifiedCallError();

    /// @dev Out of gas to perform the call operation.
    error InsufficientGas();

    /// @dev The order has already been filled.
    error OrderAlreadyFilled();

    /// @dev For returning the gas required and the error from a simulation.
    /// For the meaning of the returned variables, see `simulateExecute`.
    error SimulationResult(uint256 gExecute, uint256 gCombined, uint256 gUsed, bytes4 err);

    /// @dev The simulate execute run has failed. Try passing in more gas to the simulation.
    error SimulateExecuteFailed();

    /// @dev No revert has been encountered.
    error NoRevertEncountered();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev The nonce sequence of `eoa` is invalidated up to (inclusive) of `nonce`.
    /// The new available nonce will be `nonce + 1`.
    event NonceInvalidated(address indexed eoa, uint256 nonce);

    /// @dev Emitted when a UserOp is executed.
    /// This event is emitted in the `execute` function.
    /// - `incremented` denotes that `nonce`'s sequence has been incremented to invalidate `nonce`,
    /// - `err` denotes the resultant error selector.
    /// If `incremented` is true and `err` is non-zero,
    /// `err` will be stored for retrieval with `nonceStatus`.
    event UserOpExecuted(address indexed eoa, uint256 indexed nonce, bool incremented, bytes4 err);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant USER_OP_TYPEHASH = keccak256(
        "UserOp(bool multichain,address eoa,Call[] calls,uint256 nonce,address payer,address paymentToken,uint256 paymentMaxAmount,uint256 paymentPerGas,uint256 combinedGas)Call(address target,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");

    /// @dev For EIP712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    /// @dev Nonce prefix to signal that the payload is to be signed with EIP-712 without the chain ID.
    /// This constant is a pun for "chain ID 0".
    uint16 public constant MULTICHAIN_NONCE_PREFIX = 0xc1d0;

    /// @dev For ensuring that the remaining gas is sufficient for a self-call with
    /// overhead for cleaning up after the self-call. This also has an added benefit
    /// of preventing the censorship vector of calling `execute` in a very deep call-stack.
    /// With the 63/64 rule, and an initial gas of 30M, we can approximately make
    /// around 339 recursive calls before the amount of gas passed in drops below 100k.
    /// The EVM has a maximum call depth of 1024.
    uint256 internal constant _INNER_GAS_OVERHEAD = 100000;

    /// @dev The amount of expected gas for refunds.
    /// Should be enough for a cold zero to non-zero SSTORE + a warm SSTORE + a few SLOADs.
    uint256 internal constant _REFUND_GAS = 50000;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Holds the storage.
    struct EntryPointStorage {
        /// @dev Mapping of (`eoa`, `seqKey`) to nonce sequence.
        /// We use a `LibStorage.Ref` instead of a uint64 for performance.
        mapping(address => mapping(uint192 => LibStorage.Ref)) nonceSeqs;
        /// @dev Mapping of (`eoa`, `nonce`) to the error selector.
        /// If `uint64(nonce) < nonceSeqs[eoa][uint192(nonce >> 64)]`,
        /// it means that the nonce has either been used or invalidated,
        /// and a non-zero error selector denotes an error.
        /// Otherwise, if `uint64(nonce) >= nonceSeqs[eoa][uint192(nonce >> 64)]`,
        /// we would expect that the error selector is zero (i.e. uninitialized).
        mapping(address => mapping(uint256 => bytes4)) errs;
        /// @dev A bitmap to mark ERC7683 order IDs as filled, to prevent filling replays.
        LibBitmap.Bitmap filledOrderIds;
    }

    /// @dev Returns the storage pointer.
    function _getEntryPointStorage() internal pure returns (EntryPointStorage storage $) {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("PORTO_ENTRY_POINT_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////

    constructor(address initialOwner) payable {
        _initializeOwner(initialOwner);
    }

    ////////////////////////////////////////////////////////////////////////
    // Main
    ////////////////////////////////////////////////////////////////////////

    /// @dev Executes a single encoded user operation.
    /// `encodedUserOp` is given by `abi.encode(userOp)`, where `userOp` is a struct of type `UserOp`.
    /// If sufficient gas is provided, returns an error selector that is non-zero
    /// if there is an error during the payment, verification, and call execution.
    function execute(bytes calldata encodedUserOp)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4 err)
    {
        (, err) = _execute(encodedUserOp, 0);
    }

    /// @dev Executes the array of encoded user operations.
    /// Each element in `encodedUserOps` is given by `abi.encode(userOp)`,
    /// where `userOp` is a struct of type `UserOp`.
    function execute(bytes[] calldata encodedUserOps)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4[] memory errs)
    {
        // This allocation and loop was initially in assembly, but I've normified it for now.
        errs = new bytes4[](encodedUserOps.length);
        for (uint256 i; i < encodedUserOps.length; ++i) {
            // We reluctantly use regular Solidity to access `encodedUserOps[i]`.
            // This generates an unnecessary check for `i < encodedUserOps.length`, but helps
            // generate all the implicit calldata bound checks on `encodedUserOps[i]`.
            (, errs[i]) = _execute(encodedUserOps[i], 0);
        }
    }

    /// @dev This function does not actually execute.
    /// It simulates an execution and reverts with
    /// `SimulationResult(gExecute, gCombined, gUsed, err)`:
    /// - `gExecute` is the recommended amount of gas to pass into execute.
    ///    This does not include the minimum transaction overhead of 21k gas.
    ///    You will need to add that in.
    /// - `gCombined` is the recommendation for `gasCombined`.
    /// - `gUsed` is the amount of gas that has been eaten.
    /// - `err` is the error selector from the simulation.
    ///   If the `err` is non-zero, it means that the simulation with `gExecute`
    ///   has not resulted in a success execution.
    /// Notes:
    /// - `combinedGas` will be ignored and overwritten during estimation. Just leave it as zero.
    /// - `signature` is NOT required to be valid, but sufficient for triggering
    ///    the code paths to meter the gas required.
    ///   - EOA (no `keyHash`): `abi.encodePacked(r, s, v)`.
    ///   - Others (e.g. P256, with `keyHash`):
    ///     `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
    ///     The `keyHash` is required for triggering to validation and GuardedExecutor
    ///     code paths for that particular `keyHash`.
    ///   For most accurate metering, the signatures should be actual signatures,
    ///   but signed by a different private key of the same key type.
    ///   For simulations, we want to avoid early returns for trivially invalid signatures.
    function simulateExecute(bytes calldata encodedUserOp) public payable virtual {
        uint256 gExecute = gasleft();
        uint256 gCombined;
        uint256 gUsed;
        bytes4 err;
        assembly ("memory-safe") {
            function callSimulateExecute(g_, data_) -> _success {
                calldatacopy(0x00, calldatasize(), 0x40) // Zeroize the memory for the return data.
                pop(call(g_, address(), 0, add(data_, 0x20), mload(data_), 0x00, 0x40))
                _success := eq(shr(224, mload(0x00)), 0xffffffff)
            }
            function revertSimulateExecuteFailed() {
                mstore(0x00, 0x234e352e) // `SimulateExecuteFailed()`.
                revert(0x1c, 0x04)
            }
            // `abi.encodePacked(bytes4(0xffffffff), combinedGasOverride, encodedUserOp)`.
            let data := mload(0x40)
            mstore(add(data, 0x04), 0xffffffff) // `selfCallSimulateExecute565348489()`.
            calldatacopy(add(data, 0x44), encodedUserOp.offset, encodedUserOp.length)
            mstore(data, add(0x24, encodedUserOp.length)) // Store `data.length`.

            // Setting the bit at `1 << 254` tells `_execute` that we want the
            // simulation to skip the invalid signature revert and also the 63/64 rule revert.
            // Also use `2**96 - 1` as the `combinedGas` for the very first call to `_execute`.
            mstore(add(data, 0x24), or(shl(254, 1), 0xffffffffffffffffffffffff))
            if iszero(callSimulateExecute(gas(), data)) { revertSimulateExecuteFailed() }
            gUsed := mload(0x04)
            err := mload(0x24)
            // If the UserOp results in a successful execution, let's try to determine
            // the amount of gas that needs to be passed in.
            if iszero(err) {
                // Tell `selfCallSimulateExecute565348489()` that we just want the verification gas.
                mstore(add(data, 0x24), "gVerify")
                // We need to use a reverting simulation call to measure the verification gas,
                // as it resets warm address and storage access.
                if iszero(callSimulateExecute(gas(), data)) { revertSimulateExecuteFailed() }
                let gVerify := mload(0x04)
                // Heuristic: if the verification gas is > 60k, assume it is P256 verification
                // without the precompile, which has quite a large variance in verification gas.
                // Add 110k (empirically determined) to the `gUsed` to account for the variance.
                for { gCombined := add(gUsed, mul(110000, gt(gVerify, 60000))) } 1 {} {
                    gCombined := add(gCombined, shr(4, gCombined)) // Heuristic: multiply by 1.0625.
                    // Now that we are trying to hone in onto a good estimate for `combinedGas`, we
                    // still want to skip the invalid signature revert and also the 63/64 rule revert.
                    mstore(add(data, 0x24), or(shl(254, 1), gCombined))
                    if iszero(callSimulateExecute(gas(), data)) { revertSimulateExecuteFailed() }
                    if iszero(mload(0x24)) { break } // If `err` is zero, we've found the `gCombined`.
                }
                // Setting the `1 << 255` bit tells `_execute` to early return,
                // as we just want to test the 63/64 rule on `gExecute` for the given `gCombined`.
                mstore(add(data, 0x24), or(shl(255, 1), gCombined))
                for { gExecute := gCombined } 1 {} {
                    gExecute := add(gExecute, shr(5, gExecute)) // Heuristic: multiply by 1.03125.
                    if callSimulateExecute(gExecute, data) { if iszero(mload(0x24)) { break } }
                }
                // Add a bit of buffer to account for the variations in
                // function dispatch between `execute` and `simulateExecute`.
                gExecute := add(gExecute, 500)
            }
        }
        revert SimulationResult(gExecute, gCombined, gUsed, err);
    }

    /// @dev This function is intended for self-call via `simulateExecute`.
    /// The name is mined to give a function selector of `0xffffffff`, which makes it
    /// least efficient to call by placing it at the rightmost part of the function dispatch tree.
    /// As this is only for simulation purposes, it does not need to be efficient.
    ///
    /// Simply calling this function to get `gUsed` is NOT enough in production.
    /// It is NOT sufficient to simply estimate `gExecute` as `gUsed * a + b; a > 1 && b > 0`.
    /// Gas is burned at varying call depths, applying the 63/64 rule at different multiples
    /// to different segments of the gas burned. `gExecute` is NOT a constant multiple of `gUsed`.
    /// The only generalized reliable way to predict `gCombined` and `gExecute` is to
    /// try and error gas-limited self-calls via `simulateExecute` to this function.
    ///
    /// This function does not actually execute.
    /// It simulates an execution and reverts with
    /// `abi.encodePacked(bytes4(0xffffffff), abi.encode(gUsed, err))`.
    /// This function requires that `combinedGas` be set to a high enough value.
    /// Notes:
    /// - `gUsed` is the amount of gas that has been eaten.
    /// - `err` is the error selector from the simulation.
    ///   If the `err` is non-zero, it means that the simulation with `gExecute`
    ///   has not resulted in a success execution.
    function selfCallSimulateExecute565348489() public payable virtual {
        bytes calldata encodedUserOp;
        uint256 combinedGasOverride;
        assembly ("memory-safe") {
            combinedGasOverride := calldataload(0x04)
            encodedUserOp.offset := 0x24
            encodedUserOp.length := sub(calldatasize(), 0x24)
        }
        uint256 gUsed;
        bytes4 err;
        if (bytes32(combinedGasOverride) == bytes32("gVerify")) {
            uint256 gVerifyStart = gasleft();
            _verify(_extractUserOp(encodedUserOp));
            gUsed = Math.rawSub(gVerifyStart, gasleft());
        } else {
            (gUsed, err) = _execute(encodedUserOp, combinedGasOverride);
        }
        // Revert with `abi.encodePacked(bytes4(0xffffffff), abi.encode(gUsed, err))`.
        assembly ("memory-safe") {
            mstore(0x00, not(0)) // `0xffffffff`.
            mstore(0x04, gUsed)
            mstore(0x24, shl(224, shr(224, err))) // Clean the lower bytes of `err` word.
            revert(0x00, 0x44)
        }
    }

    /// @dev This function is provided for debugging purposes.
    /// This function bubbles up the full revert for the calls
    /// to `initializePREP` (if any) and `execute` on the eoa.
    function simulateFailed(bytes calldata encodedUserOp) public payable virtual {
        assembly ("memory-safe") {
            let m := mload(0x40) // Grab the free memory pointer.
            // Copy the encoded user op to the memory to be ready to pass to the self call.
            calldatacopy(add(m, 0x40), encodedUserOp.offset, encodedUserOp.length)
            mstore(m, 0x00000000) // `selfCallPayVerifyCall537021665()`.
            // The word after the function selector contains the simulation flags.
            // If `flags & 2 != 0`, it means it's a simulation to get the full revert.
            mstore(add(m, 0x20), 2)
            // Make the self-call and bubble up the full revert on failure.
            if iszero(
                call(gas(), address(), 0, add(m, 0x1c), add(encodedUserOp.length, 0x44), 0x00, 0x00)
            ) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
        revert NoRevertEncountered();
    }

    /// @dev Extracts the UserOp from the calldata bytes, with minimal checks.
    function _extractUserOp(bytes calldata encodedUserOp)
        internal
        virtual
        returns (UserOp calldata u)
    {
        // This function does NOT allocate memory to avoid quadratic memory expansion costs.
        // Otherwise, it will be unfair to the UserOps at the back of the batch.
        assembly ("memory-safe") {
            let t := calldataload(encodedUserOp.offset)
            u := add(t, encodedUserOp.offset)
            // Bounds check. We don't need to explicitly check the fields here.
            // In the self call functions, we will use regular Solidity to access the
            // dynamic fields like `signature`, which generate the implicit bounds checks.
            if or(shr(64, t), lt(encodedUserOp.length, 0x20)) { revert(0x00, 0x00) }
        }
    }

    /// @dev Executes a single encoded UserOp.
    function _execute(bytes calldata encodedUserOp, uint256 combinedGasOverride)
        internal
        virtual
        returns (uint256 gUsed, bytes4 err)
    {
        UserOp calldata u = _extractUserOp(encodedUserOp);
        uint256 g = Math.coalesce(uint96(combinedGasOverride), u.combinedGas);
        uint256 gStart = gasleft();

        unchecked {
            // Check if there's sufficient gas left for the gas-limited self calls
            // via the 63/64 rule. This is for gas estimation. If the total amount of gas
            // for the whole transaction is insufficient, revert.
            if (((gasleft() * 63) >> 6) < Math.saturatingAdd(g, _INNER_GAS_OVERHEAD)) {
                // Don't revert if the bit at `1 << 254` is set. For `simulateExecute2` to be able to
                // get a simulation before knowing how much gas is needed without reverting.
                if ((combinedGasOverride >> 254) & 1 == 0) revert InsufficientGas();
            }
            // If the bit at `1 << 255` is set, this means `simulateExecute2` just wants
            // to check the 63/64 rule, so early return to skip the rest of the computations.
            if (combinedGasOverride >> 255 != 0) return (0, 0);
        }

        address payer = Math.coalesce(u.payer, u.eoa);
        uint256 paymentAmount = u.paymentAmount;
        // Early skip the entire pay-verify-call workflow if the payer lacks tokens,
        // so that less gas is wasted when the UserOp fails.
        if (paymentAmount != 0) {
            if (TokenTransferLib.balanceOf(u.paymentToken, payer) < paymentAmount) {
                err = PaymentError.selector;
            }
        }

        bool selfCallSuccess;
        // We'll use assembly for frequently used call related stuff to save massive memory gas.
        assembly ("memory-safe") {
            if iszero(err) {
                let m := mload(0x40) // Grab the free memory pointer.
                // Copy the encoded user op to the memory to be ready to pass to the self call.
                calldatacopy(add(m, 0x40), encodedUserOp.offset, encodedUserOp.length)
                mstore(m, 0x00000000) // `selfCallPayVerifyCall537021665()`.
                // The word after the function selector contains the simulation flags.
                // If `flags & 1 != 0`, it means it's a gas simulation.
                mstore(add(m, 0x20), shr(254, combinedGasOverride))
                mstore(0x00, 0) // Zeroize the return slot.

                // To prevent griefing, we need to do a non-reverting gas-limited self call.
                // If the self call is successful, we know that the payment has been made,
                // and the sequence for `nonce` has been incremented.
                // For more information, see `selfCallPayVerifyCall537021665()`.
                selfCallSuccess :=
                    call(g, address(), 0, add(m, 0x1c), add(encodedUserOp.length, 0x44), 0x00, 0x20)
                err := mload(0x00) // The self call will do another self call to execute.
                // Set `err` to `VerifiedCallError()` if `selfCallSuccess` is false and `err` is zero.
                if iszero(selfCallSuccess) { if iszero(err) { err := shl(224, 0xad4db224) } }
            }
        }

        emit UserOpExecuted(u.eoa, u.nonce, selfCallSuccess, err);

        if (LibBit.and(selfCallSuccess, paymentAmount != 0)) {
            // Refund strategy:
            // `totalAmountOfGasToPayFor = gasUsedThusFar + _REFUND_GAS`.
            // `paymentAmountForGas = paymentPerGas * totalAmountOfGasToPayFor`.
            // If we have overpaid, then refund `paymentAmount - paymentAmountForGas`.

            gUsed = Math.rawSub(gStart, gasleft());
            uint256 paymentPerGas = Math.coalesce(u.paymentPerGas, type(uint256).max);
            uint256 finalPaymentAmount = Math.min(
                paymentAmount,
                Math.saturatingMul(paymentPerGas, Math.saturatingAdd(gUsed, _REFUND_GAS))
            );
            address paymentRecipient = Math.coalesce(u.paymentRecipient, address(this));
            if (LibBit.and(finalPaymentAmount != 0, paymentRecipient != address(this))) {
                TokenTransferLib.safeTransfer(u.paymentToken, paymentRecipient, finalPaymentAmount);
            }
            if (paymentAmount > finalPaymentAmount) {
                TokenTransferLib.safeTransfer(
                    u.paymentToken, payer, Math.rawSub(paymentAmount, finalPaymentAmount)
                );
            }
        }
    }

    /// @dev This function is only intended for self-call.
    /// The name is mined to give a function selector of `0x00000000`, which makes it
    /// more efficient to call by placing it at the leftmost part of the function dispatch tree.
    ///
    /// We perform a gas-limited self-call to this function via `_execute(bytes,uint256)`
    /// with assembly for the following reasons:
    /// - Allow recovery from out-of-gas errors.
    ///   When a transaction is actually mined, an `executionData` payload that takes 100k gas
    ///   to execute during simulation might require 1M gas to actually execute
    ///   (e.g. a sale contract that auto-distributes tokens at the very last sale).
    ///   If we do simply let this consume all gas, then the relayer's compensation
    ///   which is determined to be sufficient during simulation might not be actually sufficient.
    ///   We can only know how much gas a payload costs by actually executing it, but once it
    ///   has been executed, the gas burned cannot be returned and will be debited from the relayer.
    /// - Avoid the overheads of `abi.encode`, `abi.decode`, and memory allocation.
    ///   Doing `(bool success, bytes memory result) = address(this).call(abi.encodeCall(...))`
    ///   incurs unnecessary ABI encoding, decoding, and memory allocation.
    ///   Quadratic memory expansion costs will make UserOps in later parts of a batch
    ///   unfairly punished, while making gas estimates unreliable.
    /// - For even more efficiency, we directly rip the UserOp from the calldata instead
    ///   of making it as an argument to this function.
    ///
    /// This function reverts if the PREP initialization or the UserOp validation fails.
    /// This is to prevent incorrect compensation (the UserOp's signature defines what is correct).
    function selfCallPayVerifyCall537021665() public payable {
        require(msg.sender == address(this));

        UserOp calldata u;
        uint256 simulationFlags;
        assembly ("memory-safe") {
            u := add(0x24, calldataload(0x24))
            simulationFlags := calldataload(0x04)
        }
        address eoa = u.eoa;
        // Verify the nonce, early reverting to save gas.
        (LibStorage.Ref storage seqRef, uint256 seq) =
            LibNonce.check(_getEntryPointStorage().nonceSeqs[eoa], u.nonce);

        // The chicken and egg problem:
        // A off-chain simulation of a successful UserOp may not guarantee on-chain success.
        // The state may change in the window between simulation and actual on-chain execution.
        // If on-chain execution fails, gas that has already been burned cannot be returned
        // and will be debited from the relayer.
        // Yet, we still need to minimally check that the UserOp has a valid signature to draw
        // compensation. If we draw compensation first and then realize that the signature is
        // invalid, we will need to refund the compensation, which is more inefficient than
        // simply ensuring validity of the signature before drawing compensation.
        // The best we can do is to minimize the chance that an UserOp success in off-chain
        // simulation can somehow result in an uncompensated on-chain failure.
        // This is why ERC4337 has all those weird storage and opcode restrictions for
        // simulation, and suggests banning users that intentionally grief the simulation.

        // If `initializePREP` fails, just revert.
        // Off-chain simulation can ensure that the eoa is indeed a PREP address.
        // If the eoa is a PREP address, this means the delegation cannot be altered
        // while the UserOp is in-flight, which means off-chain simulation success
        // guarantees on-chain execution success.
        if (u.initData.length != 0) {
            bytes calldata initData = u.initData;
            assembly ("memory-safe") {
                let m := mload(0x40)
                mstore(m, 0x36745d10) // `initializePREP(bytes)`.
                mstore(add(m, 0x20), 0x20)
                mstore(add(m, 0x40), initData.length)
                calldatacopy(add(m, 0x60), initData.offset, initData.length)
                let success :=
                    call(gas(), eoa, 0, add(m, 0x1c), add(0x64, initData.length), m, 0x20)
                if iszero(and(eq(mload(m), 1), success)) {
                    // If this is a simulation via `simulateFailed`, bubble up the whole revert.
                    if and(simulationFlags, 2) {
                        returndatacopy(mload(0x40), 0x00, returndatasize())
                        revert(mload(0x40), returndatasize())
                    }
                    revert(0x00, 0x20)
                }
            }
        }

        // If `_verify` is invalid, just revert.
        // The verification gas is determined by `executionData` and the delegation logic.
        // Off-chain simulation of `_verify` should suffice, provided that the eoa's
        // delegation is not changed, and the `keyHash` is not revoked
        // in the window between off-chain simulation and on-chain execution.
        (bool isValid, bytes32 keyHash) = _verify(u);
        if (!isValid) if (simulationFlags & 1 == 0) revert VerificationError();

        // If `_pay` fails, just revert.
        // Off-chain simulation of `_pay` should suffice,
        // provided that the token balance does not decrease in the window between
        // off-chain simulation and on-chain execution.
        if (u.paymentAmount != 0) _pay(u);

        // Once the payment has been made, the nonce must be invalidated.
        // Otherwise, an attacker can keep replaying the UserOp to take payment and drain the user.
        // EntryPoint UserOp nonce bookkeeping is stored on the EntryPoint itself
        // to make implementing this nonce-invalidation pattern more performant.
        seqRef.value = Math.rawAdd(seq, 1);

        // This re-encodes the ERC7579 `executionData` with the optional `opData`.
        // We expect that the delegation supports ERC7821
        // (an extension of ERC7579 tailored for 7702 accounts).
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            hex"01000000000078210001", // ERC7821 batch execution mode.
            u.executionData,
            abi.encode(keyHash) // `opData`.
        );
        assembly ("memory-safe") {
            mstore(0x00, 0) // Zeroize the return slot.
            if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x20)) {
                // If this is a simulation via `simulateFailed`, bubble up the whole revert.
                if and(simulationFlags, 2) {
                    returndatacopy(mload(0x40), 0x00, returndatasize())
                    revert(mload(0x40), returndatasize())
                }
                if iszero(mload(0x00)) { mstore(0x00, shl(224, 0x6c9d47e8)) } // `CallError()`.
                return(0x00, 0x20) // Return the `err`.
            }
            return(0x60, 0x20) // If all success, returns with zero `err`.
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Nonces
    ////////////////////////////////////////////////////////////////////////

    /// @dev Return current nonce with sequence key.
    function getNonce(address eoa, uint192 seqKey) public view virtual returns (uint256) {
        return LibNonce.get(_getEntryPointStorage().nonceSeqs[eoa], seqKey);
    }

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to (inclusive) `uint64(nonce)`.
    function invalidateNonce(uint256 nonce) public virtual {
        LibNonce.invalidate(_getEntryPointStorage().nonceSeqs[msg.sender], nonce);
        emit NonceInvalidated(msg.sender, nonce);
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7683
    ////////////////////////////////////////////////////////////////////////

    /// @dev ERC7683 fill.
    /// If you don't need to ensure that the `orderId` can only be used once,
    /// pass in `bytes32(0)` for the `orderId`. The `originData` will
    /// already include the nonce for the delegated `eoa`.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata)
        public
        payable
        virtual
        returns (bytes4)
    {
        if (orderId != bytes32(0)) {
            if (!_getEntryPointStorage().filledOrderIds.toggle(uint256(orderId))) {
                revert OrderAlreadyFilled();
            }
        }
        // Like `abi.decode(originData, (bytes, address, uint256))`, but way faster.
        if (originData.length < 0x60) revert();
        bytes calldata encodedUserOp = LibBytes.bytesInCalldata(originData, 0x00);
        address fundingToken = address(uint160(uint256(LibBytes.loadCalldata(originData, 0x20))));
        uint256 fundingAmount = uint256(LibBytes.loadCalldata(originData, 0x40));

        // Like `abi.decode(encodedUserOp, (UserOp)).eoa`, but way faster.
        bytes calldata u = LibBytes.dynamicStructInCalldata(encodedUserOp, 0x00);
        address eoa = address(uint160(uint256(LibBytes.loadCalldata(u, 0x00))));

        TokenTransferLib.safeTransferFrom(fundingToken, msg.sender, eoa, fundingAmount);
        return execute(encodedUserOp);
    }

    /// @dev Returns true if the order ID has been filled.
    function orderIdIsFilled(bytes32 orderId) public view virtual returns (bool) {
        if (orderId == bytes32(0)) return false;
        return _getEntryPointStorage().filledOrderIds.get(uint256(orderId));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Makes the `eoa` perform a payment to the `entryPoint`.
    /// This reverts if the payment is insufficient or fails. Otherwise returns nothing.
    function _pay(UserOp calldata u) internal virtual {
        uint256 paymentAmount = u.paymentAmount;
        address paymentToken = u.paymentToken;
        uint256 requiredBalanceAfter = Math.saturatingAdd(
            TokenTransferLib.balanceOf(paymentToken, address(this)), paymentAmount
        );
        address eoa = u.eoa;
        address payer = Math.coalesce(u.payer, eoa);
        if (paymentAmount > u.paymentMaxAmount) {
            revert PaymentError();
        }
        assembly ("memory-safe") {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(m, 0x56298c98) // `compensate(address,address,uint256,address)`.
            mstore(add(m, 0x20), shr(96, shl(96, paymentToken)))
            mstore(add(m, 0x40), address())
            mstore(add(m, 0x60), paymentAmount)
            mstore(add(m, 0x80), shr(96, shl(96, eoa)))
            // Copy the entire `encodedUserOp` to the end of the calldata, in case `payer` needs
            // bespoke logic to validate the payment.
            // The UserOp can be retrieved via assembly: `userOp := add(0x84, calldataload(0x84))`.
            // This pattern is extremely efficient, as it avoids unnecessary decoding of UserOp args.
            // It is also extremely flexible, allowing multiple variants of UserOps to be supported.
            // Additionally, `encodedUserOp` can be abused to add additional data, e.g.:
            // `encodedUserOp = abi.encode(userOp, someCustomStructForThePayer)`.
            let n := sub(calldatasize(), 0x04)
            calldatacopy(add(m, 0xa0), 0x04, n)
            pop(call(gas(), payer, 0, add(m, 0x1c), add(0x84, n), 0x00, 0x00))
        }
        if (TokenTransferLib.balanceOf(paymentToken, address(this)) < requiredBalanceAfter) {
            revert PaymentError();
        }
    }

    /// @dev Calls `unwrapAndValidateSignature` on the `eoa`.
    function _verify(UserOp calldata u)
        internal
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        bytes calldata sig = u.signature;
        address eoa = u.eoa;
        // While it is technically safe for the digest to be computed on the delegation,
        // we do it on the EntryPoint for efficiency and maintainability. Validating the
        // a single bytes32 digest avoids having to pass in the entire UserOp. Additionally,
        // the delegation does not need to know anything about the UserOp structure.
        bytes32 digest = _computeDigest(u);
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0x0cef73b4) // `unwrapAndValidateSignature(bytes32,bytes)`.
            mstore(add(m, 0x20), digest)
            mstore(add(m, 0x40), 0x40)
            mstore(add(m, 0x60), sig.length)
            calldatacopy(add(m, 0x80), sig.offset, sig.length)
            isValid := staticcall(gas(), eoa, add(m, 0x1c), add(sig.length, 0x64), 0x00, 0x40)
            isValid := and(eq(mload(0x00), 1), and(gt(returndatasize(), 0x3f), isValid))
            keyHash := mload(0x20)
        }
    }

    /// @dev Computes the EIP712 digest for the UserOp.
    /// If the the nonce starts with `MULTICHAIN_NONCE_PREFIX`,
    /// the digest will be computed without the chain ID.
    /// Otherwise, the digest will be computed with the chain ID.
    function _computeDigest(UserOp calldata u) internal view virtual returns (bytes32) {
        bytes32[] calldata pointers = LibERC7579.decodeBatch(u.executionData);
        bytes32[] memory a = EfficientHashLib.malloc(pointers.length);
        unchecked {
            for (uint256 i; i != pointers.length; ++i) {
                (address target, uint256 value, bytes calldata data) = pointers.getExecution(i);
                a.set(
                    i,
                    EfficientHashLib.hash(
                        CALL_TYPEHASH,
                        bytes32(uint256(uint160(target))),
                        bytes32(value),
                        EfficientHashLib.hashCalldata(data)
                    )
                );
            }
        }
        bool isMultichain = u.nonce >> 240 == MULTICHAIN_NONCE_PREFIX;
        // To avoid stack-too-deep. Faster than a regular Solidity array anyways.
        bytes32[] memory f = EfficientHashLib.malloc(10);
        f.set(0, USER_OP_TYPEHASH);
        f.set(1, LibBit.toUint(isMultichain));
        f.set(2, uint160(u.eoa));
        f.set(3, a.hash());
        f.set(4, u.nonce);
        f.set(5, uint160(u.payer));
        f.set(6, uint160(u.paymentToken));
        f.set(7, u.paymentMaxAmount);
        f.set(8, u.paymentPerGas);
        f.set(9, u.combinedGas);

        return isMultichain ? _hashTypedDataSansChainId(f.hash()) : _hashTypedData(f.hash());
    }

    receive() external payable virtual {}

    ////////////////////////////////////////////////////////////////////////
    // Only Owner Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows the entry point owner to withdraw tokens.
    /// If `token` is `address(0)`, withdraws the native gas token.
    function withdrawTokens(address token, address recipient, uint256 amount)
        public
        virtual
        onlyOwner
    {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    ////////////////////////////////////////////////////////////////////////
    // EIP712
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "EntryPoint";
        version = "0.0.1";
    }

    ////////////////////////////////////////////////////////////////////////
    // Other Overrides
    ////////////////////////////////////////////////////////////////////////

    /// @dev There won't be chains that have 7702 and without TSTORE.
    function _useTransientReentrancyGuardOnlyOnMainnet()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return false;
    }
}
