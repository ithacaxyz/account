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

import { Delegation } from "./Delegation.sol";

/// @title SimpleEntryPoint
/// @notice Simplified contract for ERC7702 delegations
contract SimpleEntryPoint is EIP712, Ownable, CallContextChecker, ReentrancyGuardTransient {
    using LibERC7579 for bytes32[];
    using EfficientHashLib for bytes32[];
    using LibBitmap for LibBitmap.Bitmap;

    /*//////////////////////////////////////////////////////////////
                           DATA STRUCTURES
    //////////////////////////////////////////////////////////////*/

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
    struct UserOp {
        /// @dev The user's address.
        address eoa;
        /// @dev An encoded array of calls, using ERC7579 batch execution encoding.
        bytes executionData;
        /// @dev Per delegated EOA nonce
        uint256 nonce;
        /// @dev The account paying the payment token.
        address payer;
        /// @dev The ERC20 or native token used to pay for gas.
        address paymentToken;
        /// @dev The payment recipient for the ERC20 token.
        address paymentRecipient;
        /// @dev The amount of the token to pay.
        uint256 paymentAmount;
        /// @dev The maximum amount of the token to pay.
        uint256 paymentMaxAmount;
        /// @dev The amount of ERC20 to pay per gas spent.
        uint256 paymentPerGas;
        /// @dev The combined gas limit for payment, verification, and calling the EOA.
        uint256 combinedGas;
        /// @dev The wrapped signature.
        bytes signature;
        /// @dev Optional data for `initPREP` on the delegation.
        bytes initData;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

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
    error SimulationResult2(uint256 gExecute, uint256 gCombined, uint256 gUsed, bytes4 err);

    /// @dev The simulate execute 2 run has failed. Try passing in more gas to the simulation.
    error SimulateExecute2Failed();

    /// @dev No revert has been encountered.
    error NoRevertEncoutered();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev The nonce sequence of `eoa` is invalidated up to (inclusive) of `nonce`.
    event NonceInvalidated(address indexed eoa, uint256 nonce);

    /// @dev Emitted when a UserOp is executed.
    event UserOpExecuted(address indexed eoa, uint256 indexed nonce, bool incremented, bytes4 err);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

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
    uint16 public constant MULTICHAIN_NONCE_PREFIX = 0xc1d0;

    /// @dev For gas estimation.
    uint256 internal constant _INNER_GAS_OVERHEAD = 100000;

    /// @dev Caps the gas stipend for the payment.
    uint256 internal constant _PAYMENT_GAS_CAP = 100000;

    /// @dev The amount of expected gas for refunds.
    uint256 internal constant _REFUND_GAS = 50000;

    /// @dev The storage slot to determine if the simulation should check the amount of gas left.
    uint256 internal constant _COMBINED_GAS_OVERRIDE_SLOT = 0xadfa658cdd8b2da0a825;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Holds the storage.
    struct EntryPointStorage {
        /// @dev Mapping of (`eoa`, `seqKey`) to nonce sequence.
        mapping(address => mapping(uint192 => LibStorage.Ref)) nonceSeqs;
        /// @dev Mapping of (`eoa`, `nonce`) to the error selector.
        mapping(address => mapping(uint256 => bytes4)) errs;
        /// @dev A bitmap to mark ERC7683 order IDs as filled, to prevent filling replays.
        LibBitmap.Bitmap filledOrderIds;
    }

    /// @dev Returns the storage pointer.
    function _getEntryPointStorage() internal pure returns (EntryPointStorage storage $) {
        uint256 s = uint72(bytes9(keccak256("PORTO_ENTRY_POINT_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 MAIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Executes a single encoded user operation.
    function execute(bytes calldata encodedUserOp)
        public
        payable
        nonReentrant
        returns (bytes4 err)
    {
        UserOp memory userOp = abi.decode(encodedUserOp, (UserOp));
        (,err) = _executeInternal(userOp, 0);
        return err;
    }

    /// @dev Executes an array of encoded user operations.
    function execute(bytes[] calldata encodedUserOps)
        public
        payable
        nonReentrant
        returns (bytes4[] memory errs)
    {
        errs = new bytes4[](encodedUserOps.length);
        for (uint256 i = 0; i < encodedUserOps.length; ++i) {
            UserOp memory userOp = abi.decode(encodedUserOps[i], (UserOp));
            (, errs[i]) = _executeInternal(userOp, 0);
        }
    }

    /// @dev This function does not actually execute.
    /// It simulates an execution and reverts with gas estimates and error information.
    function simulateExecute2(bytes calldata encodedUserOp) public payable {
        // Used to pass parameters to the simulation
        LibStorage.ref(_COMBINED_GAS_OVERRIDE_SLOT).value = (1 << 254) | 0xffffffffffffffffffffffff;
        
        // First simulation to get gas usage
        (bool success, bytes memory result) = address(this).call(
            abi.encodeCall(this.simulateExecute, encodedUserOp)
        );
        if (!success) revert SimulateExecute2Failed();
        
        bytes4 selector;
        uint256 gUsed;
        bytes4 err;
        
        // Parse simulation result
        assembly {
            selector := mload(add(result, 32))
            gUsed := mload(add(result, 36))
            err := mload(add(result, 68))
        }
        
        uint256 gExecute;
        uint256 gCombined;
        
        // If successful execution, calculate optimal gas amounts
        if (err == 0) {
            // Simulation for verification gas
            LibStorage.ref(_COMBINED_GAS_OVERRIDE_SLOT).value = type(uint256).max - 1;
            (success, result) = address(this).call(
                abi.encodeCall(this.simulateExecute, encodedUserOp)
            );
            if (!success) revert SimulateExecute2Failed();
            
            // Calculate combined gas with padding for P256 verification if needed
            uint256 verificationGas;
            assembly {
                verificationGas := mload(add(result, 36))
            }
            
            gCombined = gUsed;
            if (verificationGas > 60000) {
                gCombined += 110000; // Add padding for heavy verification
            }
            gCombined += gCombined >> 4; // Add 6.25% buffer
            
            // Find minimal execution gas
            LibStorage.ref(_COMBINED_GAS_OVERRIDE_SLOT).value = (1 << 254) | gCombined;
            for (gExecute = gCombined; ; gExecute += gExecute >> 5) {
                (success, result) = address(this).call{gas: gExecute}(
                    abi.encodeCall(this.simulateExecute, encodedUserOp)
                );
                
                if (success) {
                    assembly {
                        err := mload(add(result, 68))
                    }
                    if (err == 0) break;
                }
            }
            
            gExecute += 500; // Buffer for function dispatch differences
        }
        
        revert SimulationResult2(gExecute, gCombined, gUsed, err);
    }

    /// @dev Simulates execution without actually executing
    function simulateExecute(bytes calldata encodedUserOp) public payable {
        uint256 combinedGasOverride = LibStorage.ref(_COMBINED_GAS_OVERRIDE_SLOT).value;
        
        // Used for verification gas estimation
        if (combinedGasOverride == type(uint256).max) {
            uint256 startGas = gasleft();
            UserOp memory userOpVerify = abi.decode(encodedUserOp, (UserOp));
            _verifyUserOp(userOpVerify);
            uint256 gasUsed = startGas - gasleft();
            revert SimulationResult(gasUsed, 0);
        }
        
        UserOp memory userOpExec = abi.decode(encodedUserOp, (UserOp));
        (uint256 gUsed, bytes4 err) = _executeInternal(userOpExec, combinedGasOverride);
        revert SimulationResult(gUsed, err);
    }

    /// @dev Debug function for failed verification and execution
    function simulateFailedVerifyAndCall(bytes calldata encodedUserOp) public payable {
        UserOp memory userOp = abi.decode(encodedUserOp, (UserOp));
        (bool isValid, bytes32 keyHash) = _verifyUserOp(userOp);
        if (!isValid) revert VerificationError();
        _executeCall(userOp, keyHash);
        revert NoRevertEncoutered();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Core execution logic for a user operation
    function _executeInternal(UserOp memory userOp, uint256 combinedGasOverride) 
        internal
        returns (uint256 gasUsed, bytes4 err)
    {
        uint256 combinedGas = combinedGasOverride == 0 ? userOp.combinedGas : uint96(combinedGasOverride);
        uint256 startGas = gasleft();
        bool success = true;
        
        // Check nonce validity 
        EntryPointStorage storage storage$ = _getEntryPointStorage();
        (LibStorage.Ref storage nonceRef, uint256 seq) = 
            LibNonce.check(storage$.nonceSeqs[userOp.eoa], userOp.nonce);
            
        uint256 paymentAmount = 0;
        
        // Step 1: Initialize PREP if needed
        if (userOp.initData.length > 0) {
            _initializePREP(userOp);
        }
        
        // Step 2: Verify the user operation
        (bool isValid, bytes32 keyHash) = _verifyUserOp(userOp);
        if (!isValid) {
            if ((combinedGasOverride >> 254) & 1 == 0) { // Not simulation mode
                revert VerificationError();
            }
        }
        
        // Step 3: Process payment
        paymentAmount = _processPayment(userOp);
        
        // Step 4: Invalidate nonce
        nonceRef.value = seq + 1;
        
        // Step 5: Execute the call
        _executeCall(userOp, keyHash);
        
        emit UserOpExecuted(userOp.eoa, userOp.nonce, success, err);
        
        // Calculate gas used and process payment
        gasUsed = startGas - gasleft();
        uint256 paymentPerGas = userOp.paymentPerGas == 0 ? type(uint256).max : userOp.paymentPerGas;
        
        uint256 finalPaymentAmount = Math.min(
            paymentAmount,
            Math.saturatingMul(paymentPerGas, Math.saturatingAdd(gasUsed, _REFUND_GAS))
        );
        
        address paymentRecipient = userOp.paymentRecipient == address(0) ? 
            address(this) : userOp.paymentRecipient;
            
        // Transfer payment to recipient if needed
        if (finalPaymentAmount != 0 && paymentRecipient != address(this)) {
            TokenTransferLib.safeTransfer(userOp.paymentToken, paymentRecipient, finalPaymentAmount);
        }
        
        // Refund excess payment
        if (paymentAmount > finalPaymentAmount) {
            address refundRecipient = userOp.payer == address(0) ? userOp.eoa : userOp.payer;
            TokenTransferLib.safeTransfer(
                userOp.paymentToken,
                refundRecipient,
                paymentAmount - finalPaymentAmount
            );
        }
        
        // Store error if there was one
        if (err != 0) {
            storage$.errs[userOp.eoa][userOp.nonce] = err;
        }
        
        return (gasUsed, err);
    }

    /*//////////////////////////////////////////////////////////////
                         USER OPERATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Verifies the user operation signature
    function _verifyUserOp(UserOp memory userOp) 
        internal 
        view 
        returns (bool isValid, bytes32 keyHash) 
    {
        bytes32 digest = _computeDigest(userOp);
        
        // Call unwrapAndValidateSignature on the target EOA
        // Using 0x0cef73b4 selector for "unwrapAndValidateSignature(bytes32,bytes)"
        bytes memory callData = abi.encodeWithSelector(
            0x0cef73b4,
            digest,
            userOp.signature
        );
        
        (bool success, bytes memory returnData) = userOp.eoa.staticcall(callData);
        
        if (success && returnData.length >= 32) {
            isValid = abi.decode(returnData, (bool));
            
            if (isValid && returnData.length >= 64) {
                keyHash = abi.decode(returnData, (bool, bytes32))[1];
            }
        }
        
        return (isValid, keyHash);
    }
    
    /// @dev Process payment for the user operation
    function _processPayment(UserOp memory userOp) internal returns (uint256 paymentAmount) {
        paymentAmount = userOp.paymentAmount;
        if (paymentAmount == 0) return 0;
        
        address paymentToken = userOp.paymentToken;
        uint256 requiredBalanceAfter = TokenTransferLib.balanceOf(paymentToken, address(this)) + paymentAmount;
        
        address payer = userOp.payer == address(0) ? userOp.eoa : userOp.payer;
        
        if (paymentAmount > userOp.paymentMaxAmount) {
            revert PaymentError();
        }
        
        // Call compensate on the payer - using 0x56298c98 selector for "compensate(address,address,uint256,address)"
        bytes memory callData = abi.encodeWithSelector(
            0x56298c98,
            paymentToken,
            address(this),
            paymentAmount,
            userOp.eoa
        );
        
        // We append the encodedUserOp to allow the payer to validate the payment
        bytes memory data = _appendUserOpData(callData, abi.encode(userOp));
        
        (bool success,) = payer.call(data);
        
        // Check that payment was successful
        if (TokenTransferLib.balanceOf(paymentToken, address(this)) < requiredBalanceAfter) {
            revert PaymentError();
        }
        
        return paymentAmount;
    }

    /// @dev Helper function to append UserOp data to calldata
    /// This preserves the pattern from the original implementation where UserOp is appended to calldata
    function _appendUserOpData(bytes memory callData, bytes memory userOpData) internal pure returns (bytes memory) {
        bytes memory result = new bytes(callData.length + userOpData.length);
        
        assembly {
            // Copy callData to result
            let len := mload(callData)
            let src := add(callData, 0x20)
            let dest := add(result, 0x20)
            for { let i := 0 } lt(i, len) { i := add(i, 0x20) } {
                mstore(add(dest, i), mload(add(src, i)))
            }
            
            // Copy userOpData to result after callData
            let userOpLen := mload(userOpData)
            src := add(userOpData, 0x20)
            dest := add(add(result, 0x20), len)
            for { let i := 0 } lt(i, userOpLen) { i := add(i, 0x20) } {
                mstore(add(dest, i), mload(add(src, i)))
            }
            
            // Update result length
            mstore(result, add(len, userOpLen))
        }
        
        return result;
    }

    /// @dev Execute the call to the EOA
    function _executeCall(UserOp memory userOp, bytes32 keyHash) internal {
        // Convert memory to calldata for LibERC7579
        bytes memory mode = hex"0100000000007821000100000000000000000000000000000000000000000000"; // ERC7821 batch execution mode
        bytes memory opData = abi.encode(keyHash);

        // Manual encoding to avoid calldata conversion issues
        bytes memory data = new bytes(4 + 32*3);
        bytes4 selector = bytes4(keccak256("execute(bytes32,bytes,bytes)"));
        
        assembly {
            // Store selector
            mstore(add(data, 32), selector)
            // Store mode
            mstore(add(data, 36), mload(add(mode, 32)))
            // Store executionData pointer
            let executionDataPtr := mload(add(userOp, 64)) // Get pointer to executionData
            mstore(add(data, 68), executionDataPtr)
            // Store opData pointer
            mstore(add(data, 100), mload(add(opData, 32)))
        }
        
        // Call the EOA & revert with the error with the right revert data
        (bool success, bytes memory returnData) = userOp.eoa.call(data);
        if (!success) {
            // bubble up the error with the exact revert message
            assembly {
                let returnDataSize := mload(returnData)
                revert(add(32, returnData), returnDataSize)
            }
        }
    }

    /// @dev Initialize PREP for the user
    function _initializePREP(UserOp memory userOp) internal {
        if (userOp.initData.length == 0) return;
        
        (bool success, bytes memory returnData) = userOp.eoa.call(
            abi.encodeCall(
                this.initializePREP,
                (userOp.initData)
            )
        );
        
        if (!success || returnData.length < 32 || !abi.decode(returnData, (bool))) {
            revert("PREP initialization failed");
        }
    }
    
    /// @dev This is a placeholder function to represent the interface expected for PREP initialization
    /// Not meant to be called directly, only used for function selector generation
    function initializePREP(bytes calldata initData) external returns (bool) {
        revert("Not implemented");
    }

    /// @dev Compute the EIP712 digest for signature verification
    function _computeDigest(UserOp memory userOp) internal view returns (bytes32) {
        // Manually decode the batch to avoid calldata/memory type issues
        uint256 numCalls = 0;
        bytes memory executionData = userOp.executionData;
        
        // First determine the number of calls
        assembly {
            let dataPtr := add(executionData, 32) // Skip length prefix
            numCalls := mload(dataPtr) // First 32 bytes is number of calls
        }
        
        bytes32[] memory callHashes = new bytes32[](numCalls);
        
        // Process each call manually
        for (uint256 i = 0; i < numCalls; i++) {
            address target;
            uint256 value;
            bytes memory data;
            
            // Extract call data at position i
            assembly {
                let dataPtr := add(mload(add(executionData, 32)), 32) // Skip length prefix and numCalls
                let offset := mul(i, 96) // Each call has 3 32-byte fields
                
                // Extract target (address)
                target := and(mload(add(dataPtr, offset)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
                
                // Extract value (uint256)
                value := mload(add(dataPtr, add(offset, 32)))
                
                // Extract data pointer
                let dataOffset := mload(add(dataPtr, add(offset, 64)))
                data := add(executionData, dataOffset)
            }
            
            // Hash the call data
            bytes32 dataHash = keccak256(data);
            
            callHashes[i] = EfficientHashLib.hash(
                CALL_TYPEHASH,
                bytes32(uint256(uint160(target))),
                bytes32(value),
                dataHash
            );
        }
        
        // Check if this is a multichain operation (signed without chain ID)
        bool isMultichain = userOp.nonce >> 240 == MULTICHAIN_NONCE_PREFIX;
        
        // Prepare fields for hashing
        bytes32[] memory fields = new bytes32[](10);
        fields[0] = USER_OP_TYPEHASH;
        fields[1] = bytes32(isMultichain ? 1 : 0);
        fields[2] = bytes32(uint256(uint160(userOp.eoa)));
        fields[3] = EfficientHashLib.hashArray(callHashes);
        fields[4] = bytes32(userOp.nonce);
        fields[5] = bytes32(uint256(uint160(userOp.payer)));
        fields[6] = bytes32(uint256(uint160(userOp.paymentToken)));
        fields[7] = bytes32(userOp.paymentMaxAmount);
        fields[8] = bytes32(userOp.paymentPerGas);
        fields[9] = bytes32(userOp.combinedGas);
        
        bytes32 structHash = EfficientHashLib.hashArray(fields);
        
        // Hash with or without chain ID
        return isMultichain ? 
            _hashTypedDataSansChainId(structHash) : 
            _hashTypedData(structHash);
    }

    /*//////////////////////////////////////////////////////////////
                              NONCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Return current nonce with sequence key.
    function getNonce(address eoa, uint192 seqKey) public view returns (uint256) {
        return LibNonce.get(_getEntryPointStorage().nonceSeqs[eoa], seqKey);
    }

    /// @dev Returns the current sequence for the `seqKey` in nonce and any error
    function nonceStatus(address eoa, uint256 nonce)
        public
        view
        returns (uint64 seq, bytes4 err)
    {
        seq = uint64(getNonce(eoa, uint192(nonce >> 64)));
        err = _getEntryPointStorage().errs[eoa][nonce];
    }

    /// @dev Invalidates nonces for the sender up to and including the given nonce
    function invalidateNonce(uint256 nonce) public {
        LibNonce.invalidate(_getEntryPointStorage().nonceSeqs[msg.sender], nonce);
        emit NonceInvalidated(msg.sender, nonce);
    }

    /*//////////////////////////////////////////////////////////////
                             ERC7683 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev ERC7683 fill.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata)
        public
        payable
        returns (bytes4)
    {
        if (orderId != bytes32(0)) {
            if (!_getEntryPointStorage().filledOrderIds.toggle(uint256(orderId))) {
                revert OrderAlreadyFilled();
            }
        }
        
        // Decode originData
        if (originData.length < 0x60) revert("Invalid originData");
        
        (bytes memory encodedUserOp, address fundingToken, uint256 fundingAmount) = 
            abi.decode(originData, (bytes, address, uint256));
        
        // Extract EOA address from user operation
        UserOp memory userOp = abi.decode(encodedUserOp, (UserOp));
        
        // Transfer funds to the EOA
        TokenTransferLib.safeTransferFrom(fundingToken, msg.sender, userOp.eoa, fundingAmount);
        
        // Execute the operation
        return this.execute(encodedUserOp);
    }

    /// @dev Returns true if the order ID has been filled.
    function orderIdIsFilled(bytes32 orderId) public view returns (bool) {
        if (orderId == bytes32(0)) return false;
        return _getEntryPointStorage().filledOrderIds.get(uint256(orderId));
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Allows the entry point owner to withdraw tokens.
    function withdrawTokens(address token, address recipient, uint256 amount)
        public
        onlyOwner
    {
        TokenTransferLib.safeTransfer(token, recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @dev For EIP712.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "SimpleEntryPoint";
        version = "0.0.1";
    }

    /// @dev Always use transient storage for reentrancy guard
    function _useTransientReentrancyGuardOnlyOnMainnet()
        internal
        view
        virtual
        override
        returns (bool)
    {
        return false;
    }
    
    /// @dev Fallback to receive ETH
    receive() external payable {}
}