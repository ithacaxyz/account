// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC7821} from "solady/accounts/ERC7821.sol";
import {LibSort} from "solady/utils/LibSort.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {LibBit} from "solady/utils/LibBit.sol";
import {DynamicArrayLib} from "solady/utils/DynamicArrayLib.sol";
import {EnumerableSetLib} from "solady/utils/EnumerableSetLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";

/// @title GuardedExecutor
/// @notice Mixin for spend limits and calldata execution guards.
/// @dev
/// Overview:
/// - Execution guards are implemented on a whitelist basis.
///   With the exception of the EOA itself and super admin keys,
///   execution targets and function selectors has to be approved for each new key.
/// - Spend limits are implemented on a whitelist basis.
///   With the exception of the EOA itself and super admin keys,
///   a key cannot spend tokens (ERC20s and native) until spend permissions have been added.
/// - When a spend permission is removed and re-added, its spent amount will be reset.
abstract contract GuardedExecutor is ERC7821 {
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
        Year,
        Forever
    }

    ////////////////////////////////////////////////////////////////////////
    // Structs
    ////////////////////////////////////////////////////////////////////////

    /// @dev Information about a spend.
    /// All timestamp related values are Unix timestamps in seconds.
    struct SpendInfo {
        /// @dev Address of the token. `address(0)` denotes native token.
        address token;
        /// @dev The type of period.
        SpendPeriod period;
        /// @dev The maximum spend limit for the period.
        uint256 limit;
        /// @dev The amount spent in the last updated period.
        uint256 spent;
        /// @dev The start of the last updated period.
        uint256 lastUpdated;
        /// @dev The amount spent in the current period.
        uint256 currentSpent;
        /// @dev The start of the current period.
        uint256 current;
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

    /// @dev Not authorized to perform the call.
    error UnauthorizedCall(bytes32 keyHash, address target, bytes data);

    /// @dev Exceeded the spend limit.
    error ExceededSpendLimit(address token);

    /// @dev In order to spend a token, it must have spend permissions set.
    error NoSpendPermissions();

    /// @dev Super admin keys can execute everything.
    error SuperAdminCanExecuteEverything();

    /// @dev Super admin keys can spend anything.
    error SuperAdminCanSpendAnything();

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev Emitted when the ability to execute a call with function selector is set.
    event CanExecuteSet(bytes32 keyHash, address target, bytes4 fnSel, bool can);

    /// @dev Emitted when a spend limit is set.
    event SpendLimitSet(bytes32 keyHash, address token, SpendPeriod period, uint256 limit);

    /// @dev Emitted when a spend limit is removed.
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

    /// @dev Holds the data for the token period spend limits.
    /// All timestamp related values are Unix timestamps in seconds.
    struct TokenPeriodSpend {
        /// @dev The maximum spend limit for the period.
        uint256 limit;
        /// @dev The amount spent in the last updated period.
        uint256 spent;
        /// @dev The start of the last updated period (unix timestamp).
        uint256 lastUpdated;
    }

    /// @dev Holds the storage for the token spend limits.
    struct TokenSpendStorage {
        /// @dev An enumerable set of the periods.
        EnumerableSetLib.Uint8Set periods;
        /// @dev Mapping of `uint8(period)` to the encoded spends.
        mapping(uint256 => LibBytes.BytesStorage) spends;
    }

    /// @dev Holds the storage for spend permissions and the current spend state.
    struct SpendStorage {
        /// @dev An enumerable set of the tokens.
        EnumerableSetLib.AddressSet tokens;
        /// @dev Mapping of `token` to `TokenSpendStorage`.
        mapping(address => TokenSpendStorage) spends;
    }

    /// @dev Holds the storage for a single `keyHash`.
    struct GuardedExecutorKeyStorage {
        /// @dev A set of `_packCanExecute(target, fnSel)`.
        EnumerableSetLib.Bytes32Set canExecute;
        /// @dev Mapping of `keyHash` to the `SpendStorage`.
        SpendStorage spends;
    }

    /// @dev Returns the storage pointer.
    function _getGuardedExecutorKeyStorage(bytes32 keyHash)
        internal
        view
        returns (GuardedExecutorKeyStorage storage $)
    {
        bytes32 seed =
            keyHash == ANY_KEYHASH ? ANY_KEYHASH : _getGuardedExecutorKeyStorageSeed(keyHash);
        uint256 namespaceHash = uint72(bytes9(keccak256("ITHACA_GUARDED_EXECUTOR_KEY_STORAGE")));
        assembly ("memory-safe") {
            // Non-standard hashing scheme to reduce chance of conflict with regular Solidity.
            mstore(0x09, namespaceHash)
            mstore(0x00, seed)
            $.slot := keccak256(0x00, 0x29)
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

    /// @dev The `_execute` function imposes spending limits with the following:
    /// 1. For every token with a spending limit, the
    ///    `max(sum(outgoingAmounts), balanceBefore - balanceAfter)`
    ///    will be added to the spent limit.
    /// 2. Any token that is granted a non-zero approval will have the approval
    ///    reset to zero after the calls.
    /// 3. Except for the EOA and super admins, a spend limit has to be set for the
    ///    `keyHash` in order for it to spend tokens.
    /// Note: Called internally in ERC7821, which coalesce zero-address `target`s to `address(this)`.
    function _execute(Call[] calldata calls, bytes32 keyHash) internal virtual override {
        // If self-execute or super admin, don't care about the spend permissions.
        if (keyHash == bytes32(0) || _isSuperAdmin(keyHash)) {
            return ERC7821._execute(calls, keyHash);
        }

        SpendStorage storage spends = _getGuardedExecutorKeyStorage(keyHash).spends;
        _ExecuteTemps memory t;

        // Collect all ERC20 tokens that need to be guarded,
        // and initialize their transfer amounts as zero.
        // Used for the check on their before and after balances, in case the batch calls
        // some contract that is authorized to transfer out tokens on behalf of the eoa.
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
                t.erc20s.p(target);
                t.transferAmounts.p(LibBytes.loadCalldata(data, 0x24)); // `amount`.
            }
            // `approve(address,uint256)`.
            // We have to revoke any new approvals after the batch, else a bad app can
            // leave an approval to let them drain unlimited tokens after the batch.
            if (fnSel == 0x095ea7b3) {
                if (LibBytes.loadCalldata(data, 0x24) == 0) continue; // `amount == 0`.
                t.approvedERC20s.p(target);
                t.approvalSpenders.p(LibBytes.loadCalldata(data, 0x04)); // `spender`.
            }
            // The only Permit2 method that requires `msg.sender` to approve.
            // `approve(address,address,uint160,uint48)`.
            // For ERC20 tokens giving Permit2 infinite approvals by default,
            // the approve method on Permit2 acts like a approve method on the ERC20.
            if (fnSel == 0x87517c45) {
                if (target != _PERMIT2) continue;
                if (LibBytes.loadCalldata(data, 0x44) == 0) continue; // `amount == 0`.
                t.permit2ERC20s.p(LibBytes.loadCalldata(data, 0x04)); // `token`.
                t.permit2Spenders.p(LibBytes.loadCalldata(data, 0x24)); // `spender`.
            }
            // `setSpendLimit(bytes32,address,uint8,uint256)`.
            if (fnSel == 0x598daac4) {
                if (target != address(this)) continue;
                if (LibBytes.loadCalldata(data, 0x04) != keyHash) continue;
                t.erc20s.p(LibBytes.loadCalldata(data, 0x24)); // `token`.
                t.transferAmounts.p(uint256(0));
            }
        }

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

        // Perform after the `_execute`, so that in the case where `calls`
        // contain a `setSpendLimit`, it will affect the `_incrementSpent`.
        _incrementSpent(spends.spends[address(0)], address(0), totalNativeSpend);

        // Increments the spent amounts.
        for (uint256 i; i < t.erc20s.length(); ++i) {
            address token = t.erc20s.getAddress(i);
            TokenSpendStorage storage tokenSpends = spends.spends[token];
            _incrementSpent(
                tokenSpends,
                token,
                // While we can actually just use the difference before and after,
                // we also want to let the sum of the transfer amounts in the calldata to be capped.
                // This prevents tokens to be used as flash loans, and also handles cases
                // where the actual token transfers might not match the calldata amounts.
                // There is no strict definition on what constitutes spending,
                // and we want to be as conservative as possible.
                Math.max(
                    t.transferAmounts.get(i),
                    Math.saturatingSub(
                        balancesBefore.get(i), SafeTransferLib.balanceOf(token, address(this))
                    )
                )
            );
        }
        // Revoke all non-zero approvals that have been made, if there's a spend limit.
        for (uint256 i; i < t.approvedERC20s.length(); ++i) {
            address token = t.approvedERC20s.getAddress(i);
            SafeTransferLib.safeApprove(token, t.approvalSpenders.getAddress(i), 0);
        }
        // Revoke all non-zero Permit2 direct approvals that have been made, if there's a spend limit.
        for (uint256 i; i < t.permit2ERC20s.length(); ++i) {
            address token = t.permit2ERC20s.getAddress(i);
            SafeTransferLib.permit2Lockdown(token, t.permit2Spenders.getAddress(i));
        }
    }

    /// @dev Override to add a check on `keyHash`.
    /// Note: Called internally in ERC7821, which coalesce zero-address `target`s to `address(this)`.
    function _execute(address target, uint256 value, bytes calldata data, bytes32 keyHash)
        internal
        virtual
        override
    {
        if (!canExecute(keyHash, target, data)) revert UnauthorizedCall(keyHash, target, data);
        ERC7821._execute(target, value, data, keyHash);
    }

    ////////////////////////////////////////////////////////////////////////
    // Admin Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Sets the ability of a key hash to execute a call with a function selector.
    /// Note: Does NOT coalesce a zero-address `target` to `address(this)`.
    function setCanExecute(bytes32 keyHash, address target, bytes4 fnSel, bool can)
        public
        virtual
        onlyThis
        checkKeyHashIsNonZero(keyHash)
    {
        if (keyHash != ANY_KEYHASH) {
            if (_isSuperAdmin(keyHash)) revert SuperAdminCanExecuteEverything();
        }

        // All calls not from the EOA itself has to go through the single `execute` function.
        // For security, only EOA key and super admin keys can call into `execute`.
        // Otherwise any low-stakes app key can call super admin functions
        // such as like `authorize` and `revoke`.
        // This check is for sanity. We will still validate this in `canExecute`.
        if (_isSelfExecute(target, fnSel)) revert CannotSelfExecute();

        // Impose a max capacity of 2048 for set enumeration, which should be more than enough.
        _getGuardedExecutorKeyStorage(keyHash).canExecute.update(
            _packCanExecute(target, fnSel), can, 2048
        );
        emit CanExecuteSet(keyHash, target, fnSel, can);
    }

    /// @dev Sets the spend limit of `token` for `keyHash` for `period`.
    function setSpendLimit(bytes32 keyHash, address token, SpendPeriod period, uint256 limit)
        public
        virtual
        onlyThis
        checkKeyHashIsNonZero(keyHash)
    {
        if (_isSuperAdmin(keyHash)) revert SuperAdminCanSpendAnything();

        SpendStorage storage spends = _getGuardedExecutorKeyStorage(keyHash).spends;
        spends.tokens.add(token, 64); // Max capacity of 64.

        TokenSpendStorage storage tokenSpends = spends.spends[token];
        tokenSpends.periods.add(uint8(period));

        LibBytes.BytesStorage storage $ = tokenSpends.spends[uint8(period)];
        TokenPeriodSpend memory tokenPeriodSpend = _loadSpend($);
        tokenPeriodSpend.limit = limit;
        _storeSpend($, tokenPeriodSpend);

        emit SpendLimitSet(keyHash, token, period, limit);
    }

    /// @dev Removes the spend limit of `token` for `keyHash` for `period`.
    function removeSpendLimit(bytes32 keyHash, address token, SpendPeriod period)
        public
        virtual
        onlyThis
        checkKeyHashIsNonZero(keyHash)
    {
        if (_isSuperAdmin(keyHash)) revert SuperAdminCanSpendAnything();

        SpendStorage storage spends = _getGuardedExecutorKeyStorage(keyHash).spends;

        TokenSpendStorage storage tokenSpends = spends.spends[token];
        if (tokenSpends.periods.remove(uint8(period))) {
            if (tokenSpends.periods.length() == uint256(0)) spends.tokens.remove(token);
        }

        LibBytes.clear(tokenSpends.spends[uint8(period)]);

        emit SpendLimitRemoved(keyHash, token, period);
    }

    ////////////////////////////////////////////////////////////////////////
    // Public View Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns whether a key hash can execute a call.
    /// Note: Does NOT coalesce a zero-address `target` to `address(this)`.
    function canExecute(bytes32 keyHash, address target, bytes calldata data)
        public
        view
        virtual
        returns (bool)
    {
        // A zero `keyHash` represents that the execution is authorized / performed
        // by the EOA's secp256k1 key itself.
        if (keyHash == bytes32(0)) return true;

        // Super admin keys can execute everything.
        if (_isSuperAdmin(keyHash)) return true;

        bytes4 fnSel = ANY_FN_SEL;

        // If the calldata has 4 or more bytes, we can assume that the leading 4 bytes
        // denotes the function selector.
        if (data.length >= 4) fnSel = bytes4(LibBytes.loadCalldata(data, 0x00));

        // If the calldata is empty, make sure that the empty calldata has been authorized.
        if (data.length == uint256(0)) fnSel = EMPTY_CALLDATA_FN_SEL;

        // This check is required to ensure that authorizing any function selector
        // or any target will still NOT allow for self execution.
        if (_isSelfExecute(target, fnSel)) return false;

        EnumerableSetLib.Bytes32Set storage c = _getGuardedExecutorKeyStorage(keyHash).canExecute;
        if (c.length() != 0) {
            if (c.contains(_packCanExecute(target, fnSel))) return true;
            if (c.contains(_packCanExecute(target, ANY_FN_SEL))) return true;
            if (c.contains(_packCanExecute(ANY_TARGET, fnSel))) return true;
            if (c.contains(_packCanExecute(ANY_TARGET, ANY_FN_SEL))) return true;
        }
        c = _getGuardedExecutorKeyStorage(ANY_KEYHASH).canExecute;
        if (c.length() != 0) {
            if (c.contains(_packCanExecute(target, fnSel))) return true;
            if (c.contains(_packCanExecute(target, ANY_FN_SEL))) return true;
            if (c.contains(_packCanExecute(ANY_TARGET, fnSel))) return true;
            if (c.contains(_packCanExecute(ANY_TARGET, ANY_FN_SEL))) return true;
        }
        return false;
    }

    /// @dev Returns an array of packed (`target`, `fnSel`) that `keyHash` is authorized to execute on.
    /// - `target` is in the upper 20 bytes.
    /// - `fnSel` is in the lower 4 bytes.
    function canExecutePackedInfos(bytes32 keyHash)
        public
        view
        virtual
        returns (bytes32[] memory)
    {
        return _getGuardedExecutorKeyStorage(keyHash).canExecute.values();
    }

    /// @dev Returns an array containing information on all the spends for `keyHash`.
    function spendInfos(bytes32 keyHash) public view virtual returns (SpendInfo[] memory results) {
        SpendStorage storage spends = _getGuardedExecutorKeyStorage(keyHash).spends;
        DynamicArrayLib.DynamicArray memory a;
        uint256 n = spends.tokens.length();
        for (uint256 i; i < n; ++i) {
            address token = spends.tokens.at(i);
            TokenSpendStorage storage tokenSpends = spends.spends[token];
            uint8[] memory periods = tokenSpends.periods.values();
            for (uint256 j; j < periods.length; ++j) {
                uint8 period = periods[j];
                TokenPeriodSpend memory tokenPeriodSpend = _loadSpend(tokenSpends.spends[period]);
                SpendInfo memory info;
                info.period = SpendPeriod(period);
                info.token = token;
                info.limit = tokenPeriodSpend.limit;
                info.lastUpdated = tokenPeriodSpend.lastUpdated;
                info.spent = tokenPeriodSpend.spent;
                info.current = startOfSpendPeriod(block.timestamp, SpendPeriod(period));
                info.currentSpent = Math.ternary(info.lastUpdated < info.current, 0, info.spent);
                uint256 pointer;
                assembly ("memory-safe") {
                    pointer := info // Use assembly to reinterpret cast.
                }
                a.p(pointer);
            }
        }
        assembly ("memory-safe") {
            results := mload(a)
        }
    }

    /// @dev Returns spend and execute infos for each provided key hash in the same order.
    function spendAndExecuteInfos(bytes32[] calldata keyHashes)
        public
        view
        virtual
        returns (SpendInfo[][] memory spends, bytes32[][] memory executes)
    {
        uint256 count = keyHashes.length;
        spends = new SpendInfo[][](count);
        executes = new bytes32[][](count);

        for (uint256 i = 0; i < count; i++) {
            spends[i] = spendInfos(keyHashes[i]);
            executes[i] = canExecutePackedInfos(keyHashes[i]);
        }
    }

    /// @dev Rounds the unix timestamp down to the period.
    function startOfSpendPeriod(uint256 unixTimestamp, SpendPeriod period)
        public
        pure
        returns (uint256)
    {
        if (period == SpendPeriod.Minute) return Math.rawMul(Math.rawDiv(unixTimestamp, 60), 60);
        if (period == SpendPeriod.Hour) return Math.rawMul(Math.rawDiv(unixTimestamp, 3600), 3600);
        if (period == SpendPeriod.Day) return Math.rawMul(Math.rawDiv(unixTimestamp, 86400), 86400);
        if (period == SpendPeriod.Week) return DateTimeLib.mondayTimestamp(unixTimestamp);
        (uint256 year, uint256 month,) = DateTimeLib.timestampToDate(unixTimestamp);
        // Note: DateTimeLib's months and month-days start from 1.
        if (period == SpendPeriod.Month) return DateTimeLib.dateToTimestamp(year, month, 1);
        if (period == SpendPeriod.Year) return DateTimeLib.dateToTimestamp(year, 1, 1);
        if (period == SpendPeriod.Forever) return 1; // Non-zero to differentiate from not set.
        revert(); // We shouldn't hit here.
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns whether the call is a self execute.
    function _isSelfExecute(address target, bytes4 fnSel) internal view returns (bool) {
        return LibBit.and(target == address(this), fnSel == ERC7821.execute.selector);
    }

    /// @dev Returns a bytes32 value that contains `target` and `fnSel`.
    function _packCanExecute(address target, bytes4 fnSel) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := or(shl(96, target), shr(224, fnSel))
        }
    }

    /// @dev Increments the amount spent.
    function _incrementSpent(TokenSpendStorage storage s, address token, uint256 amount) internal {
        if (amount == uint256(0)) return; // Early return.
        uint8[] memory periods = s.periods.values();
        if (periods.length == 0) revert NoSpendPermissions();
        for (uint256 i; i < periods.length; ++i) {
            uint8 period = periods[i];
            LibBytes.BytesStorage storage $ = s.spends[period];
            TokenPeriodSpend memory tokenPeriodSpend = _loadSpend($);
            uint256 current = startOfSpendPeriod(block.timestamp, SpendPeriod(period));
            if (tokenPeriodSpend.lastUpdated < current) {
                tokenPeriodSpend.lastUpdated = current;
                tokenPeriodSpend.spent = 0;
            }
            if ((tokenPeriodSpend.spent += amount) > tokenPeriodSpend.limit) {
                revert ExceededSpendLimit(token);
            }
            _storeSpend($, tokenPeriodSpend);
        }
    }

    /// @dev Stores the spend struct.
    function _storeSpend(LibBytes.BytesStorage storage $, TokenPeriodSpend memory spend) internal {
        LibBytes.set($, LibZip.cdCompress(abi.encode(spend)));
    }

    /// @dev Loads the spend struct.
    function _loadSpend(LibBytes.BytesStorage storage $)
        internal
        view
        returns (TokenPeriodSpend memory spend)
    {
        bytes memory compressed = LibBytes.get($);
        if (compressed.length != 0) {
            bytes memory decoded = LibZip.cdDecompress(compressed);
            assembly ("memory-safe") {
                spend := add(decoded, 0x20) // Directly make `spend` point to the decoded.
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
        // key can always be used to change the account anyways.
        if (keyHash == bytes32(0)) revert KeyHashIsZero();
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Configurables
    ////////////////////////////////////////////////////////////////////////

    /// @dev To be overriden to return if `keyHash` corresponds to a super admin key.
    function _isSuperAdmin(bytes32 keyHash) internal view virtual returns (bool);

    /// @dev To be overriden to return the storage slot seed for a `keyHash`.
    function _getGuardedExecutorKeyStorageSeed(bytes32 keyHash)
        internal
        view
        virtual
        returns (bytes32);
}
