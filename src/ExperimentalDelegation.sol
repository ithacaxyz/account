// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Receiver} from "solady/accounts/Receiver.sol";
import {MinimalBatchExecutor} from "solady/accounts/MinimalBatchExecutor.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {P256} from "solady/utils/P256.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";

contract ExperimentalDelegation is Receiver, EIP712, MinimalBatchExecutor {
    using EfficientHashLib for bytes32[];
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using LibBytes for LibBytes.BytesStorage;
    using LibBitmap for LibBitmap.Bitmap;

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    /// @notice The type of key.
    enum KeyType {
        P256,
        WebAuthnP256
    }

    /// @notice A key that can be used to authorize call.
    /// @custom:property expiry - Unix timestamp at which the key expires (0 = never).
    /// @custom:property keyType - Type of key. See the {KeyType} enum.
    /// @custom:property publicKey - Public key in encoded form.
    struct Key {
        uint40 expiry;
        KeyType keyType;
        bytes publicKey;
    }

    // The `opData` in `execute` will be constructed with the following:
    // ```
    // abi.encodePacked(
    //     uint256(nonce),
    //     uint128(maxPriorityFee),
    //     uint128(maxFeePerGas),
    //     uint64(verificationGas),
    //     uint64(callGas),
    //     uint64(preVerificationGas),
    //     uint32(paymasterAndData.length),
    //     bytes(paymasterAndData),
    //     bytes(signature)
    // )
    // ```

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Holds the storage.
    struct ExperimentalDelegationStorage {
        bool initialized;
        LibBytes.BytesStorage label;
        LibBitmap.Bitmap invalidatedNonces;
        uint256 nonceSalt;
        EnumerableSetLib.Bytes32Set keyHashes;
        mapping(bytes32 => LibBytes.BytesStorage) keyStorage;
    }

    /// @notice Returns the storage pointer.
    function _getExperimentalDelegationStorage()
        internal
        pure
        returns (ExperimentalDelegationStorage storage $)
    {
        assembly ("memory-safe") {
            // `uint72(bytes9(keccak256("PORTO_EXPERIMENTAL_DELEGATION_STORAGE")))`.
            $.slot := 0x712df45a4d8ada253b // Truncate to 9 bytes to reduce bytecode size.
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The EOA has already been initialized.
    error AlreadyInitialized();

    /// @notice The key is expired or unauthorized.
    error KeyExpiredOrUnauthorized();

    /// @notice The sender is not the EOA.
    error Unauthorized();

    /// @notice The signature is invalid.
    error InvalidSignature();

    /// @notice The key does not exist.
    error KeyDoesNotExist();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice The label has been updated to `label`.
    event LabelSet(string label);

    /// @notice The key with a corresponding `keyHash` has been authorized.
    event Authorized(bytes32 indexed keyHash, Key key);

    /// @notice The key with a corresponding `keyHash` has been revoked.
    event Revoked(bytes32 indexed keyHash);

    /// @notice The `nonce` have been invalidated.
    event NonceInvalidated(uint256 nonce);

    /// @notice The nonce salt has been incremented to `newNonceSalt`.
    event NonceSaltIncremented(uint256 newNonceSalt);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice For EIP-712 signature digest calculation for the `execute` function.
    /// `keccak256("Call(address target,uint256 value,bytes data)")`.
    bytes32 public constant CALL_TYPEHASH =
        0x84fa2cf05cd88e992eae77e851af68a4ee278dcff6ef504e487a55b3baadfbe5;

    /// @notice For EIP-712 signature digest calculation for the `execute` function.
    /// `keccak256("Execute(Call[] calls,uint256 nonce,uint256 nonceSalt)Call(address target,uint256 value,bytes data)")`.
    bytes32 public constant EXECUTE_TYPEHASH =
        0xe530e62dece51c9bec26701907051ddc8420a62f028096eeb58263193e84e049;

    /// @notice For EIP-712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    ////////////////////////////////////////////////////////////////////////
    // ERC1271
    ////////////////////////////////////////////////////////////////////////

    /// @notice Checks if a signature is valid.
    /// @param digest - The digest to verify.
    /// @param signature - The wrapped signature to verify.
    function isValidSignature(bytes32 digest, bytes calldata signature)
        public
        view
        virtual
        returns (bytes4)
    {
        // `bytes4(keccak256("isValidSignature(bytes32,bytes)")) = 0x1626ba7e`.
        // We use `0xffffffff` for invalid, in convention with the reference implementation.
        return bytes4(_isValidSignature(digest, signature) ? 0x1626ba7e : 0xffffffff);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    // The following functions can only be called by this contract.
    // If a signature is required to call these functions, please use the `execute`
    // function with `auth` set to `abi.encode(nonce, signature)`.

    /// @notice Sets the label.
    function setLabel(string calldata label_) public virtual onlyThis {
        _getExperimentalDelegationStorage().label.set(bytes(label_));
        emit LabelSet(label_);
    }

    /// @notice Revokes the key corresponding to `keyHash`.
    function revoke(bytes32 keyHash) public virtual onlyThis {
        _removeKey(keyHash);
        emit Revoked(keyHash);
    }

    /// @notice Authorizes the key.
    function authorize(Key memory key) public virtual onlyThis returns (bytes32 keyHash) {
        keyHash = _addKey(key);
        emit Authorized(keyHash, key);
    }

    /// @notice Invalidates the nonce.
    function invalidateNonce(uint256 nonce) public virtual onlyThis {
        _getExperimentalDelegationStorage().invalidatedNonces.set(nonce);
        emit NonceInvalidated(nonce);
    }

    /// @notice Increments the nonce salt by a pseudorandom uint32 value.
    function incrementNonceSalt() public virtual onlyThis returns (uint256 newNonceSalt) {
        ExperimentalDelegationStorage storage $ = _getExperimentalDelegationStorage();
        newNonceSalt = $.nonceSalt;
        unchecked {
            newNonceSalt += uint32(uint256(EfficientHashLib.hash(newNonceSalt, block.timestamp)));
        }
        $.nonceSalt = newNonceSalt;
        emit NonceSaltIncremented(newNonceSalt);
    }

    ////////////////////////////////////////////////////////////////////////
    // Public View Functions
    ////////////////////////////////////////////////////////////////////////

    function nonceIsInvalidated(uint256 nonce) public view virtual returns (bool) {
        return _getExperimentalDelegationStorage().invalidatedNonces.get(nonce);
    }

    function label() public view virtual returns (string memory) {
        return string(_getExperimentalDelegationStorage().label.get());
    }

    function nonceSalt() public view virtual returns (uint256) {
        return _getExperimentalDelegationStorage().nonceSalt;
    }

    function keyCount() public view virtual returns (uint256) {
        return _getExperimentalDelegationStorage().keyHashes.length();
    }

    function keyAt(uint256 i) public view virtual returns (Key memory) {
        return getKey(_getExperimentalDelegationStorage().keyHashes.at(i));
    }

    /// @notice Returns the hash of the key, which does not includes the expiry.
    function hash(Key memory key) public pure virtual returns (bytes32) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        return EfficientHashLib.hash(uint8(key.keyType), uint256(keccak256(key.publicKey)));
    }

    /// @notice Returns the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function getKey(bytes32 keyHash) public view virtual returns (Key memory key) {
        bytes memory data = _getExperimentalDelegationStorage().keyStorage[keyHash].get();
        if (data.length == 0) revert KeyDoesNotExist();
        unchecked {
            uint256 n = data.length - 6;
            uint256 packed = uint48(bytes6(LibBytes.load(data, n)));
            key.expiry = uint40(packed >> 8);
            key.keyType = KeyType(uint8(packed));
            key.publicKey = LibBytes.truncate(data, n);
        }
    }

    function computeDigest(Call[] calldata calls, uint256 nonce)
        public
        view
        virtual
        returns (bytes32 result)
    {
        bytes32[] memory a = EfficientHashLib.malloc(calls.length);
        for (uint256 i; i < calls.length; ++i) {
            Call calldata c = calls[i];
            a.set(
                i,
                EfficientHashLib.hash(
                    CALL_TYPEHASH,
                    bytes32(uint256(uint160(c.target))),
                    bytes32(c.value),
                    EfficientHashLib.hashCalldata(c.data)
                )
            );
        }
        return _hashTypedData(
            EfficientHashLib.hash(
                EXECUTE_TYPEHASH,
                a.hash(),
                bytes32(nonce),
                bytes32(_getExperimentalDelegationStorage().nonceSalt)
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @notice Checks if a signature is valid.
    /// @param digest - The digest to verify.
    /// @param signature - The wrapped signature to verify.
    function _isValidSignature(bytes32 digest, bytes calldata signature)
        internal
        view
        virtual
        returns (bool)
    {
        if (LibBit.or(signature.length == 64, signature.length == 65)) {
            return ECDSA.recoverCalldata(digest, signature) == address(this);
        }

        uint256 n = signature.length - 33;
        // `signature` is `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
        unchecked {
            if (uint256(LibBytes.loadCalldata(signature, n + 1)) & 0xff != 0) {
                digest = sha256(abi.encode(digest)); // Do the prehash if last byte is non-zero.
            }
        }
        Key memory key = getKey(LibBytes.loadCalldata(signature, n));
        signature = LibBytes.truncatedCalldata(signature, n);

        if (LibBit.and(key.expiry != 0, key.expiry < block.timestamp)) return false;

        if (key.keyType == KeyType.P256) {
            (bytes32 r, bytes32 s) = P256.decodePointCalldata(signature);
            (bytes32 x, bytes32 y) = P256.decodePoint(key.publicKey);
            return P256.verifySignature(digest, r, s, x, y);
        }

        if (key.keyType == KeyType.WebAuthnP256) {
            (bytes32 x, bytes32 y) = P256.decodePoint(key.publicKey);
            return WebAuthn.verify(
                abi.encode(digest), // Challenge.
                false, // Require user verification optional.
                abi.decode(signature, (WebAuthn.WebAuthnAuth)), // Auth.
                x,
                y
            );
        }
        return false;
    }

    /// @notice Adds the key. If the key already exist, its expiry will be updated.
    function _addKey(Key memory key) internal virtual returns (bytes32 keyHash) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        keyHash = hash(key);
        ExperimentalDelegationStorage storage $ = _getExperimentalDelegationStorage();
        $.keyStorage[keyHash].set(abi.encodePacked(key.publicKey, key.expiry, key.keyType));
        $.keyHashes.add(keyHash);
    }

    /// @notice Removes the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function _removeKey(bytes32 keyHash) internal virtual {
        ExperimentalDelegationStorage storage $ = _getExperimentalDelegationStorage();
        $.keyStorage[keyHash].clear();
        if (!$.keyHashes.remove(keyHash)) revert KeyDoesNotExist();
    }

    /// @notice Requires that the caller is `address(this)`.
    function _checkThis() internal view virtual {
        if (msg.sender != address(this)) revert Unauthorized();
    }

    /// @notice Guards a function such that it can only be called by `address(this)`.
    modifier onlyThis() virtual {
        _checkThis();
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Overrides
    ////////////////////////////////////////////////////////////////////////

    /// @notice For MinimalBatchExecutor.
    function _authorizeExecute(Call[] calldata calls, bytes calldata opData)
        internal
        view
        override
    {
        if (opData.length == uint256(0)) {
            _checkThis();
        } else {
            // For now, `opData` is `abi.encodePacked(bytes(signature), uint256(nonce))`.
            uint256 n = opData.length - 32;
            bytes calldata signature = LibBytes.truncatedCalldata(opData, n);
            uint256 nonce = uint256(LibBytes.loadCalldata(opData, n));
            if (!_isValidSignature(computeDigest(calls, nonce), signature)) revert Unauthorized();
        }
    }

    /// @notice For EIP712.
    function _domainNameAndVersion()
        internal
        view
        virtual
        override
        returns (string memory name, string memory version)
    {
        name = "ExperimentalDelegation";
        version = "0.0.1";
    }
}
