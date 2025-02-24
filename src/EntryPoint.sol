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

/// @title EntryPoint
/// @notice Contract for ERC7702 delegations.
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
        /// `abi.encode(calls)`, where `calls` is an array of type `Call[]`.
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

    /// @dev The function selector is not recognized.
    error FnSelectorNotRecognized();

    /// @dev Out of gas to perform the call operation.
    error InsufficientGas();

    /// @dev The order has already been filled.
    error OrderAlreadyFilled();

    /// @dev For returning the gas used and the error from a simulation.
    error SimulationResult(uint256 gUsed, bytes4 err);

    /// @dev For returning the gas required and the error from a simulation.
    /// `gExecute` is the recommended amount of gas to pass into execute.
    /// `gCombined` is the recommendation for `gasCombined`.
    /// `gUsed` is the amount of gas that has been eaten.
    /// If the `err` is non-zero, it means that the simulation with `gExecute`
    /// has not resulted in a success execution.
    error SimulationResult2(uint256 gExecute, uint256 gCombined, uint256 gUsed, bytes4 err);

    /// @dev The simulate execute 2 run has failed. Try passing in more gas to the simulation.
    error SimulateExecute2Failed();

    /// @dev No revert has been encountered.
    error NoRevertEncoutered();

    /// @dev EOA nonce is not valid.
    error InvalidNonce();

    /// @dev When invalidating a nonce sequence, the new sequence must be larger than the current.
    error NewSequenceMustBeLarger();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev The nonce sequence of `eoa` is incremented.
    event NonceInvalidated(address indexed eoa, uint256 nonce);

    /// @dev Emitted when a UserOp is executed.
    /// This event replaces `NonceInvalidated` in the `execute` function.
    /// It serves to signal that `nonce` has been invalidated,
    /// while also emitting the `err` in a single event.
    event UserOpExecuted(address indexed eoa, uint256 nonce, bytes4 err);

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

    /// @dev For gas estimation.
    uint256 internal constant _INNER_GAS_OVERHEAD = 100000;

    /// @dev Caps the gas stipend for the payment.
    uint256 internal constant _PAYMENT_GAS_CAP = 100000;

    /// @dev The amount of expected gas for refunds.
    uint256 internal constant _REFUND_GAS = 50000;

    /// @dev The storage slot to determine if the simulation should check the amount of gas left.
    uint256 internal constant _COMBINED_GAS_OVERRIDE_SLOT = 0xadfa658cdd8b2da0a825;

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
    /// It simulates an execution and reverts with `SimulationResult2(gExecute, gCombined, gUsed, err)`.
    function simulateExecute2(bytes calldata encodedUserOp) public payable virtual {
        bytes memory data = abi.encodeCall(this.simulateExecute, encodedUserOp);
        uint256 gExecute = gasleft();
        uint256 gCombined;
        uint256 gUsed;
        bytes4 err;
        assembly ("memory-safe") {
            function callSimulateExecute(g_, data_) -> _success {
                calldatacopy(0x00, calldatasize(), 0x40) // Zeroize the memory for the return data.
                pop(call(g_, address(), 0, add(data_, 0x20), mload(data_), 0x00, 0x40))
                _success := eq(shr(224, mload(0x00)), 0xb6013686) // `SimulationResult(uint256,bytes4)`.
            }
            function revertSimulateExecute2Failed() {
                mstore(0x00, 0x0fdb7b86) // `SimulateExecute2Failed()`.
                revert(0x1c, 0x04)
            }

            if iszero(callSimulateExecute(gas(), data)) { revertSimulateExecute2Failed() }
            gUsed := mload(0x04)
            err := mload(0x24)
            // If the UserOp results in a successful execution, let's try to determine
            // the amount of gas that needs to be passed in.
            if iszero(err) {
                // Tell `simulateExecute` that we just want the verification gas.
                sstore(_COMBINED_GAS_OVERRIDE_SLOT, not(0))
                // We need to use a reverting simulation call to measure the verification gas,
                // as it resets warm address and storage access.
                if iszero(callSimulateExecute(gas(), data)) { revertSimulateExecute2Failed() }

                // Heuristic: if the verification gas is > 60k, assume it is P256 verification
                // without the precompile, which has quite a large variance in verification gas.
                // Add 100k (emprically determined) to the `gUsed` to account for the variance.
                for { gCombined := add(gUsed, mul(100000, gt(mload(0x04), 60000))) } 1 {} {
                    gCombined := add(gCombined, shr(4, gCombined)) // Heuristic: multiply by 1.0625.
                    sstore(_COMBINED_GAS_OVERRIDE_SLOT, gCombined)
                    if iszero(callSimulateExecute(gas(), data)) { revertSimulateExecute2Failed() }
                    if iszero(mload(0x24)) { break }
                }
                // Tell `_execute` to early return, as we just want to test the 63/64 rule.
                sstore(_COMBINED_GAS_OVERRIDE_SLOT, or(shl(96, address()), gCombined))
                for { gExecute := gCombined } 1 {} {
                    gExecute := add(gExecute, shr(5, gExecute)) // Heuristic: multiply by 1.03125.
                    if callSimulateExecute(gExecute, data) { if iszero(mload(0x24)) { break } }
                }
                // Add a bit of buffer to account for the variations in
                // function dispatch between `execute` and `simulateExecute`.
                gExecute := add(gExecute, 500)
            }
        }
        revert SimulationResult2(gExecute, gCombined, gUsed, err);
    }

    /// @dev This function does not actually execute.
    /// It simulates an execution and reverts with `SimulationResult(gUsed, err)`.
    function simulateExecute(bytes calldata encodedUserOp) public payable virtual {
        uint256 g = LibStorage.ref(_COMBINED_GAS_OVERRIDE_SLOT).value;
        if (g == type(uint256).max) {
            uint256 gVerifyStart = gasleft();
            _verify(_extractUserOp(encodedUserOp));
            revert SimulationResult(Math.rawSub(gVerifyStart, gasleft()), 0);
        }
        (uint256 gUsed, bytes4 err) = _execute(encodedUserOp, g);
        revert SimulationResult(gUsed, err);
    }

    /// @dev This function is provided for debugging purposes.
    function simulateFailedVerifyAndCall(bytes calldata encodedUserOp) public payable virtual {
        UserOp calldata u = _extractUserOp(encodedUserOp);
        (bool isValid, bytes32 keyHash) = _verify(u);
        if (!isValid) revert VerificationError();
        _execute(u, keyHash, true);
        revert NoRevertEncoutered();
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
        uint256 paymentAmount;

        unchecked {
            // Check if there's sufficient gas left for the gas-limited self calls
            // via the 63/64 rule. This is for gas estimation. If the total amount of gas
            // for the whole transaction is insufficient, revert.
            if (((gasleft() * 63) >> 6) < Math.saturatingAdd(g, _INNER_GAS_OVERHEAD)) {
                revert InsufficientGas();
            }
            if (combinedGasOverride >> 96 != 0) return (0, 0);

            // Verify and invalidate the nonce.
            // The nonce will be invalidated even if the UserOp fails.
            // Otherwise, an attacker can keep replaying the UserOp to take payment and drain the user.
            // EntryPoint UserOp nonce bookkeeping is stored on the EntryPoint itself
            // to make implementing this nonce-invalidation pattern more performant.
            uint256 nonce = u.nonce;
            uint256 seq = _getEntryPointStorage().nonceSeqs[u.eoa][uint192(nonce >> 64)].value++;
            if (seq != uint64(nonce)) err = InvalidNonce.selector;
        }

        assembly ("memory-safe") {
            // To prevent griefing, we need to do two non-reverting gas-limited calls.
            // Even if the verify and call fails, which the gas will be burned,
            // the payment has already been made and can't be reverted.

            // We'll use assembly for frequently used call related stuff to save massive memory gas.
            // forgefmt: disable-next-item
            for {} iszero(err) {} {
                let m := mload(0x40) // Grab the free memory pointer.
                // Copy the encoded user op to the memory to be ready to pass to the self call.
                calldatacopy(add(m, 0x20), encodedUserOp.offset, encodedUserOp.length)
                let s := add(m, 0x1c) // Start of the calldata in memory to pass to the self call.
                let n := add(encodedUserOp.length, 0x24) // Length of the calldata to the self call.

                // 1. Pay.
                mstore(m, 0x1a3de5c3) // `_pay()`.
                mstore(0x00, 0) // Zeroize the return slot.
                if iszero(call( // Gas-limited self call.
                    xor(g, mul(xor(g, _PAYMENT_GAS_CAP), lt(_PAYMENT_GAS_CAP, g))), // `min`.
                    address(), 0, s, n, 0x00, 0x20
                )) {
                    err := mload(0x00)
                    if iszero(err) { err := shl(224, 0xabab8fc9) } // `PaymentError()`.
                    break
                }
                // Since the payment is a success, load the returned `paymentAmount`.
                paymentAmount := mload(0x00)

                // 2. Verify and call.
                let gUsedTemp := sub(gStart, gas())
                mstore(m, 0xe235a92a) // `_verifyAndCall()`.
                mstore(0x00, 0) // Zeroize the return slot.
                if iszero(call( // Gas-limited self call.
                    mul(sub(g, gUsedTemp), gt(g, gUsedTemp)), // `saturatingSub`.
                    address(), 0, s, n, 0x00, 0x20
                )) {
                    err := mload(0x00)
                    if iszero(err) { err := shl(224, 0xad4db224) } // `VerifiedCallError()`.
                }
                break
            }
        }

        emit UserOpExecuted(u.eoa, u.nonce, err);

        // Refund strategy:
        // `totalAmountOfGasToPayFor = gasUsedThusFar + _REFUND_GAS`.
        // `paymentAmountForGas = paymentPerGas * totalAmountOfGasToPayFor`.
        // If we have overpaid, then refund `paymentAmount - paymentAmountForGas`.

        gUsed = Math.rawSub(gStart, gasleft());
        uint256 paymentPerGas = Math.coalesce(u.paymentPerGas, type(uint256).max);
        uint256 finalPaymentAmount = Math.min(
            paymentAmount, Math.saturatingMul(paymentPerGas, Math.saturatingAdd(gUsed, _REFUND_GAS))
        );
        address paymentRecipient = Math.coalesce(u.paymentRecipient, address(this));
        if (LibBit.and(finalPaymentAmount != 0, paymentRecipient != address(this))) {
            TokenTransferLib.safeTransfer(u.paymentToken, paymentRecipient, finalPaymentAmount);
        }
        if (paymentAmount > finalPaymentAmount) {
            TokenTransferLib.safeTransfer(
                u.paymentToken,
                Math.coalesce(u.payer, u.eoa),
                Math.rawSub(paymentAmount, finalPaymentAmount)
            );
        }

        // If there is an error, store it.
        // We exclude this from the gas recording, which gives a tiny side benefit of
        // incentivizing relayers to submit UserOps when they are likely to succeed.
        if (err != 0) _getEntryPointStorage().errs[u.eoa][u.nonce] = err;
    }

    ////////////////////////////////////////////////////////////////////////
    // Nonces
    ////////////////////////////////////////////////////////////////////////

    /// @dev Return current nonce with sequence key.
    function getNonce(address eoa, uint192 seqKey) public view virtual returns (uint256) {
        return _getEntryPointStorage().nonceSeqs[eoa][seqKey].value | (uint256(seqKey) << 64);
    }

    /// @dev Returns the current sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// Also returns the err for that nonce.
    /// If `seq > uint64(nonce)`, it means that `nonce` is invalidated.
    /// Otherwise, it means `nonce` might still be able to be used.
    function nonceStatus(address eoa, uint256 nonce)
        public
        view
        virtual
        returns (uint64 seq, bytes4 err)
    {
        LibStorage.Ref storage s = _getEntryPointStorage().nonceSeqs[eoa][uint192(nonce >> 64)];
        seq = uint64(s.value);
        err = _getEntryPointStorage().errs[eoa][nonce];
    }

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to `uint64(nonce)`.
    function invalidateNonce(uint256 nonce) public virtual {
        LibStorage.Ref storage s =
            _getEntryPointStorage().nonceSeqs[msg.sender][uint192(nonce >> 64)];
        if (uint64(nonce) <= s.value) revert NewSequenceMustBeLarger();
        s.value = uint64(nonce);
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

    // Self call functions
    // -------------------
    // For these self call functions, we shall use the `fallback`.
    // This is so that they can be hidden from the public api,
    // and for facilitating unit testing via a mock.
    //
    // All write self call functions must be guarded with a
    // `require(msg.sender == address(this))` in the fallback.

    /// @dev Makes the `eoa` perform a payment to the `entryPoint`.
    /// This reverts if the payment is insufficient or fails. Otherwise returns nothing.
    function _pay(UserOp calldata u) internal virtual returns (uint256 paymentAmount) {
        paymentAmount = u.paymentAmount;
        if (paymentAmount == uint256(0)) return paymentAmount;
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
        bytes32 digest = _computeDigest(u);
        bytes calldata sig = u.signature;
        address eoa = u.eoa;
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

    /// @dev Sends the `executionData` to the `eoa`.
    /// Returns nothing on success.
    /// On failure, bubbles up the revert if required, or reverts with `CallError()`.
    function _execute(UserOp calldata u, bytes32 keyHash, bool bubbleRevert) internal virtual {
        // This re-encodes the ERC7579 `executionData` with the optional `opData`.
        // We expect that the delegation supports ERC7821
        // (an extension of ERC7579 tailored for 7702 accounts).
        bytes memory data = LibERC7579.reencodeBatchAsExecuteCalldata(
            0x0100000000007821000100000000000000000000000000000000000000000000, // ERC7821 batch execution mode.
            u.executionData,
            abi.encode(keyHash) // `opData`.
        );
        address eoa = u.eoa;
        assembly ("memory-safe") {
            if iszero(call(gas(), eoa, 0, add(0x20, data), mload(data), 0x00, 0x00)) {
                let m := mload(0x40)
                if iszero(bubbleRevert) {
                    // If the reverted returndata fits within a single word.
                    if iszero(gt(returndatasize(), 0x20)) {
                        returndatacopy(m, 0x00, returndatasize())
                        // And if it is not `bytes4(0)`, revert it with.
                        if shr(224, mload(m)) { revert(m, returndatasize()) }
                    }
                    // Else, just revert with `CallError()
                    mstore(0x00, 0x6c9d47e8) // `CallError()`.
                    revert(0x1c, 0x04)
                }
                // Otherwise, if `bubbleRevert` is true, bubble up the entire revert,
                // this is for `simulateFailedVerifyAndCall`.
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
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

    ////////////////////////////////////////////////////////////////////////
    // Fallback
    ////////////////////////////////////////////////////////////////////////

    receive() external payable virtual {}

    /// @dev Use the fallback function to implement gas limited verification and execution.
    /// Helps avoid unnecessary calldata decoding.
    fallback() external payable virtual {
        UserOp calldata u;
        assembly ("memory-safe") {
            u := add(0x04, calldataload(0x04))
        }
        uint256 s = uint32(bytes4(msg.sig));
        // `_pay()`.
        if (s == 0x1a3de5c3) {
            require(msg.sender == address(this));
            uint256 paymentAmount = _pay(u);
            assembly ("memory-safe") {
                mstore(0x00, paymentAmount)
                return(0x00, 0x20)
            }
        }
        // `_verifyAndCall()`.
        if (s == 0xe235a92a) {
            require(msg.sender == address(this));
            (bool isValid, bytes32 keyHash) = _verify(u);
            if (!isValid) revert VerificationError();
            _execute(u, keyHash, false);
            return;
        }
        // `_initializeOwner()`.
        if (s == 0xfc90218d) {
            _checkOnlyProxy();
            if (owner() != address(0)) return; // Prevent reinitialization if there's owner.
            address newOwner;
            assembly ("memory-safe") {
                newOwner := calldataload(0x04)
            }
            _initializeOwner(newOwner);
            return;
        }
        revert FnSelectorNotRecognized();
    }

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
