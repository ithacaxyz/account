// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibBit} from "solady/utils/LibBit.sol";

contract GuardedExecutor is ERC7821 {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Cannot set or get the permissions if the `keyHash` is `bytes32(0)`.
    error KeyHashIsZero();

    /// @dev Only the EOA itself and super admin keys can self execute.
    error CannotSelfExecute();

    /// @dev Unauthorized to perform the action.
    error Unauthorized();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev Emitted when the ability to execute a call with function selector is set.
    event CanExecuteSet(bytes32 keyHash, address target, bytes4 fnSel, bool can);

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Represents any key hash.
    bytes32 public constant ANY_KEYHASH =
        0x3232323232323232323232323232323232323232323232323232323232323232;

    /// @dev Represents any target address.
    address public constant ANY_TARGET = 0x3232323232323232323232323232323232323232;

    /// @dev Represents any function selector.
    bytes4 public constant ANY_FN_SEL = 0x32323232;

    /// @dev Represents empty calldata.
    /// An empty calldata does not have 4 bytes for a function selector,
    /// and we will use this special value to denote empty calldata.
    bytes4 public constant EMPTY_CALLDATA_FN_SEL = 0xe0e0e0e0;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Holds the storage.
    struct GuardedExecutorStorage {
        /// @dev Mapping of a call hash to whether it can be executed.
        mapping(bytes32 => bool) canExecute;
    }

    /// @dev Returns the storage pointer.
    function _getGuardedExecutorStorage()
        internal
        pure
        returns (GuardedExecutorStorage storage $)
    {
        // Truncate to 9 bytes to reduce bytecode size.
        uint256 s = uint72(bytes9(keccak256("PORTO_GUARDED_EXECUTOR_STORAGE")));
        assembly ("memory-safe") {
            $.slot := s
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC7821
    ////////////////////////////////////////////////////////////////////////

    /// @dev Override to add a check on `keyHash`.
    function _execute(address target, uint256 value, bytes calldata data, bytes32 keyHash)
        internal
        virtual
        override
    {
        if (!canExecute(keyHash, target, data)) revert Unauthorized();
        ERC7821._execute(target, value, data, keyHash);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Sets the ability of a key hash to execute a call with a function selector.
    function setCanExecute(bytes32 keyHash, address target, bytes4 fnSel, bool can)
        public
        virtual
        onlyThis
    {
        // Sanity check as a key hash of `bytes32(0)` represents the EOA's key itself.
        // The EOA is always able to call any function on itself, so there is no point
        // setting which functions and contracts it can touch via execute.
        if (keyHash == bytes32(0)) revert KeyHashIsZero();

        // All calls not from the EOA itself has to go through the single `execute` function.
        // For security, only EOA key and super admin keys can call into `execute`.
        // Otherwise any low stakes app key can call super admin functions
        // such as like `authorize` and `revoke`.
        // This check is for sanity. We will still validate this in `canExecute`.
        if (_isSelfExecute(target, fnSel)) {
            if (!_isSuperAdmin(keyHash)) revert CannotSelfExecute();
        }

        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;
        c[_hash(keyHash, target, fnSel)] = can;
        emit CanExecuteSet(keyHash, target, fnSel, can);
    }

    ////////////////////////////////////////////////////////////////////////
    // Public View Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns whether a key hash can execute a call.
    function canExecute(bytes32 keyHash, address target, bytes calldata data)
        public
        view
        virtual
        returns (bool)
    {
        // A zero `keyHash` represents that the execution is authorized / performed
        // by the `eoa`'s secp256k1 key itself.
        if (keyHash == bytes32(0)) return true;

        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;

        bytes4 fnSel = ANY_FN_SEL;
        
        // If the calldata has 4 or more bytes, we can assume that the leading 4 bytes
        // denotes the function selector. 
        if (data.length >= 4) fnSel = bytes4(LibBytes.loadCalldata(data, 0x00));
        
        // If the calldata is empty, make sure that the empty calldata has been authorized.
        if (data.length == uint256(0)) fnSel = EMPTY_CALLDATA_FN_SEL;

        // This check is required to ensure that authorizing any function selector
        // or any target will still NOT allow for self execution.
        if (_isSelfExecute(target, fnSel)) if (!_isSuperAdmin(keyHash)) return false;

        if (c[_hash(keyHash, target, fnSel)]) return true;
        if (c[_hash(keyHash, ANY_TARGET, fnSel)]) return true;
        if (c[_hash(ANY_KEYHASH, target, fnSel)]) return true;
        if (c[_hash(ANY_KEYHASH, ANY_TARGET, fnSel)]) return true;
        if (c[_hash(keyHash, target, ANY_FN_SEL)]) return true;
        if (c[_hash(keyHash, ANY_TARGET, ANY_FN_SEL)]) return true;
        if (c[_hash(ANY_KEYHASH, target, ANY_FN_SEL)]) return true;
        if (c[_hash(ANY_KEYHASH, ANY_TARGET, ANY_FN_SEL)]) return true;
        return false;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns whether the call is a self execute.
    function _isSelfExecute(address target, bytes4 fnSel) internal view returns (bool) {
        return LibBit.and(target == address(this), fnSel == ERC7821.execute.selector);
    }

    /// @dev Returns the hash of function.
    function _hash(bytes32 keyHash, address target, bytes4 fnSel)
        internal
        pure
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            // Use assembly to avoid `abi.encodePacked` overhead.
            mstore(0x00, fnSel)
            mstore(0x18, target)
            mstore(0x04, keyHash)
            result := keccak256(0x00, 0x38) // 4 + 20 + 32 = 56 = 0x38.
        }
    }

    /// @dev Guards a function such that it can only be called by `address(this)`.
    modifier onlyThis() virtual {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Configurables
    ////////////////////////////////////////////////////////////////////////

    /// @dev To be overriden to return if `keyHash` corresponds to a super admin key.
    function _isSuperAdmin(bytes32 keyHash) internal view virtual returns (bool) {
        keyHash = keyHash; // Silence unused variable warning.
        return false;
    }
}
