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
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

contract GuardedExecutor is ERC7821 {
    using DynamicArrayLib for *;
    using EnumerableSetLib for *;

    ////////////////////////////////////////////////////////////////////////
    // Enums
    ////////////////////////////////////////////////////////////////////////

    enum SpendPeriod {
        Minute,
        Hour,
        Day,
        Week,
        Month,
        Year
    }

    ////////////////////////////////////////////////////////////////////////
    // Structs
    ////////////////////////////////////////////////////////////////////////

    /// @dev Information about a daily spend.
    struct SpendInfo {
        address token;
        SpendPeriod period;
        uint256 limit;
        uint256 spent;
        uint256 lastUpdated;
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
    error ExceededSpendLimit();

    /// @dev Cannot add a new daily spend, as we have reached the maximum capacity.
    /// This is required to prevent unbounded checking costs during execution.
    error ExceededSpendsCapacity();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev Emitted when the ability to execute a call with function selector is set.
    event CanExecuteSet(bytes32 keyHash, address target, bytes4 fnSel, bool can);

    /// @dev Emitted when a daily spend limit is set.
    event SpendLimitSet(bytes32 keyHash, address token, SpendPeriod period, uint256 limit);

    /// @dev Emitted when a daily spend limit is removed.
    event SpendLimitRemoved(bytes32 keyHash, address token, SpendPeriod period);

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

    /// @dev Holds the storage for the token period spend limits.
    struct TokenPeriodSpendStorage {
        uint256 limit;
        uint256 spent;
        uint256 lastUpdated;
    }

    /// @dev Holds the storage for the token spend limits.
    struct TokenSpendStorage {
        EnumerableSetLib.Uint8Set periods;
        mapping(uint256 => TokenPeriodSpendStorage) spends;
    }

    /// @dev Holds the storage for spend permissions and the current spend state.
    struct SpendStorage {
        EnumerableSetLib.AddressSet tokens;
        mapping(address => TokenSpendStorage) spends;
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

    /// @dev To avoid stack-too-deep.
    struct _ExecuteTemps {
        DynamicArrayLib.DynamicArray approvedERC20s;
        DynamicArrayLib.DynamicArray approvalSpenders;
        DynamicArrayLib.DynamicArray erc20s;
        DynamicArrayLib.DynamicArray transferAmounts;
        DynamicArrayLib.DynamicArray permit2ERC20s;
        DynamicArrayLib.DynamicArray permit2Spenders;
    }

    /// @dev The `_execute` function imposes daily spending limits with the following:
    /// 1. For every token with a daily spending limit, the
    ///    `max(sum(outgoingAmounts), balanceBefore - balanceAfter)`
    ///    will be added to the daily spent limit.
    /// 2. Any token that is granted a non-zero approval will have the approval
    ///    reset to zero after the calls.
    function _execute(Call[] calldata calls, bytes32 keyHash) internal virtual override {
        // If self-execute, don't care about the spend permissions.
        if (keyHash == bytes32(0)) return ERC7821._execute(calls, keyHash);

        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        _ExecuteTemps memory t;

        // Collect all ERC20 tokens that need to be guarded,
        // and initialize their transfer amounts as zero.
        uint256 n = spends.tokens.length();
        for (uint256 i; i < n; ++i) {
            address token = spends.tokens.at(i);
            if (token != address(0)) {
                t.erc20s.p(token);
                t.transferAmounts.p(uint256(0));
            }
        }

        // We will only filter based on functions that are known to use `msg.sender`.
        // For signature-based approvals (e.g. permit), we can't do anything
        // to guard, as anyone else can directly submit the calldata and the signature.
        uint256 totalNativeSpend;
        for (uint256 i; i < calls.length; ++i) {
            (address target, uint256 value, bytes calldata data) = _get(calls, i);
            if (value != 0) totalNativeSpend += value;
            if (data.length < 4) continue;
            uint32 fnSel = uint32(bytes4(LibBytes.loadCalldata(data, 0x00)));
            // `transfer(address,uint256)`.
            if (fnSel == 0xa9059cbb) {
                if (!spends.tokens.contains(target)) continue;
                t.erc20s.p(target);
                t.transferAmounts.p(LibBytes.loadCalldata(data, 0x24)); // `amount`.
            }
            // `approve(address,uint256)`.
            if (fnSel == 0x095ea7b3) {
                if (!spends.tokens.contains(target)) continue;
                if (LibBytes.loadCalldata(data, 0x24) == 0) continue; // `amount == 0`.
                t.approvedERC20s.p(target);
                t.approvalSpenders.p(LibBytes.loadCalldata(data, 0x04)); // `spender`.
            }
            // The only Permit2 method that requires `msg.sender` to approve.
            // `approve(address,address,uint160,uint48)`.
            if (fnSel == 0x87517c45) {
                if (target != _PERMIT2) continue;
                if (LibBytes.loadCalldata(data, 0x44) == 0) continue; // `amount == 0`.
                t.permit2ERC20s.p(LibBytes.loadCalldata(data, 0x04)); // `token`.
                t.permit2Spenders.p(LibBytes.loadCalldata(data, 0x24)); // `spender`.
            }
        }
        _incrementSpent(spends.spends[address(0)], totalNativeSpend);

        // Sum transfer amounts, grouped by the ERC20s. In-place.
        LibSort.groupSum(t.erc20s.data, t.transferAmounts.data);

        // Collect the ERC20 balances before the batch execution.
        uint256[] memory balancesBefore = DynamicArrayLib.malloc(t.erc20s.length());
        for (uint256 i; i < t.erc20s.length(); ++i) {
            address token = t.erc20s.getAddress(i);
            balancesBefore.set(i, SafeTransferLib.balanceOf(token, address(this)));
        }

        // Perform the batch execution.
        ERC7821._execute(calls, keyHash);

        // Increments the spent amounts.
        for (uint256 i; i < t.erc20s.length(); ++i) {
            address token = t.erc20s.getAddress(i);
            uint256 balance = SafeTransferLib.balanceOf(token, address(this));
            _incrementSpent(
                spends.spends[token],
                FixedPointMathLib.max(
                    t.transferAmounts.get(i),
                    FixedPointMathLib.zeroFloorSub(balancesBefore.get(i), balance)
                )
            );
        }
        // Revoke all non-zero approvals that have been made.
        for (uint256 i; i < t.approvedERC20s.length(); ++i) {
            SafeTransferLib.safeApprove(
                t.approvedERC20s.getAddress(i), t.approvalSpenders.getAddress(i), 0
            );
        }
        // Revoke all non-zero Permit2 direct approvals that have been made.
        for (uint256 i; i < t.permit2ERC20s.length(); ++i) {
            SafeTransferLib.permit2Lockdown(
                t.permit2ERC20s.getAddress(i), t.permit2Spenders.getAddress(i)
            );
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
        checkKeyHashIsNonZero(keyHash)
    {
        // All calls not from the EOA itself has to go through the single `execute` function.
        // For security, only EOA key and super admin keys can call into `execute`.
        // Otherwise any low-stakes app key can call super admin functions
        // such as like `authorize` and `revoke`.
        // This check is for sanity. We will still validate this in `canExecute`.
        if (_isSelfExecute(target, fnSel)) {
            if (!_isSuperAdmin(keyHash)) revert CannotSelfExecute();
        }

        mapping(bytes32 => bool) storage c = _getGuardedExecutorStorage().canExecute;
        c[_hash(keyHash, target, fnSel)] = can;
        emit CanExecuteSet(keyHash, target, fnSel, can);
    }

    /// @dev Sets the daily spend limit of `token` for `keyHash` for `period`.
    function setSpendLimit(bytes32 keyHash, address token, SpendPeriod period, uint256 limit)
        public
        virtual
        onlyThis
        checkKeyHashIsNonZero(keyHash)
    {
        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        spends.tokens.add(token);
        if (spends.tokens.length() >= 64) revert ExceededSpendsCapacity();

        TokenSpendStorage storage tokenSpends = spends.spends[token];
        tokenSpends.periods.add(uint8(period));
        if (tokenSpends.periods.length() >= 8) revert ExceededSpendsCapacity();

        tokenSpends.spends[uint8(period)].limit = limit;
        emit SpendLimitSet(keyHash, token, period, limit);
    }

    /// @dev Removes the daily spend limit of `token` for `keyHash` for `period`.
    function removeSpendLimit(bytes32 keyHash, address token, SpendPeriod period)
        public
        virtual
        onlyThis
        checkKeyHashIsNonZero(keyHash)
    {
        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        spends.tokens.remove(token);

        TokenSpendStorage storage tokenSpends = spends.spends[token];
        tokenSpends.periods.remove(uint8(period));

        delete tokenSpends.spends[uint8(period)];
        emit SpendLimitRemoved(keyHash, token, period);
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
        // by the EOA's secp256k1 key itself.
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
    function spendInfos(bytes32 keyHash) public view virtual returns (SpendInfo[] memory results) {
        SpendStorage storage spends = _getGuardedExecutorStorage().spends[keyHash];
        DynamicArrayLib.DynamicArray memory a;
        uint256 n = spends.tokens.length();
        for (uint256 i; i < n; ++i) {
            address token = spends.tokens.at(i);
            TokenSpendStorage storage tokenSpends = spends.spends[token];
            uint8[] memory periods = tokenSpends.periods.values();
            for (uint256 j; j < periods.length; ++j) {
                uint8 period = periods[j];
                TokenPeriodSpendStorage storage tokenPeriodSpend = tokenSpends.spends[period];
                SpendInfo memory info;
                info.period = SpendPeriod(period);
                info.token = token;
                info.limit = tokenPeriodSpend.limit;
                info.lastUpdated = tokenPeriodSpend.lastUpdated;
                uint256 pointer;
                assembly ("memory-safe") {
                    pointer := info
                }
                a.p(pointer);
            }
        }
        assembly ("memory-safe") {
            results := mload(a)
        }
    }

    /// @dev Rounds the unix timestamp down to the period.
    function startOfSpendPeriod(uint256 unixTimestamp, SpendPeriod period)
        public
        pure
        returns (uint256)
    {
        if (period == SpendPeriod.Minute) return unixTimestamp / 60 * 60;
        if (period == SpendPeriod.Hour) return unixTimestamp / 3600 * 3600;
        if (period == SpendPeriod.Day) return unixTimestamp / 86400 * 86400;
        if (period == SpendPeriod.Week) return DateTimeLib.mondayTimestamp(unixTimestamp);
        (uint256 year, uint256 month,) = DateTimeLib.timestampToDate(unixTimestamp);
        // Note: DateTimeLib's months and month-days start from 1.
        if (period == SpendPeriod.Month) return DateTimeLib.dateToTimestamp(year, month, 1);
        if (period == SpendPeriod.Year) return DateTimeLib.dateToTimestamp(year, 1, 1);
        revert(); // We shouldn't hit here.
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
    function _incrementSpent(TokenSpendStorage storage s, uint256 amount) internal {
        if (amount == uint256(0)) return; // Early return.
        uint256 n = s.periods.length();
        for (uint256 i; i < n; ++i) {
            uint8 period = s.periods.at(i);
            TokenPeriodSpendStorage storage tokenPeriodSpend = s.spends[period];
            uint256 current = startOfSpendPeriod(block.timestamp, SpendPeriod(period));
            if (tokenPeriodSpend.lastUpdated < current) {
                tokenPeriodSpend.lastUpdated = current;
                tokenPeriodSpend.spent = 0;
            }
            if ((tokenPeriodSpend.spent += amount) > tokenPeriodSpend.limit) {
                revert ExceededSpendLimit();
            }
        }
    }

    /// @dev Guards a function such that it can only be called by `address(this)`.
    modifier onlyThis() virtual {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    /// @dev Checks that the keyHash is non-zero.
    modifier checkKeyHashIsNonZero(bytes32 keyHash) virtual {
        // Sanity check as a key hash of `bytes32(0)` represents the EOA's key itself.
        // The EOA is should be able to call any function on itself,
        // and able to spend as much as it needs. No point restricting, since the EOA
        // key can always be used to change the delegation anyways.
        if (keyHash == bytes32(0)) revert KeyHashIsZero();
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
