// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibStorage} from "solady/utils/LibStorage.sol";
import {CallContextChecker} from "solady/utils/CallContextChecker.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IIthacaAccount} from "./interfaces/IIthacaAccount.sol";
import {IOrchestrator} from "./interfaces/IOrchestrator.sol";
import {ICommon} from "./interfaces/ICommon.sol";
import {IFunder} from "./interfaces/IFunder.sol";
import {ISettler} from "./interfaces/ISettler.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

/// @title Orchestrator
/// @notice Enables atomic verification, gas compensation and execution across eoas.
/// @dev
/// The Orchestrator allows relayers to submit payloads on one or more eoas,
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
///   This means once an Intent is signed, it is infeasible to
///   alter or rearrange it to force it to fail.

contract Orchestrator is IOrchestrator, EIP712, CallContextChecker, ReentrancyGuardTransient {
    using LibERC7579 for bytes32[];
    using EfficientHashLib for bytes32[];
    using LibBitmap for LibBitmap.Bitmap;

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

    /// @dev The simulate execute run has failed. Try passing in more gas to the simulation.
    error SimulateExecuteFailed();

    /// @dev A PreCall's EOA must be the same as its parent Intent's.
    error InvalidPreCallEOA();

    /// @dev The PreCall cannot be verified to be correct.
    error PreCallVerificationError();

    /// @dev Error calling the sub Intents `executionData`.
    error PreCallError();

    /// @dev The EOA's account implementation is not supported.
    error UnsupportedAccountImplementation();

    /// @dev The simulation has passed.
    error SimulationPassed(uint256 gUsed);

    /// @dev The state override has not happened.
    error StateOverrideError();

    /// @dev The intent has expired.
    error IntentExpired();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev Emitted when an Intent (including PreCalls) is executed.
    /// This event is emitted in the `execute` function.
    /// - `incremented` denotes that `nonce`'s sequence has been incremented to invalidate `nonce`,
    /// - `err` denotes the resultant error selector.
    /// If `incremented` is true and `err` is non-zero, the Intent was successful.
    /// For PreCalls where the nonce is skipped, this event will NOT be emitted..
    event IntentExecuted(address indexed eoa, uint256 indexed nonce, bool incremented, bytes4 err);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant INTENT_TYPEHASH = keccak256(
        "Intent(bool multichain,address eoa,Call[] calls,uint256 nonce,address payer,address paymentToken,uint256 paymentMaxAmount,uint256 combinedGas,bytes[] encodedPreCalls,bytes[] encodedFundTransfers,address settler,uint256 expiry)Call(address to,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for SignedCalls
    bytes32 public constant SIGNED_CALL_TYPEHASH = keccak256(
        "SignedCall(bool multichain,address eoa,Call[] calls,uint256 nonce)Call(address to,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");

    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    /// @dev Nonce prefix to signal that the payload is to be signed with EIP712 without the chain ID.
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

    /// @dev Flag for normal execution mode.
    uint256 internal constant _NORMAL_MODE_FLAG = 0;

    /// @dev Flag for simulation mode.
    uint256 internal constant _SIMULATION_MODE_FLAG = 1;

    ////////////////////////////////////////////////////////////////////////
    // Main
    ////////////////////////////////////////////////////////////////////////

    /// @dev Allows anyone to sweep tokens from the orchestrator.
    /// If `token` is `address(0)`, withdraws the native gas token.
    function withdrawTokens(address token, address recipient, uint256 amount) public virtual {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /// @dev DEPRECATION WARNING: This function will be deprecated in the future.
    /// Allows pre calls to be executed individually, for counterfactual signatures.
    function executePreCalls(address parentEOA, SignedCall[] calldata preCalls) public virtual {
        for (uint256 j; j < preCalls.length; ++j) {
            SignedCall calldata p = preCalls[j];
            address eoa = Math.coalesce(p.eoa, parentEOA);
            uint256 nonce = p.nonce;

            (bool isValid, bytes32 keyHash) = _verify(_computeDigest(p), eoa, p.signature);

            if (!isValid) revert PreCallVerificationError();

            _checkAndIncrementNonce(eoa, nonce);

            // This part is same as `selfCallPayVerifyCall537021665`. We simply inline to save gas.
            bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
                hex"01000000000078210001", // ERC7821 batch execution mode.
                p.executionData,
                abi.encode(keyHash) // `opData`.
            );

            assembly ("memory-safe") {
                mstore(0x00, 0) // Zeroize the return slot.
                if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x20)) {
                    if iszero(mload(0x00)) { mstore(0x00, shl(224, 0x2228d5db)) } // `PreCallError()`.
                    revert(0x00, 0x20) // Revert the `err` (NOT return).
                }
            }

            // Event so that indexers can know that the nonce is used.
            // Reaching here means there's no error in the PreCall.
            emit IntentExecuted(eoa, p.nonce, true, 0); // `incremented = true`, `err = 0`.
        }
    }

    /// @dev Executes a single encoded intent.
    /// `encodedIntent` is given by `abi.encode(intent)`, where `intent` is a struct of type `Intent`.
    /// If sufficient gas is provided, returns an error selector that is non-zero
    /// if there is an error during the payment, verification, and call execution.
    function execute(bytes calldata encodedIntent)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4 err)
    {
        (, err) = _execute(encodedIntent, 0, _NORMAL_MODE_FLAG);
    }

    /// @dev Executes the array of encoded intents.
    /// Each element in `encodedIntents` is given by `abi.encode(intent)`,
    /// where `intent` is a struct of type `Intent`.
    function execute(bytes[] calldata encodedIntents)
        public
        payable
        virtual
        nonReentrant
        returns (bytes4[] memory errs)
    {
        // This allocation and loop was initially in assembly, but I've normified it for now.
        errs = new bytes4[](encodedIntents.length);
        for (uint256 i; i < encodedIntents.length; ++i) {
            // We reluctantly use regular Solidity to access `encodedIntents[i]`.
            // This generates an unnecessary check for `i < encodedIntents.length`, but helps
            // generate all the implicit calldata bound checks on `encodedIntents[i]`.
            (, errs[i]) = _execute(encodedIntents[i], 0, _NORMAL_MODE_FLAG);
        }
    }

    /// @dev Minimal function, to allow hooking into the _execute function with the simulation flags set to true.
    /// When flags is set to true, all errors are bubbled up. Also signature verification always returns true.
    /// But the codepaths for signature verification are still hit, for correct gas measurement.
    /// @dev If `isStateOverride` is false, then this function will always revert. If the simulation is successful, then it reverts with `SimulationPassed` error.
    /// If `isStateOverride` is true, then this function will not revert if the simulation is successful.
    /// But the balance of tx.origin has to be greater than or equal to type(uint192).max, to prove that a state override has been made offchain,
    /// and this is not an onchain call. This mode has been added so that receipt logs can be generated for `eth_simulateV1`
    /// @return gasUsed The amount of gas used by the execution. (Only returned if `isStateOverride` is true)
    function simulateExecute(
        bool isStateOverride,
        uint256 combinedGasOverride,
        bytes calldata encodedIntent
    ) external payable returns (uint256) {
        // If Simulation Fails, then it will revert here.
        (uint256 gUsed, bytes4 err) =
            _execute(encodedIntent, combinedGasOverride, _SIMULATION_MODE_FLAG);

        if (err != 0) {
            assembly ("memory-safe") {
                mstore(0x00, err)
                revert(0x00, 0x20)
            }
        }

        if (isStateOverride) {
            if (tx.origin.balance >= type(uint192).max) {
                return gUsed;
            } else {
                revert StateOverrideError();
            }
        } else {
            // If Simulation Passes, then it will revert here.
            revert SimulationPassed(gUsed);
        }
    }

    /// @dev Extracts the Intent from the calldata bytes, with minimal checks.
    function _extractIntent(bytes calldata encodedIntent)
        internal
        view
        virtual
        returns (Intent calldata i)
    {
        // This function does NOT allocate memory to avoid quadratic memory expansion costs.
        // Otherwise, it will be unfair to the Intents at the back of the batch.

        // `dynamicStructInCalldata` internally performs out-of-bounds checks.
        bytes calldata intentCalldata = LibBytes.dynamicStructInCalldata(encodedIntent, 0x00);
        assembly ("memory-safe") {
            i := intentCalldata.offset
        }
        // These checks are included for more safety: Swiss Cheese Model.
        // Ensures that all the dynamic children in `encodedIntent` are contained.
        LibBytes.checkInCalldata(i.executionData, intentCalldata);
        LibBytes.checkInCalldata(i.encodedPreCalls, intentCalldata);
        LibBytes.checkInCalldata(i.encodedFundTransfers, intentCalldata);
        LibBytes.checkInCalldata(i.funderSignature, intentCalldata);
        LibBytes.checkInCalldata(i.settlerContext, intentCalldata);
        LibBytes.checkInCalldata(i.signature, intentCalldata);
        LibBytes.checkInCalldata(i.paymentSignature, intentCalldata);
    }
    /// @dev Extracts the PreCall from the calldata bytes, with minimal checks.

    function _extractPreCall(bytes calldata encodedPreCall)
        internal
        virtual
        returns (SignedCall calldata p)
    {
        assembly ("memory-safe") {
            // We can skip the offset checks here, since precalls are only accessed within the verify self-call.
            // By that time, we already know that the intent struct is well formed.
            let t := calldataload(encodedPreCall.offset)
            p := add(t, encodedPreCall.offset)
        }
    }

    /// @dev Executes a single encoded intent.
    /// @dev If flags is non-zero, then all errors are bubbled up.
    /// Currently there can only be 2 modes - simulation mode, and execution mode.
    /// But we use a uint256 for efficient stack operations, and more flexiblity in the future.
    /// Note: We keep the flags in the stack/memory (TSTORE doesn't work) to make sure they are reset in each new call context,
    /// to provide protection against attacks which could spoof the execute function to believe it is in simulation mode.
    function _execute(bytes calldata encodedIntent, uint256 combinedGasOverride, uint256 flags)
        internal
        virtual
        returns (uint256 gUsed, bytes4 err)
    {
        Intent calldata i = _extractIntent(encodedIntent);

        uint256 g = Math.coalesce(uint96(combinedGasOverride), i.combinedGas);
        uint256 gStart = gasleft();

        if (i.paymentAmount > i.paymentMaxAmount) {
            err = PaymentError.selector;

            if (flags == _SIMULATION_MODE_FLAG) {
                revert PaymentError();
            }
        }

        unchecked {
            // Check if there's sufficient gas left for the gas-limited self calls
            // via the 63/64 rule. This is for gas estimation. If the total amount of gas
            // for the whole transaction is insufficient, revert.
            if (((gasleft() * 63) >> 6) < Math.saturatingAdd(g, _INNER_GAS_OVERHEAD)) {
                if (flags != _SIMULATION_MODE_FLAG) {
                    revert InsufficientGas();
                }
            }
        }

        if (i.supportedAccountImplementation != address(0)) {
            if (accountImplementationOf(i.eoa) != i.supportedAccountImplementation) {
                err = UnsupportedAccountImplementation.selector;
                if (flags == _SIMULATION_MODE_FLAG) {
                    revert UnsupportedAccountImplementation();
                }
            }
        }

        address payer = Math.coalesce(i.payer, i.eoa);

        // Early skip the entire pay-verify-call workflow if the payer lacks tokens,
        // so that less gas is wasted when the Intent fails.
        // For multi chain mode, we skip this check, as the funding happens inside the self call.
        if (!i.isMultichain && LibBit.and(i.paymentAmount != 0, err == 0)) {
            if (TokenTransferLib.balanceOf(i.paymentToken, payer) < i.paymentAmount) {
                err = PaymentError.selector;

                if (flags == _SIMULATION_MODE_FLAG) {
                    revert PaymentError();
                }
            }
        }

        bool selfCallSuccess;
        // We'll use assembly for frequently used call related stuff to save massive memory gas.
        assembly ("memory-safe") {
            let m := mload(0x40) // Grab the free memory pointer.
            if iszero(err) {
                // Copy the encoded user op to the memory to be ready to pass to the self call.
                calldatacopy(add(m, 0x40), encodedIntent.offset, encodedIntent.length)
                mstore(m, 0x00000000) // `selfCallPayVerifyCall537021665()`.
                // The word after the function selector contains the simulation flags.
                mstore(add(m, 0x20), flags)
                mstore(0x00, 0) // Zeroize the return slot.

                // To prevent griefing, we need to do a non-reverting gas-limited self call.
                // If the self call is successful, we know that the payment has been made,
                // and the sequence for `nonce` has been incremented.
                // For more information, see `selfCallPayVerifyCall537021665()`.
                selfCallSuccess := call(
                    g,
                    address(),
                    0,
                    add(m, 0x1c),
                    add(encodedIntent.length, 0x24),
                    0x00,
                    0x20
                )
                err := mload(0x00) // The self call will do another self call to execute.

                if iszero(selfCallSuccess) {
                    // If it is a simulation, we simply revert with the full error.
                    if eq(flags, _SIMULATION_MODE_FLAG) {
                        returndatacopy(mload(0x40), 0x00, returndatasize())
                        revert(mload(0x40), returndatasize())
                    }

                    // If we don't get an error selector, then we set this one.
                    if iszero(err) { err := shl(224, 0xad4db224) } // `VerifiedCallError()`.
                }
            }
        }

        emit IntentExecuted(i.eoa, i.nonce, selfCallSuccess, err);
        if (selfCallSuccess) {
            gUsed = Math.rawSub(gStart, gasleft());
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
    ///   Quadratic memory expansion costs will make Intents in later parts of a batch
    ///   unfairly punished, while making gas estimates unreliable.
    /// - For even more efficiency, we directly rip the Intent from the calldata instead
    ///   of making it as an argument to this function.
    ///
    /// This function reverts if the PREP initialization or the Intent validation fails.
    /// This is to prevent incorrect compensation (the Intent's signature defines what is correct).
    function selfCallPayVerifyCall537021665() public payable {
        require(msg.sender == address(this));

        Intent calldata i;
        uint256 flags;
        assembly ("memory-safe") {
            i := add(0x24, calldataload(0x24))
            flags := calldataload(0x04)
        }

        // Check if intent has expired (only if expiry is set)
        // If expiry timestamp is set to 0, then expiry is considered to be infinite.
        if (i.expiry != 0 && block.timestamp > i.expiry) {
            revert IntentExpired();
        }

        address eoa = i.eoa;
        uint256 nonce = i.nonce;
        bytes32 digest = _computeDigest(i);

        _fund(eoa, i.funder, digest, i.encodedFundTransfers, i.funderSignature);

        // The chicken and egg problem:
        // A off-chain simulation of a successful Intent may not guarantee on-chain success.
        // The state may change in the window between simulation and actual on-chain execution.
        // If on-chain execution fails, gas that has already been burned cannot be returned
        // and will be debited from the relayer.
        // Yet, we still need to minimally check that the Intent has a valid signature to draw
        // compensation. If we draw compensation first and then realize that the signature is
        // invalid, we will need to refund the compensation, which is more inefficient than
        // simply ensuring validity of the signature before drawing compensation.
        // The best we can do is to minimize the chance that an Intent success in off-chain
        // simulation can somehow result in an uncompensated on-chain failure.
        // This is why ERC4337 has all those weird storage and opcode restrictions for
        // simulation, and suggests banning users that intentionally grief the simulation.

        // Handle the sub Intents after initialize (if any), and before the `_verify`.
        if (i.encodedPreCalls.length != 0) _handlePreCalls(eoa, i.payer, flags, i.encodedPreCalls);

        // If `_verify` is invalid, just revert.
        // The verification gas is determined by `executionData` and the account logic.
        // Off-chain simulation of `_verify` should suffice, provided that the eoa's
        // account is not changed, and the `keyHash` is not revoked
        // in the window between off-chain simulation and on-chain execution.

        bool isValid;
        bytes32 keyHash;
        if (i.isMultichain) {
            // For multi chain intents, we have to verify using merkle sigs.
            (isValid, keyHash) = _verifyMerkleSig(digest, eoa, i.signature);

            // If this is an output intent, then send the digest as the settlementId
            // on all input chains.
            if (i.encodedFundTransfers.length > 0) {
                // Output intent
                ISettler(i.settler).send(digest, i.settlerContext);
            }
        } else {
            (isValid, keyHash) = _verify(digest, eoa, i.signature);
        }

        if (flags == _SIMULATION_MODE_FLAG) {
            isValid = true;
        }

        if (!isValid) revert VerificationError();

        _checkAndIncrementNonce(eoa, nonce);

        // Payment
        // If `_pay` fails, just revert.
        // Off-chain simulation of `_pay` should suffice,
        // provided that the token balance does not decrease in the window between
        // off-chain simulation and on-chain execution.
        if (i.paymentAmount != 0) _pay(keyHash, digest, i);

        // This re-encodes the ERC7579 `executionData` with the optional `opData`.
        // We expect that the account supports ERC7821
        // (an extension of ERC7579 tailored for 7702 accounts).
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            hex"01000000000078210001", // ERC7821 batch execution mode.
            i.executionData,
            abi.encode(keyHash) // `opData`.
        );

        assembly ("memory-safe") {
            mstore(0x00, 0) // Zeroize the return slot.
            if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x20)) {
                if eq(flags, _SIMULATION_MODE_FLAG) {
                    returndatacopy(mload(0x40), 0x00, returndatasize())
                    revert(mload(0x40), returndatasize())
                }
                if iszero(mload(0x00)) { mstore(0x00, shl(224, 0x6c9d47e8)) } // `CallError()`.
                return(0x00, 0x20)
            }
        }
    }

    /// @dev Loops over the `encodedPreCalls` and does the following for each:
    /// - If the `eoa == address(0)`, it will be coalesced to `parentEOA`.
    /// - Check if `eoa == parentEOA`.
    /// - Validate the signature.
    /// - Check and increment the nonce.
    /// - Call the Account with `executionData`, using the ERC7821 batch-execution mode.
    ///   If the call fails, revert.
    /// - Emit an {IntentExecuted} event.
    function _handlePreCalls(
        address parentEOA,
        address payer,
        uint256 flags,
        bytes[] calldata encodedPreCalls
    ) internal virtual {
        for (uint256 j; j < encodedPreCalls.length; ++j) {
            SignedCall calldata p = _extractPreCall(encodedPreCalls[j]);
            address eoa = Math.coalesce(p.eoa, parentEOA);
            uint256 nonce = p.nonce;

            if (eoa != parentEOA && eoa != payer) revert InvalidPreCallEOA();

            (bool isValid, bytes32 keyHash) = _verify(_computeDigest(p), eoa, p.signature);

            if (flags == _SIMULATION_MODE_FLAG) {
                isValid = true;
            }
            if (!isValid) revert PreCallVerificationError();

            _checkAndIncrementNonce(eoa, nonce);

            // This part is same as `selfCallPayVerifyCall537021665`. We simply inline to save gas.
            bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
                hex"01000000000078210001", // ERC7821 batch execution mode.
                p.executionData,
                abi.encode(keyHash) // `opData`.
            );

            assembly ("memory-safe") {
                mstore(0x00, 0) // Zeroize the return slot.
                if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x20)) {
                    // If this is a simulation via `simulateFailed`, bubble up the whole revert.
                    if eq(flags, _SIMULATION_MODE_FLAG) {
                        returndatacopy(mload(0x40), 0x00, returndatasize())
                        revert(mload(0x40), returndatasize())
                    }
                    if iszero(mload(0x00)) { mstore(0x00, shl(224, 0x2228d5db)) } // `PreCallError()`.
                    revert(0x00, 0x20) // Revert the `err` (NOT return).
                }
            }

            // Event so that indexers can know that the nonce is used.
            // Reaching here means there's no error in the PreCall.
            emit IntentExecuted(eoa, p.nonce, true, 0); // `incremented = true`, `err = 0`.
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Account Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the implementation of the EOA.
    /// If the EOA's account's is not valid EIP7702Proxy (via bytecode check), returns `address(0)`.
    /// This function is provided as a public helper for easier integration.
    function accountImplementationOf(address eoa) public view virtual returns (address result) {
        (, result) = LibEIP7702.delegationAndImplementationOf(eoa);
    }

    ////////////////////////////////////////////////////////////////////////
    // Multi Chain Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Verifies the merkle sig for the multi chain intents.
    /// - Note: Each leaf of the merkle tree should be a standard intent digest, computed with chainId.
    /// - Leaf intents do NOT need to have the multichain nonce prefix.
    /// - The signature for multi chain intents using merkle verification is encoded as:
    /// - bytes signature = abi.encode(bytes32[] memory proof, bytes32 root, bytes memory rootSig)
    function _verifyMerkleSig(bytes32 digest, address eoa, bytes memory signature)
        internal
        view
        returns (bool isValid, bytes32 keyHash)
    {
        (bytes32[] memory proof, bytes32 root, bytes memory rootSig) =
            abi.decode(signature, (bytes32[], bytes32, bytes));

        if (MerkleProofLib.verify(proof, root, digest)) {
            (isValid, keyHash) = IIthacaAccount(eoa).unwrapAndValidateSignature(root, rootSig);

            return (isValid, keyHash);
        }

        return (false, bytes32(0));
    }

    /// @dev Funds the eoa with with the encoded fund transfers, before executing the intent.
    /// - For ERC20 tokens, the funder needs to approve the orchestrator to pull funds.
    /// - For native assets like ETH, the funder needs to transfer the funds to the orchestrator
    ///   before calling execute.
    /// - The funder address should implement the IFunder interface.
    function _fund(
        address eoa,
        address funder,
        bytes32 digest,
        bytes[] memory encodedFundTransfers,
        bytes memory funderSignature
    ) internal virtual {
        // Note: The fund function is mostly only used in the multi chain mode.
        // For single chain intents the encodedFundTransfers field would be empty.
        if (encodedFundTransfers.length == 0) {
            return;
        }

        Transfer[] memory transfers = new Transfer[](encodedFundTransfers.length);

        for (uint256 i; i < encodedFundTransfers.length; ++i) {
            transfers[i] = abi.decode(encodedFundTransfers[i], (Transfer));
        }

        IFunder(funder).fund(digest, transfers, funderSignature);

        uint256 j;

        if (transfers[0].token == address(0)) {
            SafeTransferLib.safeTransferETH(eoa, transfers[0].amount);
            j++;
        }

        for (j; j < transfers.length; ++j) {
            SafeTransferLib.safeTransferFrom(transfers[j].token, funder, eoa, transfers[j].amount);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Makes the `eoa` perform a payment to the `paymentRecipient` directly.
    /// This reverts if the payment is insufficient or fails. Otherwise returns nothing.
    function _pay(bytes32 keyHash, bytes32 digest, Intent calldata i) internal virtual {
        uint256 paymentAmount = i.paymentAmount;
        uint256 requiredBalanceAfter = Math.saturatingAdd(
            TokenTransferLib.balanceOf(i.paymentToken, i.paymentRecipient), paymentAmount
        );

        address payer = Math.coalesce(i.payer, i.eoa);

        // Call the pay function on the account contract
        // Equivalent Solidity code:
        // IIthacaAccount(payer).pay(paymentAmount, keyHash, digest, abi.encode(i));
        // Gas Savings:
        // Saves ~2k gas for normal use cases, by avoiding abi.encode and solidity external call overhead
        assembly ("memory-safe") {
            let m := mload(0x40) // Load the free memory pointer
            mstore(m, 0xf81d87a7) // `pay(uint256,bytes32,bytes32,bytes)`
            mstore(add(m, 0x20), paymentAmount) // Add payment amount as first param
            mstore(add(m, 0x40), keyHash) // Add keyHash as second param
            mstore(add(m, 0x60), digest) // Add digest as third param
            mstore(add(m, 0x80), 0x80) // Add offset of encoded Intent as third param

            let encodedSize := sub(calldatasize(), i)

            mstore(add(m, 0xa0), add(encodedSize, 0x20)) // Store length of encoded Intent at offset.
            mstore(add(m, 0xc0), 0x20) // Offset at which the Intent struct starts in encoded Intent.

            // Copy the intent data to memory
            calldatacopy(add(m, 0xe0), i, encodedSize)

            // We revert here, so that if the payment fails, the execution is also reverted.
            // The revert for payment is caught inside the selfCallPayVerify function.
            if iszero(
                call(
                    gas(), // gas
                    payer, // address
                    0, // value
                    add(m, 0x1c), // input memory offset
                    add(0xc4, encodedSize), // input size
                    0x00, // output memory offset
                    0x20 // output size
                )
            ) { revert(0x00, 0x20) }
        }

        if (TokenTransferLib.balanceOf(i.paymentToken, i.paymentRecipient) < requiredBalanceAfter) {
            revert PaymentError();
        }
    }

    /// @dev Calls `unwrapAndValidateSignature` on the `eoa`.
    function _verify(bytes32 digest, address eoa, bytes calldata sig)
        internal
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        // While it is technically safe for the digest to be computed on the account,
        // we do it on the Orchestrator for efficiency and maintainability. Validating the
        // a single bytes32 digest avoids having to pass in the entire Intent. Additionally,
        // the account does not need to know anything about the Intent structure.
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

    /// @dev calls `checkAndIncrementNonce` on the eoa.
    function _checkAndIncrementNonce(address eoa, uint256 nonce) internal virtual {
        assembly ("memory-safe") {
            mstore(0x00, 0x9e49fbf1) // `checkAndIncrementNonce(uint256)`.
            mstore(0x20, nonce)

            if iszero(call(gas(), eoa, 0, 0x1c, 0x24, 0x00, 0x00)) {
                mstore(0x00, 0x756688fe) // `InvalidNonce()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Computes the EIP712 digest for the PreCall.
    function _computeDigest(SignedCall calldata p) internal view virtual returns (bytes32) {
        bool isMultichain = p.nonce >> 240 == MULTICHAIN_NONCE_PREFIX;
        // To avoid stack-too-deep. Faster than a regular Solidity array anyways.
        bytes32[] memory f = EfficientHashLib.malloc(5);
        f.set(0, SIGNED_CALL_TYPEHASH);
        f.set(1, LibBit.toUint(isMultichain));
        f.set(2, uint160(p.eoa));
        f.set(3, _executionDataHash(p.executionData));
        f.set(4, p.nonce);

        return isMultichain ? _hashTypedDataSansChainId(f.hash()) : _hashTypedData(f.hash());
    }

    /// @dev Computes the EIP712 digest for the Intent.
    /// If the the nonce starts with `MULTICHAIN_NONCE_PREFIX`,
    /// the digest will be computed without the chain ID.
    /// Otherwise, the digest will be computed with the chain ID.
    function _computeDigest(Intent calldata i) internal view virtual returns (bytes32) {
        bool isMultichain = i.nonce >> 240 == MULTICHAIN_NONCE_PREFIX;

        // To avoid stack-too-deep. Faster than a regular Solidity array anyways.
        bytes32[] memory f = EfficientHashLib.malloc(13);
        f.set(0, INTENT_TYPEHASH);
        f.set(1, LibBit.toUint(isMultichain));
        f.set(2, uint160(i.eoa));
        f.set(3, _executionDataHash(i.executionData));
        f.set(4, i.nonce);
        f.set(5, uint160(i.payer));
        f.set(6, uint160(i.paymentToken));
        f.set(7, i.paymentMaxAmount);
        f.set(8, i.combinedGas);
        f.set(9, _encodedArrHash(i.encodedPreCalls));
        f.set(10, _encodedArrHash(i.encodedFundTransfers));
        f.set(11, uint160(i.settler));
        f.set(12, i.expiry);

        return isMultichain ? _hashTypedDataSansChainId(f.hash()) : _hashTypedData(f.hash());
    }

    /// @dev Helper function to return the hash of the `execuctionData`.
    function _executionDataHash(bytes calldata executionData)
        internal
        view
        virtual
        returns (bytes32)
    {
        bytes32[] calldata pointers = LibERC7579.decodeBatch(executionData);
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
        return a.hash();
    }

    /// @dev Helper function to return the hash of the `encodedPreCalls`.
    function _encodedArrHash(bytes[] calldata encodedArr) internal view virtual returns (bytes32) {
        bytes32[] memory a = EfficientHashLib.malloc(encodedArr.length);
        for (uint256 i; i < encodedArr.length; ++i) {
            a.set(i, EfficientHashLib.hashCalldata(encodedArr[i]));
        }
        return a.hash();
    }

    receive() external payable virtual {}

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
        name = "Orchestrator";
        version = "0.5.5";
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
