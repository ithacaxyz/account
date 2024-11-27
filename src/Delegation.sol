// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Receiver} from "solady/accounts/Receiver.sol";
import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {P256} from "solady/utils/P256.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";

contract Delegation is Receiver, EIP712, ERC7821 {
    using EfficientHashLib for bytes32[];
    using EnumerableSetLib for EnumerableSetLib.Bytes32Set;
    using LibBytes for LibBytes.BytesStorage;
    using LibBitmap for LibBitmap.Bitmap;

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    /// @dev The type of key.
    enum KeyType {
        P256,
        WebAuthnP256
    }

    /// @dev A key that can be used to authorize call.
    struct Key {
        /// @dev Unix timestamp at which the key expires (0 = never).
        uint40 expiry;
        /// @dev Type of key. See the {KeyType} enum.
        KeyType keyType;
        /// @dev Public key in encoded form.
        bytes publicKey;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Holds the storage.
    struct DelegationStorage {
        /// @dev The entry point.
        address entryPoint;
        /// @dev The label.
        LibBytes.BytesStorage label;
        /// @dev Bitmap of invalidated nonces. Set bit means invalidated.
        LibBitmap.Bitmap invalidatedNonces;
        /// @dev The current nonce salt.
        uint256 nonceSalt;
        /// @dev Set of key hashes for onchain enumeration of authorized keys.
        EnumerableSetLib.Bytes32Set keyHashes;
        /// @dev Mapping of key hash to the key in encoded form.
        mapping(bytes32 => LibBytes.BytesStorage) keyStorage;
    }

    /// @dev Returns the storage pointer.
    function _getDelegationStorage()
        internal
        pure
        returns (DelegationStorage storage $)
    {
        assembly ("memory-safe") {
            // `uint72(bytes9(keccak256("PORTO_DELEGATION_STORAGE")))`.
            $.slot := 0x6d3d4e7fb92a523813 // Truncate to 9 bytes to reduce bytecode size.
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev This feature has not been implemented yet.
    error Unimplemented();

    /// @dev The key is expired or unauthorized.
    error KeyExpiredOrUnauthorized();

    /// @dev The sender is not the EOA.
    error Unauthorized();

    /// @dev The signature is invalid.
    error InvalidSignature();

    /// @dev The key does not exist.
    error KeyDoesNotExist();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev The entry point has been updated to `newEntryPoint`.
    event EntryPointSet(address newEntryPoint);

    /// @dev The label has been updated to `newLabel`.
    event LabelSet(string newLabel);

    /// @dev The key with a corresponding `keyHash` has been authorized.
    event Authorized(bytes32 indexed keyHash, Key key);

    /// @dev The key with a corresponding `keyHash` has been revoked.
    event Revoked(bytes32 indexed keyHash);

    /// @dev The `nonce` have been invalidated.
    event NonceInvalidated(uint256 nonce);

    /// @dev The nonce salt has been incremented to `newNonceSalt`.
    event NonceSaltIncremented(uint256 newNonceSalt);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP-712 signature digest calculation for the `execute` function.
    /// "Execute(Call[] calls,uint256 nonce,uint256 nonceSalt)Call(address target,uint256 value,bytes data)"
    bytes32 public constant EXECUTE_TYPEHASH =
        0xe530e62dece51c9bec26701907051ddc8420a62f028096eeb58263193e84e049;

    /// @dev For EIP-712 signature digest calculation for the `execute` function.
    /// "Call(address target,uint256 value,bytes data)")`
    bytes32 public constant CALL_TYPEHASH =
        0x84fa2cf05cd88e992eae77e851af68a4ee278dcff6ef504e487a55b3baadfbe5;

    /// @dev For EIP-712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    ////////////////////////////////////////////////////////////////////////
    // ERC1271
    ////////////////////////////////////////////////////////////////////////

    /// @dev Checks if a signature is valid. The `signature` is a wrapped signature.
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

    /// @dev Sets the entry point.
    function setEntryPoint(address newEntryPoint) public virtual onlyThis {
        _getDelegationStorage().entryPoint = newEntryPoint;
        emit EntryPointSet(newEntryPoint);
    }

    /// @dev Sets the label.
    function setLabel(string calldata newLabel) public virtual onlyThis {
        _getDelegationStorage().label.set(bytes(newLabel));
        emit LabelSet(newLabel);
    }

    /// @dev Revokes the key corresponding to `keyHash`.
    function revoke(bytes32 keyHash) public virtual onlyThis {
        _removeKey(keyHash);
        emit Revoked(keyHash);
    }

    /// @dev Authorizes the key.
    function authorize(Key memory key) public virtual onlyThis returns (bytes32 keyHash) {
        keyHash = _addKey(key);
        emit Authorized(keyHash, key);
    }

    /// @dev Invalidates the nonce.
    function invalidateNonce(uint256 nonce) public virtual onlyThis {
        _getDelegationStorage().invalidatedNonces.set(nonce);
        emit NonceInvalidated(nonce);
    }

    /// @dev Increments the nonce salt by a pseudorandom uint32 value.
    function incrementNonceSalt() public virtual onlyThis returns (uint256 newNonceSalt) {
        DelegationStorage storage $ = _getDelegationStorage();
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

    function entryPoint() public view virtual returns (address) {
        return _getDelegationStorage().entryPoint;
    }

    function label() public view virtual returns (string memory) {
        return string(_getDelegationStorage().label.get());
    }

    function nonceIsInvalidated(uint256 nonce) public view virtual returns (bool) {
        return _getDelegationStorage().invalidatedNonces.get(nonce);
    }

    function nonceSalt() public view virtual returns (uint256) {
        return _getDelegationStorage().nonceSalt;
    }

    function keyCount() public view virtual returns (uint256) {
        return _getDelegationStorage().keyHashes.length();
    }

    function keyAt(uint256 i) public view virtual returns (Key memory) {
        return getKey(_getDelegationStorage().keyHashes.at(i));
    }

    /// @dev Returns the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function getKey(bytes32 keyHash) public view virtual returns (Key memory key) {
        bytes memory data = _getDelegationStorage().keyStorage[keyHash].get();
        if (data.length == 0) revert KeyDoesNotExist();
        unchecked {
            uint256 n = data.length - 6;
            uint256 packed = uint48(bytes6(LibBytes.load(data, n)));
            key.expiry = uint40(packed >> 8);
            key.keyType = KeyType(uint8(packed));
            key.publicKey = LibBytes.truncate(data, n);
        }
    }

    /// @dev Returns the hash of the key, which does not includes the expiry.
    function hash(Key memory key) public pure virtual returns (bytes32) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        return EfficientHashLib.hash(uint8(key.keyType), uint256(keccak256(key.publicKey)));
    }

    /// @dev Computes the EIP-712 digest for `calls`, `opData`, with `nonceSalt` from storage.
    function computeDigest(Call[] calldata calls, bytes calldata opData)
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
                bytes32(opData[:32]),
                bytes32(_getDelegationStorage().nonceSalt)
            )
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Checks if a signature is valid. The `signature` is a wrapped signature.
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
        
        uint256 expiry = key.expiry;
        if (LibBit.and(expiry != 0, expiry < block.timestamp)) return false;    

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
                WebAuthn.tryDecodeAuth(signature), // Auth.
                x,
                y
            );
        }
        return false;
    }

    /// @dev Adds the key. If the key already exist, its expiry will be updated.
    function _addKey(Key memory key) internal virtual returns (bytes32 keyHash) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        keyHash = hash(key);
        DelegationStorage storage $ = _getDelegationStorage();
        $.keyStorage[keyHash].set(abi.encodePacked(key.publicKey, key.expiry, key.keyType));
        $.keyHashes.add(keyHash);
    }

    /// @dev Removes the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function _removeKey(bytes32 keyHash) internal virtual {
        DelegationStorage storage $ = _getDelegationStorage();
        $.keyStorage[keyHash].clear();
        if (!$.keyHashes.remove(keyHash)) revert KeyDoesNotExist();
    }

    /// @dev Guards a function such that it can only be called by `address(this)`.
    modifier onlyThis() virtual {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7821
    ////////////////////////////////////////////////////////////////////////

    /// @dev For ERC7821.
    function _execute(Call[] calldata calls, bytes calldata opData)
        internal
        virtual
        override
        returns (bytes[] memory)
    {
        // Entry point workflow.
        if (msg.sender == entryPoint()) {
            // If the sender is the trusted entry point, we assume that `calls` have
            // been authorized via signature that has been checked on the entry point.
            // In this case, `opData` will be used to pass paymaster information instead.
            address paymentERC20 = address(bytes20(LibBytes.loadCalldata(opData, 0x00)));
            uint256 requiredBalanceAfter = uint256(LibBytes.loadCalldata(opData, 0x14))
                + SafeTransferLib.balanceOf(paymentERC20, msg.sender);

            bytes[] memory results = _execute(calls);

            uint256 balanceAfter = SafeTransferLib.balanceOf(paymentERC20, msg.sender);
            if (requiredBalanceAfter > balanceAfter) {
                unchecked {
                    uint256 delta = requiredBalanceAfter - balanceAfter;
                    SafeTransferLib.safeTransfer(paymentERC20, msg.sender, delta);
                }
            }
            return results;
        }

        // Simple workflow.
        if (opData.length == uint256(0)) {
            if (msg.sender != address(this)) revert Unauthorized();
            return _execute(calls);
        }
        if (!_isValidSignature(computeDigest(calls, opData), opData[32:])) revert Unauthorized();
        return _execute(calls);
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
        name = "Delegation";
        version = "0.0.1";
    }
}
