// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {LibBit} from "solady/utils/LibBit.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibTransient} from "solady/utils/LibTransient.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {P256} from "solady/utils/P256.sol";
import {WebAuthn} from "solady/utils/WebAuthn.sol";
import {LibStorage} from "solady/utils/LibStorage.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {LibERC7579} from "solady/accounts/LibERC7579.sol";
import {GuardedExecutor} from "./GuardedExecutor.sol";
import {LibNonce} from "./libraries/LibNonce.sol";
import {TokenTransferLib} from "./libraries/TokenTransferLib.sol";
import {LibTStack} from "./libraries/LibTStack.sol";
import {IIthacaAccount} from "./interfaces/IIthacaAccount.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

/// @title Account
/// @notice A account contract for EOAs with EIP7702.
contract IthacaAccount is IIthacaAccount, EIP712, GuardedExecutor {
    using EfficientHashLib for bytes32[];
    using EnumerableSetLib for *;
    using LibBytes for LibBytes.BytesStorage;
    using LibBitmap for LibBitmap.Bitmap;
    using LibStorage for LibStorage.Bump;
    using LibRLP for LibRLP.List;
    using LibTransient for LibTransient.TBytes32;
    using LibTStack for LibTStack.TStack;

    ////////////////////////////////////////////////////////////////////////
    // Data Structures
    ////////////////////////////////////////////////////////////////////////

    /// @dev The type of key.
    enum KeyType {
        P256,
        WebAuthnP256,
        Secp256k1,
        External
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
    struct AccountStorage {
        /// @dev The label.
        LibBytes.BytesStorage label;
        /// @dev Mapping for 4337-style 2D nonce sequences.
        /// Each nonce has the following bit layout:
        /// - Upper 192 bits are used for the `seqKey` (sequence key).
        ///   The upper 16 bits of the `seqKey` is `MULTICHAIN_NONCE_PREFIX`,
        ///   then the Intent EIP-712 hash will exclude the chain ID.
        /// - Lower 64 bits are used for the sequential nonce corresponding to the `seqKey`.
        mapping(uint192 => LibStorage.Ref) nonceSeqs;
        /// @dev Set of key hashes for onchain enumeration of authorized keys.
        EnumerableSetLib.Bytes32Set keyHashes;
        /// @dev Mapping of key hash to the key in encoded form.
        mapping(bytes32 => LibBytes.BytesStorage) keyStorage;
        /// @dev Mapping of key hash to the key's extra storage.
        mapping(bytes32 => LibStorage.Bump) keyExtraStorage;
        /// @dev Nonce management when porto account acts as paymaster.
        mapping(bytes32 => bool) paymasterNonces;
    }

    /// @dev Returns the storage pointer.
    function _getAccountStorage() internal pure returns (AccountStorage storage $) {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("ITHACA_ACCOUNT_STORAGE")));
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
        bytes32 s = _getAccountStorage().keyExtraStorage[keyHash].slot();
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev The key does not exist.
    error KeyDoesNotExist();

    /// @dev The `opData` is too short.
    error OpDataError();

    /// @dev The `keyType` cannot be super admin.
    error KeyTypeCannotBeSuperAdmin();

    /// @dev The public key is invalid.
    error InvalidPublicKey();

    /// @dev Upgrading to `address(0)` is not allowed.
    /// If you want to upgrade to a bricked implementation,
    /// use `address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD)`.
    error NewImplementationIsZero();

    /// @dev The paymaster nonce has already been used.
    error PaymasterNonceError();

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

    /// @dev The nonce sequence of is invalidated up to (inclusive) of `nonce`.
    /// The new available nonce will be `nonce + 1`.
    /// This event is emitted in the `invalidateNonce` function,
    /// as well as the `execute` function when an execution is performed directly
    /// on the Account with a `keyHash`, bypassing the Orchestrator.
    event NonceInvalidated(uint256 nonce);

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev The orchestrator address.
    address public immutable ORCHESTRATOR;

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant EXECUTE_TYPEHASH = keccak256(
        "Execute(bool multichain,Call[] calls,uint256 nonce)Call(address to,uint256 value,bytes data)"
    );

    /// @dev For EIP712 signature digest calculation for the `execute` function.
    bytes32 public constant CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");

    /// @dev For EIP712 signature digest calculation.
    bytes32 public constant DOMAIN_TYPEHASH = _DOMAIN_TYPEHASH;

    /// @dev For ERC1271 replay-safe hashing.
    bytes32 public constant SIGN_TYPEHASH = keccak256("ERC1271Sign(bytes32 digest)");

    /// @dev Nonce prefix to signal that the payload is to be signed with EIP-712 without the chain ID.
    /// This constant is a pun for "chain ID 0".
    uint16 public constant MULTICHAIN_NONCE_PREFIX = 0xc1d0;

    /// @dev A unique identifier to be passed into `upgradeHook(bytes32 previousVersion)`
    /// via the transient storage slot at `_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT`.
    bytes32 internal constant _UPGRADE_HOOK_ID = keccak256("ITHACA_ACCOUNT_UPGRADE_HOOK_ID");

    /// @dev This transient slot must be set to `_UPGRADE_HOOK_ID` before `upgradeHook` can be processed.
    bytes32 internal constant _UPGRADE_HOOK_GUARD_TRANSIENT_SLOT =
        bytes32(uint256(keccak256("_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT")) - 1);

    /// @dev List of keyhashes that have authorized the current execution context.
    /// Increasing in order of recursive depth.
    uint256 internal constant _KEYHASH_STACK_TRANSIENT_SLOT =
        uint256(keccak256("_KEYHASH_STACK_TRANSIENT_SLOT")) - 1;

    /// @dev General capacity for enumerable sets,
    /// to prevent off-chain full enumeration from running out-of-gas.
    uint256 internal constant _CAP = 512;

    ////////////////////////////////////////////////////////////////////////
    // Constructor
    ////////////////////////////////////////////////////////////////////////

    constructor(address orchestrator) payable {
        ORCHESTRATOR = orchestrator;
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC1271
    ////////////////////////////////////////////////////////////////////////

    /// @dev Variant of `_hashTypedData` that includes only the verifying contract.
    function _hashTypedDataOnlyVerifyingContract(bytes32 structHash)
        internal
        view
        virtual
        returns (bytes32 digest)
    {
        assembly ("memory-safe") {
            let m := mload(0x40) // Load the free memory pointer.
            // Domain Typehash: `keccak256("EIP712Domain(address verifyingContract)")`
            mstore(0x00, 0x035aff83d86937d35b32e04f0ddc6ff469290eef2f1b692d8a815c89404d4749)
            mstore(0x20, address())
            // Compute the digest.
            mstore(0x20, keccak256(0x00, 0x40)) // Store the domain separator.
            mstore(0x00, 0x1901) // Store "\x19\x01".
            mstore(0x40, structHash) // Store the struct hash.
            digest := keccak256(0x1e, 0x42)
            mstore(0x40, m) // Restore the free memory pointer.
        }
    }

    /// @dev Checks if a signature is valid.
    /// Note: For security reasons, we can only let this function validate against the
    /// original EOA key and other super admin keys.
    /// Otherwise, any session key can be used to approve infinite allowances
    /// via Permit2 by default, which will allow apps infinite power.
    /// @dev Note: The rehashing scheme is not EIP-5267 compliant.
    /// A different domain separator is used for the rehashing, which excludes `name` and `version`
    /// from the domain, for latency improvements offchain.
    function isValidSignature(bytes32 digest, bytes calldata signature)
        public
        view
        virtual
        returns (bytes4)
    {
        // To sign an app digest (e.g. Permit2), you would need to perform a `hashTypedData` on the app's 712,
        // along with the app's domain, then `signTypedData` with the account's 712 and account domain.
        // The account domain is added as a layer to prevent replay attacks since some apps do not include the
        // account address as a field in their 712 data.
        bytes32 replaySafeDigest = EfficientHashLib.hash(SIGN_TYPEHASH, digest);
        digest = _hashTypedDataOnlyVerifyingContract(replaySafeDigest);

        (bool isValid, bytes32 keyHash) = unwrapAndValidateSignature(digest, signature);
        if (LibBit.and(keyHash != 0, isValid)) {
            isValid = _isSuperAdmin(keyHash)
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
        _getAccountStorage().label.set(bytes(newLabel));
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

    /// @dev Sets whether `checker` can use `isValidSignature` to successfully validate
    /// a signature for a given key hash.
    function setSignatureCheckerApproval(bytes32 keyHash, address checker, bool isApproved)
        public
        virtual
        onlyThis
    {
        if (_getAccountStorage().keyStorage[keyHash].isEmpty()) revert KeyDoesNotExist();
        _getKeyExtraStorage(keyHash).checkers.update(checker, isApproved, _CAP);
        emit SignatureCheckerApprovalSet(keyHash, checker, isApproved);
    }

    /// @dev Increments the sequence for the `seqKey` in nonce (i.e. upper 192 bits).
    /// This invalidates the nonces for the `seqKey`, up to (inclusive) `uint64(nonce)`.
    function invalidateNonce(uint256 nonce) public virtual onlyThis {
        LibNonce.invalidate(_getAccountStorage().nonceSeqs, nonce);
        emit NonceInvalidated(nonce);
    }

    /// @dev Upgrades the proxy account.
    /// If this account is delegated directly without usage of EIP7702Proxy,
    /// this operation will not affect the logic until the authority is redelegated
    /// to a proper EIP7702Proxy. The `newImplementation` should implement
    /// `upgradeProxyAccount` or similar, otherwise upgrades will be locked and
    /// only a new EIP-7702 transaction can change the authority's logic.
    function upgradeProxyAccount(address newImplementation) public virtual onlyThis {
        if (newImplementation == address(0)) revert NewImplementationIsZero();
        LibEIP7702.upgradeProxyDelegation(newImplementation);
        (, string memory version) = _domainNameAndVersion();
        // Using a dedicated guard makes the hook only callable via this function
        // prevents direct self-calls which may accidentally use the wrong hook ID and version.
        LibTransient.tBytes32(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT).set(_UPGRADE_HOOK_ID);
        // We MUST use `this`, so that it uses the new implementation's `upgradeHook`.
        require(this.upgradeHook(LibString.toSmallString(version)));
    }

    /// @dev For this very first version, the upgrade hook is just an no-op.
    /// Provided to enable calling it via plain Solidity.
    /// For future implementations, we will have an upgrade hook which can contain logic
    /// to migrate storage on a case-by-case basis if needed.
    /// If this hook is implemented to mutate storage,
    /// it MUST check that `_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT` is correctly set.
    function upgradeHook(bytes32 previousVersion) external virtual onlyThis returns (bool) {
        previousVersion = previousVersion; // Silence unused variable warning.
        // Example of how we are supposed to load, check and clear the upgrade hook guard.
        bytes32 hookId = LibTransient.tBytes32(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT).get();
        require(hookId == _UPGRADE_HOOK_ID);
        LibTransient.tBytes32(_UPGRADE_HOOK_GUARD_TRANSIENT_SLOT).clear();
        // Always returns true for cheaper call success check (even in plain Solidity).
        return true;
    }

    ////////////////////////////////////////////////////////////////////////
    // Public View Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Return current nonce with sequence key.
    function getNonce(uint192 seqKey) public view virtual returns (uint256) {
        return LibNonce.get(_getAccountStorage().nonceSeqs, seqKey);
    }

    /// @dev Returns the label.
    function label() public view virtual returns (string memory) {
        return string(_getAccountStorage().label.get());
    }

    /// @dev Returns the number of authorized keys.
    function keyCount() public view virtual returns (uint256) {
        return _getAccountStorage().keyHashes.length();
    }

    /// @dev Returns the authorized key at index `i`.
    function keyAt(uint256 i) public view virtual returns (Key memory) {
        return getKey(_getAccountStorage().keyHashes.at(i));
    }

    /// @dev Returns the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function getKey(bytes32 keyHash) public view virtual returns (Key memory key) {
        bytes memory data = _getAccountStorage().keyStorage[keyHash].get();
        if (data.length == uint256(0)) revert KeyDoesNotExist();
        unchecked {
            uint256 n = data.length - 7; // 5 + 1 + 1 bytes of fixed length fields.
            uint256 packed = uint56(bytes7(LibBytes.load(data, n)));
            key.expiry = uint40(packed >> 16); // 5 bytes.
            key.keyType = KeyType(uint8(packed >> 8)); // 1 byte.
            key.isSuperAdmin = uint8(packed) != 0; // 1 byte.
            key.publicKey = LibBytes.truncate(data, n);
        }
    }

    /// @dev Returns arrays of all (non-expired) authorized keys and their hashes.
    function getKeys() public view virtual returns (Key[] memory keys, bytes32[] memory keyHashes) {
        uint256 totalCount = keyCount();

        keys = new Key[](totalCount);
        keyHashes = new bytes32[](totalCount);

        uint256 validCount = 0;
        for (uint256 i = 0; i < totalCount; i++) {
            bytes32 keyHash = _getAccountStorage().keyHashes.at(i);
            Key memory key = getKey(keyHash);

            // If key.expiry is set and the key is expired, skip it.
            if (LibBit.and(key.expiry != 0, block.timestamp > key.expiry)) {
                continue;
            }

            keys[validCount] = key;
            keyHashes[validCount] = keyHash;

            validCount++;
        }

        // Adjust the length of the arrays to the validCount
        assembly {
            mstore(keys, validCount)
            mstore(keyHashes, validCount)
        }
    }

    /// @dev Return the key hash that signed the latest execution context.
    /// @dev Returns bytes32(0) if the EOA key was used.
    function getContextKeyHash() public view virtual returns (bytes32) {
        LibTStack.TStack memory t = LibTStack.tStack(_KEYHASH_STACK_TRANSIENT_SLOT);
        if (LibTStack.size(t) == 0) {
            return bytes32(0);
        }

        return LibTStack.top(t);
    }

    /// @dev Returns the hash of the key, which does not includes the expiry.
    function hash(Key memory key) public pure virtual returns (bytes32) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        return EfficientHashLib.hash(uint8(key.keyType), uint256(keccak256(key.publicKey)));
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

    /// @dev Verifies the merkle sig
    /// - Note: Each leaf of the merkle tree should be a standard digest.
    /// - The signature for using merkle verification is encoded as:
    /// - bytes signature = abi.encode(bytes32[] proof, bytes32 root, bytes rootSig)
    function _verifyMerkleSig(bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool isValid, bytes32 keyHash)
    {
        bytes32[] calldata proof;
        bytes32 root;
        bytes calldata rootSig;

        assembly ("memory-safe") {
            let proofOffset := add(signature.offset, calldataload(signature.offset))
            proof.length := calldataload(proofOffset)
            proof.offset := add(proofOffset, 0x20)

            root := calldataload(add(signature.offset, 0x20))

            let rootSigOffset := add(signature.offset, calldataload(add(signature.offset, 0x40)))
            rootSig.length := calldataload(rootSigOffset)
            rootSig.offset := add(rootSigOffset, 0x20)
        }

        if (MerkleProofLib.verifyCalldata(proof, root, digest)) {
            (isValid, keyHash) = unwrapAndValidateSignature(root, rootSig);

            return (isValid, keyHash);
        }

        return (false, bytes32(0));
    }

    /// @dev Returns if the signature is valid, along with its `keyHash`.
    /// The `signature` is a wrapped signature, given by
    /// `abi.encode(bytes(innerSignature), bytes32(keyHash), bool(prehash), bool(merkle))`.
    function unwrapAndValidateSignature(bytes32 digest, bytes calldata signature)
        public
        view
        virtual
        returns (bool isValid, bytes32 keyHash)
    {
        // Early return if unable to unwrap the signature.
        if (signature.length < 0x21) return (false, 0);

        // If the signature's length is 64 or 65, treat it like an secp256k1 signature.
        if (LibBit.or(signature.length == 64, signature.length == 65)) {
            return (ECDSA.recoverCalldata(digest, signature) == address(this), 0);
        }

        bool merkle;
        unchecked {
            uint256 n = signature.length - 0x22;
            keyHash = LibBytes.loadCalldata(signature, n);
            signature = LibBytes.truncatedCalldata(signature, n);
            // Do the prehash if last byte is non-zero.
            if (uint256(LibBytes.loadCalldata(signature, n + 1)) & 0xff != 0) {
                digest = EfficientHashLib.sha2(digest); // `sha256(abi.encode(digest))`.
            }
            merkle = uint256(LibBytes.loadCalldata(signature, n + 2)) & 0xff != 0;
        }

        if (merkle) {
            return _verifyMerkleSig(digest, signature);
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
        } else if (key.keyType == KeyType.External) {
            // The public key of an external key type HAS to be 32 bytes.
            // Top 20 bytes: address of the signer.
            // Bottom 12 bytes: arbitrary data, that should be used as a salt.
            if (key.publicKey.length != 32) revert InvalidPublicKey();

            address signer = address(bytes20(key.publicKey));

            assembly ("memory-safe") {
                let m := mload(0x40)
                mstore(m, 0x8afc93b4) // `isValidSignatureWithKeyHash(bytes32,bytes32,bytes)`
                mstore(add(m, 0x20), digest)
                mstore(add(m, 0x40), keyHash)
                mstore(add(m, 0x60), 0x60) // signature offset
                mstore(add(m, 0x80), signature.length) // signature length
                calldatacopy(add(m, 0xa0), signature.offset, signature.length) // copy data to memory offset

                mstore(0x00, 0) // Zeroize return data memory.
                let size := add(signature.length, 0x84)
                let success := staticcall(gas(), signer, add(m, 0x1c), size, 0x00, 0x20)

                // MagicValue: bytes4(keccak256("isValidSignatureWithKeyHash(bytes32,bytes32,bytes)")
                if and(success, eq(shr(224, mload(0x00)), 0x8afc93b4)) { isValid := true }
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Adds the key. If the key already exist, its expiry will be updated.
    function _addKey(Key memory key) internal virtual returns (bytes32 keyHash) {
        // `keccak256(abi.encode(key.keyType, keccak256(key.publicKey)))`.
        keyHash = hash(key);
        AccountStorage storage $ = _getAccountStorage();
        $.keyStorage[keyHash]
        .set(abi.encodePacked(key.publicKey, key.expiry, key.keyType, key.isSuperAdmin));
        $.keyHashes.add(keyHash);
    }

    /// @dev Removes the key corresponding to the `keyHash`. Reverts if the key does not exist.
    function _removeKey(bytes32 keyHash) internal virtual {
        AccountStorage storage $ = _getAccountStorage();
        $.keyStorage[keyHash].clear();
        $.keyExtraStorage[keyHash].invalidate();
        if (!$.keyHashes.remove(keyHash)) revert KeyDoesNotExist();
    }

    ////////////////////////////////////////////////////////////////////////
    // Orchestrator Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Checks current nonce and increments the sequence for the `seqKey`.
    function checkAndIncrementNonce(uint256 nonce) public payable virtual {
        if (msg.sender != ORCHESTRATOR) {
            revert Unauthorized();
        }
        LibNonce.checkAndIncrement(_getAccountStorage().nonceSeqs, nonce);
    }

    /// @dev Pays `paymentAmount` of `paymentToken` to the `paymentRecipient`.
    function pay(
        uint256 paymentAmount,
        bytes32 keyHash,
        bytes32 intentDigest,
        bytes calldata encodedIntent
    ) public virtual {
        Intent calldata intent;
        // Equivalent Solidity Code: (In the assembly intent is stored in calldata, instead of memory)
        // Intent memory intent = abi.decode(encodedIntent, (Intent));
        // Gas Savings:
        // ~2.5-3k gas for general cases, by avoiding duplicated bounds checks, and avoiding writing the intent to memory.
        // Extracts the Intent from the calldata bytes, with minimal checks.
        // NOTE: Only use this implementation if you are sure that the encodedIntent is coming from a trusted source.
        // We can avoid standard bound checks here, because the Orchestrator already does these checks when it interacts with ALL the fields in the intent using solidity.
        assembly ("memory-safe") {
            let t := calldataload(encodedIntent.offset)
            intent := add(t, encodedIntent.offset)
            // Bounds check. We don't need to explicitly check the fields here.
            // In the self call functions, we will use regular Solidity to access the
            // dynamic fields like `signature`, which generate the implicit bounds checks.
            if or(shr(64, t), lt(encodedIntent.length, 0x20)) { revert(0x00, 0x00) }
        }

        if (!LibBit.and(
                msg.sender == ORCHESTRATOR,
                LibBit.or(intent.eoa == address(this), intent.payer == address(this))
            )) {
            revert Unauthorized();
        }

        // If this account is the paymaster, validate the paymaster signature.
        if (intent.payer == address(this)) {
            if (_getAccountStorage().paymasterNonces[intentDigest]) {
                revert PaymasterNonceError();
            }
            _getAccountStorage().paymasterNonces[intentDigest] = true;

            (bool isValid, bytes32 k) =
                unwrapAndValidateSignature(intentDigest, intent.paymentSignature);

            // Set the target key hash to the payer's.
            keyHash = k;

            // If this is a simulation, signature validation errors are skipped.
            /// @dev to simulate a paymaster, state override the balance of the relayer
            /// to type(uint192).max.
            if (tx.origin.balance >= type(uint192).max) {
                isValid = true;
            }

            if (!isValid) {
                revert Unauthorized();
            }
        }

        TokenTransferLib.safeTransfer(intent.paymentToken, intent.paymentRecipient, paymentAmount);
        // Increase spend.
        if (!(keyHash == bytes32(0) || _isSuperAdmin(keyHash))) {
            SpendStorage storage spends = _getGuardedExecutorKeyStorage(keyHash).spends;
            _incrementSpent(spends.spends[intent.paymentToken], intent.paymentToken, paymentAmount);
        }

        // Done to avoid compiler warnings.
        intentDigest = intentDigest;
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7821
    ////////////////////////////////////////////////////////////////////////

    /// @dev For ERC7821.
    function _execute(bytes32, bytes calldata, Call[] calldata calls, bytes calldata opData)
        internal
        virtual
        override
    {
        // Orchestrator workflow.
        if (msg.sender == ORCHESTRATOR) {
            // opdata
            // 0x00: keyHash
            if (opData.length != 0x20) revert OpDataError();
            bytes32 _keyHash = LibBytes.loadCalldata(opData, 0x00);

            LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).push(_keyHash);
            _execute(calls, _keyHash);
            LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).pop();

            return;
        }

        // Simple workflow without `opData`.
        if (opData.length == uint256(0)) {
            if (msg.sender != address(this)) revert Unauthorized();
            return _execute(calls, bytes32(0));
        }

        // Simple workflow with `opData`.
        if (opData.length < 0x20) revert OpDataError();
        uint256 nonce = uint256(LibBytes.loadCalldata(opData, 0x00));
        LibNonce.checkAndIncrement(_getAccountStorage().nonceSeqs, nonce);
        emit NonceInvalidated(nonce);

        (bool isValid, bytes32 keyHash) = unwrapAndValidateSignature(
            computeDigest(calls, nonce), LibBytes.sliceCalldata(opData, 0x20)
        );
        if (!isValid) revert Unauthorized();

        // TODO: Figure out where else to add these operations, after removing delegate call.
        LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).push(keyHash);
        _execute(calls, keyHash);
        LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).pop();
    }

    ////////////////////////////////////////////////////////////////////////
    // GuardedExecutor
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns if `keyHash` corresponds to a super admin key.
    function _isSuperAdmin(bytes32 keyHash) internal view virtual override returns (bool) {
        LibBytes.BytesStorage storage s = _getAccountStorage().keyStorage[keyHash];
        uint256 encodedLength = s.length();
        if (encodedLength == uint256(0)) revert KeyDoesNotExist();
        return s.uint8At(Math.rawSub(encodedLength, 1)) != 0;
    }

    /// @dev Returns the storage seed for a `keyHash`.
    function _getGuardedExecutorKeyStorageSeed(bytes32 keyHash)
        internal
        view
        override
        returns (bytes32)
    {
        return _getAccountStorage().keyExtraStorage[keyHash].slot();
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
        name = "IthacaAccount";
        version = "0.5.11";
    }
}
