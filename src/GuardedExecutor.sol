// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract GuardedExecutor is ERC7821 {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Unauthorized to perform the action.
    error Unauthorized();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev Emitted when the ability to execute a call with function selector is set.
    event CanExecuteFunctionSet(bytes32 keyHash, address target, bytes4 fnSel, bool can);

    /// @dev Emitted when the ability to execute a call with exact calldata is set.
    event CanExecuteExactCalldataSet(
        bytes32 keyHash, address target, bytes exactCalldata, bool can
    );

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

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Holds the storage.
    struct GuardedExecutorStorage {
        /// @dev Mapping of a call hash to whether it can be executed.
        /// Call hash is either based on:
        /// - `(keyHash, target, fnSel)`.
        /// - `(keyHash, target, exactCalldata)`.
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
        returns (bytes memory result)
    {
        if (!canExecute(keyHash, target, data)) revert Unauthorized();
        if (target == address(this)) if (keyHash != bytes32(0)) revert Unauthorized();
        result = ERC7821._execute(target, value, data, keyHash);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Sets the ability of a key hash to execute a call with a function selector.
    function setCanExecuteFunction(bytes32 keyHash, address target, bytes4 fnSel, bool can)
        public
        virtual
        onlyThis
    {
        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;
        c[_hash(keyHash, target, fnSel)] = can;
        emit CanExecuteFunctionSet(keyHash, target, fnSel, can);
    }

    /// @dev Sets the ability of a key hash to execute a call with exact calldata.
    function setCanExecuteExactCalldata(
        bytes32 keyHash,
        address target,
        bytes calldata exactCalldata,
        bool can
    ) public virtual onlyThis {
        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;
        c[_hash(keyHash, target, exactCalldata)] = can;
        emit CanExecuteExactCalldataSet(keyHash, target, exactCalldata, can);
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
        if (data.length >= 4) {
            bytes4 fnSel = bytes4(LibBytes.loadCalldata(data, 0x00));
            if (canExecuteFunction(keyHash, target, fnSel)) return true;
        }
        return canExecuteExactCalldata(keyHash, target, data);
    }

    /// @dev Returns whether a key hash can execute a call with a function selector.
    function canExecuteFunction(bytes32 keyHash, address target, bytes4 fnSel)
        public
        view
        virtual
        returns (bool)
    {
        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;
        if (c[_hash(keyHash, target, fnSel)]) return true;
        if (c[_hash(keyHash, target, ANY_FN_SEL)]) return true;
        if (c[_hash(keyHash, ANY_TARGET, fnSel)]) return true;
        if (c[_hash(keyHash, ANY_TARGET, ANY_FN_SEL)]) return true;
        if (c[_hash(ANY_KEYHASH, target, fnSel)]) return true;
        if (c[_hash(ANY_KEYHASH, target, ANY_FN_SEL)]) return true;
        if (c[_hash(ANY_KEYHASH, ANY_TARGET, fnSel)]) return true;
        if (c[_hash(ANY_KEYHASH, ANY_TARGET, ANY_FN_SEL)]) return true;
        return false;
    }

    /// @dev Returns whether a key hash can execute a call with exact calldata.
    function canExecuteExactCalldata(bytes32 keyHash, address target, bytes calldata exactCalldata)
        public
        view
        virtual
        returns (bool)
    {
        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;
        if (c[_hash(keyHash, target, exactCalldata)]) return true;
        if (c[_hash(keyHash, ANY_TARGET, exactCalldata)]) return true;
        if (c[_hash(ANY_KEYHASH, target, exactCalldata)]) return true;
        if (c[_hash(ANY_KEYHASH, ANY_TARGET, exactCalldata)]) return true;
        return false;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns the hash of a call.
    function _hash(bytes32 keyHash, address target, bytes4 fnSel) internal pure returns (bytes32) {
        return EfficientHashLib.hash(
            keyHash, bytes32(uint256(uint160(target)) | uint256(bytes32(fnSel)))
        );
    }

    /// @dev Returns the hash of a call.
    function _hash(bytes32 keyHash, address target, bytes calldata exactCalldata)
        internal
        pure
        returns (bytes32)
    {
        return EfficientHashLib.hash(keyHash, bytes20(target), keccak256(exactCalldata));
    }

    /// @dev Guards a function such that it can only be called by `address(this)`.
    modifier onlyThis() virtual {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }
}
