// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBit} from "solady/utils/LibBit.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {LibStorage} from "solady/utils/LibStorage.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {GuardedExecutor} from "./GuardedExecutor.sol";
import {TokenTransferLib} from "./TokenTransferLib.sol";

/// @title Delegation
/// @notice A delegation contract for EOAs with EIP7702.
contract Delegation is EIP712, GuardedExecutor {
    using EfficientHashLib for bytes32[];
    using EnumerableSetLib for *;
    using LibBytes for LibBytes.BytesStorage;
    using LibBitmap for LibBitmap.Bitmap;
    using LibStorage for LibStorage.Bump;

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    /// @dev The type of key.
    enum KeyType {
        P256,
        WebAuthnP256,
        Secp256k1
    }

    /// @dev A key that can be used to authorize call.
    struct Key {
        /// @dev Unix timestamp at which the key expires (0 = never).
        uint40 expiry;
        /// @dev Type of key. See the {KeyType} enum.
        KeyType keyType;
        /// @dev Whether the key is a super admin key.
        /// Super admin keys are allowed to call into super admin functions such as
        /// `authorize` and `revoke` via `execute`.
        bool isSuperAdmin;
        /// @dev Public key in encoded form.
        bytes publicKey;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev This struct contains extra data for a given key hash.
    struct KeyExtraStorage {
        /// @dev The `msg.senders` that can use `isValidSignature`
        /// to successfully validate a signature for a given key hash.
        EnumerableSetLib.AddressSet checkers;
    }

    /// @dev Holds the storage.
    struct DelegationStorage {
        /// @dev The label.
        LibBytes.BytesStorage label;
        /// @dev Reserved spacer.
        uint256 _spacer0;
        /// @dev Mapping for 4337-style 2D nonce sequences.
        /// Each nonce has the following bit layout:
        /// - Upper 192 bits are used for the `seqKey` (sequence key).
        ///   The upper 16 bits of the `seqKey` is `MULTICHAIN_NONCE_PREFIX`,
        ///   then the UserOp EIP-712 hash will exclude the chain ID.
        /// - Lower 64 bits are used for the sequential nonce corresponding to the `seqKey`.
        mapping(uint192 => LibStorage.Ref) nonceSeqs;
        /// @dev Set of key hashes for onchain enumeration of authorized keys.
        EnumerableSetLib.Bytes32Set keyHashes;
        /// @dev Mapping of key hash to the key in encoded form.
        mapping(bytes32 => LibBytes.BytesStorage) keyStorage;
        /// @dev Mapping of key hash to the key's extra storage.
        mapping(bytes32 => LibStorage.Bump) keyExtraStorage;
        /// @dev Set of approved implementations for delegate calls.
        EnumerableSetLib.AddressSet approvedImplementations;
        /// @dev Mapping of approved implementations to their callers storage.
        mapping(address => LibStorage.Bump) approvedImplementationCallers;
    }

    /// @dev Returns the storage pointer.
    function _getDelegationStorage() internal pure returns (DelegationStorage storage $) {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("PORTO_DELEGATION_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    /// @dev Returns the storage pointer.
    function _getKeyExtraStorage(bytes32 keyHash)
        internal
        view
        returns (KeyExtraStorage storage $)
    {
        bytes32 s = _getDelegationStorage().keyExtraStorage[keyHash].slot();
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    /// @dev Returns the storage pointer.
    function _getApprovedImplementationCallers(address implementation)
        internal
        view
        returns (EnumerableSetLib.AddressSet storage $)
    {
        bytes32 s = _getDelegationStorage().approvedImplementationCallers[implementation].slot();
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev The key does not exist.
    error KeyDoesNotExist();

    /// @dev The nonce is invalid.
    error InvalidNonce();

    /// @dev The `opData` is too short.
    error OpDataTooShort();

    /// @dev When invalidating a nonce sequence, the new sequence must be larger than the current.
    error NewSequenceMustBeLarger();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev The label has been updated to `newLabel`.
    event LabelSet(string newLabel);

    /// @dev The key with a corresponding `keyHash` has been authorized.
    event Authorized(bytes32 indexed keyHash, Key key);

    /// @dev The `implementation` has been authorized.
    event ImplementationApprovalSet(address indexed implementation, bool isApproved);

    /// @dev The `caller` has been authorized to delegate call into `implementation`.
    event ImplementationCallerApprovalSet(
        address indexed implementation, address indexed caller, bool isApproved
    );

    /// @dev The key with a corresponding `keyHash` has been revoked.
    event Revoked(bytes32 indexed keyHash);

    /// @dev The `checker` has been authorized to use `isValidSignature` for `keyHash`.
    event SignatureCheckerApprovalSet(
        bytes32 indexed keyHash, address indexed checker, bool isApproved
    );

    /// @dev The nonce sequence is incremented.
    event NonceInvalidated(uint256 nonce);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The entry point address.
    address public constant ENTRY_POINT = 0x307AF7d28AfEE82092aA95D35644898311CA5360;

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant EXECUTE_TYPEHASH = keccak256(
        "Execute(bool multichain,Call[] calls,uint256 nonce)Call(address target,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");

    /// @dev For EIP712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    /// @dev Nonce prefix to signal that the payload is to be signed with EIP-712 without the chain ID.
    /// This constant is a pun for "chain ID 0".
    uint16 public constant MULTICHAIN_NONCE_PREFIX = 0xc1d0;

    /// @dev General capacity for enumerable sets,
    /// to prevent off-chain full enumeration from running out-of-gas.
    uint256 internal constant _CAP = 512;

    ////////////////////////////////////////////////////////////////////////
    // ERC1271
    ////////////////////////////////////////////////////////////////////////

    /// @dev Checks if a signature is valid.
    /// Note: For security reasons, we can only let this function validate against the
    /// original EOA key and other super admin keys.
    /// Otherwise, any session key can be used to approve infinite allowances
    /// via Permit2 by default, which will allow apps infinite power.
    function isValidSignature(bytes32 digest, bytes calldata signature)
        public
        view
        virtual
        returns (bytes4)
    {
        (bool isValid, bytes32 keyHash) = _unwrapAndValidateSignature(digest, signature);
        if (LibBit.and(keyHash != 0, isValid)) {
            isValid = getKey(keyHash).isSuperAdmin
                || _getKeyExtraStorage(keyHash).checkers.contains(msg.sender);
        }
        // `bytes4(keccak256("isValidSignature(bytes32,bytes)")) = 0x1626ba7e`.
        // We use `0xffffffff` for invalid, in convention with the reference implementation.
        return bytes4(isValid ? 0x1626ba7e : 0xffffffff);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    // The following functions can only be called by this contract.
    // If a signature is required to call these functions, please use the `execute`
    // function with `auth` set to `abi.encode(nonce, signature)`.

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

    /// @dev Sets whether `implementation` is approved to be delegate called into.
    function setImplementationApproval(address implementation, bool isApproved)
        public
        virtual
        onlyThis
    {
        DelegationStorage storage $ = _getDelegationStorage();
        $.approvedImplementations.update(implementation, isApproved, _CAP);
        if (!isApproved) $.approvedImplementationCallers[implementation].invalidate();
        emit ImplementationApprovalSet(implementation, isApproved);
    }

    /// @dev Sets whether `implementation` can be delegate called by `caller`.
    function setImplementationCallerApproval(
        address implementation,
        address caller,
        bool isApproved
    ) public virtual onlyThis {
        DelegationStorage storage $ = _getDelegationStorage();
        if (!$.approvedImplementations.contains(implementation)) revert Unauthorized();
        _getApprovedImplementationCallers(implementation).update(caller, isApproved, _CAP);
        emit ImplementationCallerApprovalSet(implementation, caller, isApproved);
    }

    /// @dev Sets whether `checker` can use `isValidSignature` to successfully validate
    /// a signature for a given key hash.
    function setSignatureCheckerApproval(bytes32 keyHash, address checker, bool isApproved)
        public
        virtual
        onlyThis
    {
        if (_getDelegationStorage().keyStorage[keyHash].isEmpty()) revert KeyDoesNotExist();
        _getKeyExtraStorage(keyHash).checkers.update(checker, isApproved, _CAP);
        emit SignatureCheckerApprovalSet(keyHash, checker, isApproved);
    }

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to `uint64(nonce)`.
    function invalidateNonce(uint256 nonce) public virtual onlyThis {
        LibStorage.Ref storage s = _getDelegationStorage().nonceSeqs[uint192(nonce >> 64)];
        if (uint64(nonce) <= s.value) revert NewSequenceMustBeLarger();
        s.value = uint64(nonce);
        emit NonceInvalidated(nonce);
    }

    /// @dev Upgrades the proxy delegation.
    /// If this delegation is delegated directly without usage of EIP7702Proxy,
    /// this operation will not affect the logic until the authority is redelegated
    /// to a proper EIP7702Proxy. The `newImplementation` should implement
    /// `upgradeProxyDelegation` or similar, otherwise upgrades will be locked and
    /// only a new EIP-7702 transaction can change the authority's logic.
    function upgradeProxyDelegation(address newImplementation) public virtual onlyThis {
        LibEIP7702.upgradeProxyDelegation(newImplementation);
    }

    ////////////////////////////////////////////////////////////////////////
    // Public View Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Return current nonce with sequence key.
    function getNonce(uint192 seqKey) public view virtual returns (uint256) {
        return _getDelegationStorage().nonceSeqs[seqKey].value | (uint256(seqKey) << 64);
    }

    /// @dev Returns the label.
    function label() public view virtual returns (string memory) {
        return string(_getDelegationStorage().label.get());
    }

    /// @dev Returns the number of authorized keys.
    function keyCount() public view virtual returns (uint256) {
        return _getDelegationStorage().keyHashes.length();
    }

    /// @dev Returns the authorized key at index `i`.
    function keyAt(uint256 i) public view virtual returns (Key memory) {
        return getKey(_getDelegationStorage().keyHashes.at(i));
    }

    /// @dev Returns the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function getKey(bytes32 keyHash) public view virtual returns (Key memory key) {
        bytes memory data = _getDelegationStorage().keyStorage[keyHash].get();
        if (data.length == 0) revert KeyDoesNotExist();
        unchecked {
            uint256 n = data.length - 7; // 5 + 1 + 1 bytes of fixed length fields.
            uint256 packed = uint56(bytes7(LibBytes.load(data, n)));
            key.expiry = uint40(packed >> 16); // 5 bytes.
            key.keyType = KeyType(uint8(packed >> 8)); // 1 byte.
            key.isSuperAdmin = uint8(packed) != 0; // 1 byte.
            key.publicKey = LibBytes.truncate(data, n);
        }
    }

    /// @dev Returns the hash of the key, which does not includes the expiry.
    function hash(Key memory key) public pure virtual returns (bytes32) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        return EfficientHashLib.hash(uint8(key.keyType), uint256(keccak256(key.publicKey)));
    }

    /// @dev Returns the list of approved implementations.
    function approvedImplementations() public view virtual returns (address[] memory) {
        return _getDelegationStorage().approvedImplementations.values();
    }

    /// @dev Returns the list of callers approved to delegate call into `implementation`.
    function approvedImplementationCallers(address implementation)
        public
        view
        virtual
        returns (address[] memory)
    {
        return _getApprovedImplementationCallers(implementation).values();
    }

    /// @dev Returns the list of approved signature checkers for `keyHash`.
    function approvedSignatureCheckers(bytes32 keyHash)
        public
        view
        virtual
        returns (address[] memory)
    {
        return _getKeyExtraStorage(keyHash).checkers.values();
    }

    /// @dev Computes the EIP712 digest for `calls`.
    /// If the the nonce starts with `MULTICHAIN_NONCE_PREFIX`,
    /// the digest will be computed without the chain ID.
    /// Otherwise, the digest will be computed with the chain ID.
    function computeDigest(Call[] calldata calls, uint256 nonce)
        public
        view
        virtual
        returns (bytes32 result)
    {
        bytes32[] memory a = EfficientHashLib.malloc(calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (address target, uint256 value, bytes calldata data) = _get(calls, i);
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
        bool isMultichain = nonce >> 240 == MULTICHAIN_NONCE_PREFIX;
        bytes32 structHash = EfficientHashLib.hash(
            uint256(EXECUTE_TYPEHASH), LibBit.toUint(isMultichain), uint256(a.hash()), nonce
        );
        return isMultichain ? _hashTypedDataSansChainId(structHash) : _hashTypedData(structHash);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Adds the key. If the key already exist, its expiry will be updated.
    function _addKey(Key memory key) internal virtual returns (bytes32 keyHash) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        keyHash = hash(key);
        DelegationStorage storage $ = _getDelegationStorage();
        $.keyStorage[keyHash].set(
            abi.encodePacked(key.publicKey, key.expiry, key.keyType, key.isSuperAdmin)
        );
        $.keyHashes.add(keyHash);
    }

    /// @dev Removes the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function _removeKey(bytes32 keyHash) internal virtual {
        DelegationStorage storage $ = _getDelegationStorage();
        $.keyStorage[keyHash].clear();
        $.keyExtraStorage[keyHash].invalidate();
        if (!$.keyHashes.remove(keyHash)) revert KeyDoesNotExist();
    }

    ////////////////////////////////////////////////////////////////////////
    // Entry Point Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Pays `paymentAmount` of `paymentToken` to the Entry Point.
    function payEntryPoint(address paymentToken, uint256 paymentAmount, address eoa)
        public
        virtual
    {
        if (msg.sender != ENTRY_POINT) revert Unauthorized();
        if (eoa != address(this)) revert Unauthorized();
        TokenTransferLib.safeTransfer(paymentToken, msg.sender, paymentAmount);
    }

    /// @dev Returns if the signature is valid, along with its `keyHash`.
    /// The `signature` is a wrapped signature, given by
    /// `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
    function unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        public
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        return _unwrapAndValidateSignature(digest, signature);
    }

    /// @dev Returns if the signature is valid, along with its `keyHash`.
    /// The `signature` is a wrapped signature, given by
    /// `abi.encodePacked(bytes(innerSignature), bytes32(keyHash), bool(prehash))`.
    function _unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        internal
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        // If the signature's length is 64 or 65, treat it like an secp256k1 signature.
        if (LibBit.or(signature.length == 64, signature.length == 65)) {
            return (ECDSA.recoverCalldata(digest, signature) == address(this), 0);
        }

        // Early return if unable to unwrap the signature.
        if (signature.length < 0x21) return (false, 0);

        unchecked {
            uint256 n = signature.length - 0x21;
            keyHash = LibBytes.loadCalldata(signature, n);
            signature = LibBytes.truncatedCalldata(signature, n);
            // Do the prehash if last byte is non-zero.
            if (uint256(LibBytes.loadCalldata(signature, n + 1)) & 0xff != 0) {
                digest = EfficientHashLib.sha2(digest); // `sha256(abi.encode(digest))`.
            }
        }
        Key memory key = getKey(keyHash);

        // Early return if the key has expired.
        if (LibBit.and(key.expiry != 0, block.timestamp > key.expiry)) return (false, keyHash);

        if (key.keyType == KeyType.P256) {
            // The try decode functions returns `(0,0)` if the bytes is too short,
            // which will make the signature check fail.
            (bytes32 r, bytes32 s) = P256.tryDecodePointCalldata(signature);
            (bytes32 x, bytes32 y) = P256.tryDecodePoint(key.publicKey);
            isValid = P256.verifySignature(digest, r, s, x, y);
        } else if (key.keyType == KeyType.WebAuthnP256) {
            (bytes32 x, bytes32 y) = P256.tryDecodePoint(key.publicKey);
            isValid = WebAuthn.verify(
                abi.encode(digest), // Challenge.
                false, // Require user verification optional.
                // This is simply `abi.decode(signature, (WebAuthn.WebAuthnAuth))`.
                WebAuthn.tryDecodeAuth(signature), // Auth.
                x,
                y
            );
        } else if (key.keyType == KeyType.Secp256k1) {
            isValid = SignatureCheckerLib.isValidSignatureNowCalldata(
                abi.decode(key.publicKey, (address)), digest, signature
            );
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7821
    ////////////////////////////////////////////////////////////////////////

    /// @dev Override to allow for a delegate call workflow.
    /// Any implementation contract used in the delegate call workflow must be approved first.
    function execute(bytes32 mode, bytes calldata executionData) public payable virtual override {
        // ERC7579 designates `mode[0]` to denote the call mode, and delegate call is `0xff`.
        if (bytes1(mode) == 0xff) {
            _executeERC7579DelegateCall(executionData);
        } else {
            super.execute(mode, executionData);
        }
        LibEIP7702.requestProxyDelegationInitialization();
    }

    /// @dev Supported modes:
    /// - `0x01000000000000000000...`: Single batch. Does not support optional `opData`.
    /// - `0x01000000000078210001...`: Single batch. Supports optional `opData`.
    /// - `0x01000000000078210002...`: Batch of batches.
    /// - `0xff000000000000000000...`: Delegate call.
    function supportsExecutionMode(bytes32 mode) public view virtual override returns (bool) {
        return LibBit.or(bytes1(mode) == 0xff, super.supportsExecutionMode(mode));
    }

    /// @dev Special execute for the delegate call mode.
    function _executeERC7579DelegateCall(bytes calldata executionData) internal virtual {
        DelegationStorage storage $ = _getDelegationStorage();
        // ERC7579 defines the delegate call encoding as `abi.encodePacked(implementation,data)`.
        address target = address(bytes20(LibBytes.loadCalldata(executionData, 0x00)));
        bytes calldata data = LibBytes.sliceCalldata(executionData, 0x14);
        if (!$.approvedImplementations.contains(target)) {
            revert Unauthorized();
        }
        if (msg.sender != address(this)) {
            if (!_getApprovedImplementationCallers(target).contains(msg.sender)) {
                revert Unauthorized();
            }
        }
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(delegatecall(gas(), target, m, data.length, codesize(), 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }

    /// @dev For ERC7821.
    function _execute(bytes32, bytes calldata, Call[] calldata calls, bytes calldata opData)
        internal
        virtual
        override
    {
        // Entry point workflow.
        if (msg.sender == ENTRY_POINT) {
            if (opData.length < 0x20) revert OpDataTooShort();
            return _execute(calls, LibBytes.loadCalldata(opData, 0x00));
        }

        // Simple workflow without `opData`.
        if (opData.length == uint256(0)) {
            if (msg.sender != address(this)) revert Unauthorized();
            return _execute(calls, bytes32(0));
        }

        // Simple workflow with `opData`.
        if (opData.length < 0x20) revert OpDataTooShort();
        uint256 nonce = uint256(LibBytes.loadCalldata(opData, 0x00));
        unchecked {
            uint256 seq = _getDelegationStorage().nonceSeqs[uint192(nonce >> 64)].value++;
            if (seq != uint64(nonce)) revert InvalidNonce();
        }

        (bool isValid, bytes32 keyHash) = unwrapAndValidateSignature(
            computeDigest(calls, nonce), LibBytes.sliceCalldata(opData, 0x20)
        );
        if (!isValid) revert Unauthorized();
        _execute(calls, keyHash);
    }

    ////////////////////////////////////////////////////////////////////////
    // GuardedExecutor
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns if `keyHash` corresponds to a super admin key.
    function _isSuperAdmin(bytes32 keyHash) internal view virtual override returns (bool) {
        return getKey(keyHash).isSuperAdmin;
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
