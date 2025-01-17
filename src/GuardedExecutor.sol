// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {DynamicArrayLib} from "solady/utils/DynamicArrayLib.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract GuardedExecutor is ERC7821 {
    using DynamicArrayLib for *;
    using EnumerableSetLib for *;

    ////////////////////////////////////////////////////////////////////////
    // Structs
    ////////////////////////////////////////////////////////////////////////

    /// @dev Information about a daily spend.
    struct DailySpendInfo {
        address token;
        uint256 limit;
        uint256 spent;
        uint256 lastUpdatedDay;
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Cannot set or get the permissions if the `keyHash` is `bytes32(0)`.
    error KeyHashIsZero();

    /// @dev Only the EOA itself and super admin keys can self execute.
    error CannotSelfExecute();

    /// @dev Unauthorized to perform the action.
    error Unauthorized();

    /// @dev Exceeded the daily spend limit.
    error ExceededDailySpendLimit();

    /// @dev Cannot add a new daily spend, as we have reached the maximum capacity.
    /// This is required to prevent unbounded checking costs during execution.
    error ExceededDailySpendsCapacity();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev Emitted when the ability to execute a call with function selector is set.
    event CanExecuteSet(bytes32 keyHash, address target, bytes4 fnSel, bool can);

    /// @dev Emitted when a daily spend limit is set.
    event DailySpendLimitSet(bytes32 keyHash, address token, uint256 limit);

    /// @dev Emitted when a daily spend limit is removed.
    event DailySpendLimitRemoved(bytes32 keyHash, address token);

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

    /// @dev The canonical Permit2 address.
    address internal constant _PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Holds the storage for the daily spend limits.
    struct DailySpendStorage {
        uint256 limit;
        uint256 spent;
        uint256 lastUpdatedDay;
    }

    /// @dev Holds the storage for spend permissions and the current spend state.
    struct SpendStorage {
        EnumerableSetLib.AddressSet tokens;
        mapping(address => DailySpendStorage) dailys;
    }

    /// @dev Holds the storage.
    struct GuardedExecutorStorage {
        /// @dev Mapping of `keccak256(abi.encodePacked(keyHash, target, fnSel))`
        /// to whether it can be executed.
        mapping(bytes32 => bool) canExecute;
        /// @dev Mapping of `keyHash` to the `SpendStorage`.
        mapping(bytes32 => SpendStorage) spends;
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

    struct _ExecuteTemps {
        DynamicArrayLib.DynamicArray withApprovals;
        DynamicArrayLib.DynamicArray approvalTos;
        DynamicArrayLib.DynamicArray erc20s;
        DynamicArrayLib.DynamicArray transferAmounts;
        DynamicArrayLib.DynamicArray guardedERC20s;
        uint256[] balancesBefore;
        uint256 totalNativeSpend;
    }

    /// @dev The `_execute` function imposes daily spending limits with the following:
    /// 1. For every token with a daily spending limit, the
    ///    `max(sum(outgoingAmounts), balanceBefore - balanceAfter)`
    ///    will be added to the daily spent limit.
    /// 2. Any token that is granted a non-zero approval will have the approval
    ///    reset to zero after the calls.
    function _execute(Call[] calldata calls, bytes32 keyHash) internal virtual override {
        if (keyHash == 0) {
            return ERC7821._execute(calls, keyHash);
        }

        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        _ExecuteTemps memory t;

        unchecked {
            uint256 n = spends.tokens.length();
            for (uint256 i; i != n; ++i) {
                address token = spends.tokens.at(i);
                if (token != address(0)) {
                    t.erc20s.p(token);
                    t.transferAmounts.p(uint256(0));
                }
                t.guardedERC20s = t.erc20s.copy();
            }
        }
        // We will only filter based on functions that are known to use `msg.sender`.
        // For signature-based approvals (e.g. permit), we can't do anything
        // to guard, as anyone else can directly submit the calldata and the signature.
        for (uint256 i; i != calls.length; i = FixedPointMathLib.rawAdd(i, 1)) {
            (address target, uint256 value, bytes calldata data) = _get(calls, i);
            t.totalNativeSpend += value;
            if (data.length < 4) continue;
            bytes4 fnSel = bytes4(LibBytes.loadCalldata(data, 0x00));
            // `transfer(address,uint256)`.
            if (fnSel == 0xa9059cbb && t.guardedERC20s.contains(target)) {
                t.erc20s.p(target);
                t.transferAmounts.p(LibBytes.loadCalldata(data, 0x24));
            }
            // `approve(address,uint256)`.
            if (fnSel == 0x095ea7b3 && t.guardedERC20s.contains(target)) {
                if (LibBytes.loadCalldata(data, 0x24) != 0) {
                    t.withApprovals.p(target);
                    t.approvalTos.p(LibBytes.loadCalldata(data, 0x04));
                }
            }
            // The only Permit2 method that requires `msg.sender` to approve.
            // `approve(address,address,uint160,uint48)`.
            if (target == _PERMIT2 && fnSel == 0x87517c45) revert Unauthorized();
        }
        _incrementSpent(spends.dailys[address(0)], t.totalNativeSpend);

        // Sum transfer amounts, grouped by erc20s.
        LibSort.groupSum(t.erc20s.data, t.transferAmounts.data);

        t.balancesBefore = DynamicArrayLib.malloc(t.erc20s.length());
        unchecked {
            for (uint256 i; i != t.erc20s.length(); ++i) {
                address token = t.erc20s.getAddress(i);
                t.balancesBefore.set(i, SafeTransferLib.balanceOf(token, address(this)));
            }
        }

        // Perform the batch execution.
        ERC7821._execute(calls, keyHash);

        unchecked {
            // Revoke all non-zero approvals that have been made.
            for (uint256 i; i < t.withApprovals.length(); ++i) {
                SafeTransferLib.safeApprove(
                    t.withApprovals.getAddress(i), t.approvalTos.getAddress(i), 0
                );
            }
            // Increments the spent amounts.
            for (uint256 i; i < t.erc20s.length(); ++i) {
                address token = t.erc20s.getAddress(i);
                uint256 delta = FixedPointMathLib.zeroFloorSub(
                    t.balancesBefore.get(i), SafeTransferLib.balanceOf(token, address(this))
                );
                delta = FixedPointMathLib.max(delta, t.transferAmounts.get(i));
                _incrementSpent(spends.dailys[token], delta);
            }
        }
    }

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

    /// @dev Sets the daily spend limit of `token` for `keyHash`.
    function setDailySpendLimit(bytes32 keyHash, address token, uint256 limit)
        public
        virtual
        onlyThis
    {
        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        spends.tokens.add(token);
        if (spends.tokens.length() > 255) revert ExceededDailySpendsCapacity();
        spends.dailys[token].limit = limit;
        emit DailySpendLimitSet(keyHash, token, limit);
    }

    /// @dev Removes the daily spend limit of `token` for `keyHash`.
    function removeDailySpendLimit(bytes32 keyHash, address token) public virtual onlyThis {
        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        spends.tokens.remove(token);
        delete spends.dailys[token];
        emit DailySpendLimitRemoved(keyHash, token);
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

    /// @dev Returns an array containing information on all the daily spends for `keyHash`.
    function dailySpends(bytes32 keyHash)
        public
        view
        virtual
        returns (DailySpendInfo[] memory results)
    {
        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        results = new DailySpendInfo[](spends.tokens.length());
        for (uint256 i; i < results.length; ++i) {
            DailySpendInfo memory info = results[i];
            address token = spends.tokens.at(i);
            info.token = token;
            DailySpendStorage storage daily = spends.dailys[token];
            info.limit = daily.limit;
            info.spent = daily.spent;
            info.lastUpdatedDay = daily.lastUpdatedDay;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns whether the call is a self execute.
    function _isSelfExecute(address target, bytes4 fnSel) internal view returns (bool) {
        return LibBit.and(target == address(this), fnSel == ERC7821.execute.selector);
    }

    /// @dev Returns `keccak256(abi.encodePacked(keyHash, target, fnSel))`.
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

    /// @dev Increments the amount spent.
    function _incrementSpent(DailySpendStorage storage daily, uint256 amount) internal virtual {
        uint256 currentDay = block.timestamp / 86400;
        if (daily.lastUpdatedDay < currentDay) {
            daily.lastUpdatedDay = currentDay;
            daily.spent = 0;
        }
        if ((daily.spent += amount) > daily.limit) revert ExceededDailySpendLimit();
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
