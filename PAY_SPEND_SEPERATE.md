# Test Case Changes Required for Separate Pay Spends Storage

## Overview
The code changes introduced a separate `paySpends` mapping within `SpendStorage` to track payment-related spending separately from execution-related spending. This affects how spend limits are enforced and tracked for payment operations vs execution operations.

## Key Changes Made

### 1. Storage Structure Update (`GuardedExecutor.sol:175`)
```solidity
struct SpendStorage {
    EnumerableSetLib.AddressSet tokens;
    mapping(address => TokenSpendStorage) spends;     // Execution-related spends
    mapping(address => TokenSpendStorage) paySpends;  // Payment-related spends (NEW)
}
```

### 2. Payment Tracking Update (`IthacaAccount.sol:772`)
```solidity
// Changed from: spends.spends[intent.paymentToken]
// Changed to:   spends.paySpends[intent.paymentToken]
_incrementSpent(spends.paySpends[intent.paymentToken], intent.paymentToken, paymentAmount);
```

## Required Test Case Modifications

### 1. Update Spend Limit Setup for Payment Tokens
**Location**: `test/GuardedExecutor.t.sol:839-841`

**Current Code**:
```solidity
calls[3] = _setSpendLimitCall(
    k, u.paymentToken, GuardedExecutor.SpendPeriod.Day, type(uint192).max
);
```

**Issue**: This sets spend limits on the `spends` mapping, but payments now use the `paySpends` mapping. The test will fail because there are no spend permissions configured for payments.

**Required Changes**:
1. **Add a new function** to set spend limits specifically for payment operations
2. **Or modify the existing test** to set both execution and payment spend limits
3. **Or create separate test scenarios** for execution vs payment spending

### 2. Update Spend Tracking Assertions
**Location**: `test/GuardedExecutor.t.sol:853-854, 873-874`

**Current Assertions**:
```solidity
assertEq(d.d.spendInfos(k.keyHash)[1].token, u.paymentToken);
assertEq(d.d.spendInfos(k.keyHash)[1].spent, 1 ether);
```

**Issue**: `spendInfos()` only returns information from the `spends` mapping, not `paySpends`. Payment spending won't be reflected in these assertions.

**Required Changes**:
1. **Add a new function** `paySpendInfos()` to query payment spend information
2. **Or modify `spendInfos()`** to include both execution and payment spend data
3. **Update assertions** to check the correct spend tracking mechanism

## Specific Test Functions Affected

### `_testSpendWithPassKeyViaOrchestrator()` (lines 808-941)
- **Setup phase**: Payment token spend limits need to be configured for `paySpends`
- **Assertion phase**: Payment spending validation needs to check `paySpends` data

### Potential New Functions Needed

```solidity
// In GuardedExecutor.sol - Add payment-specific spend limit functions
function setPaySpendLimit(bytes32 keyHash, address token, SpendPeriod period, uint256 limit) public virtual onlyThis;
function removePaySpendLimit(bytes32 keyHash, address token, SpendPeriod period) public virtual onlyThis;
function paySpendInfos(bytes32 keyHash) public view virtual returns (SpendInfo[] memory);

// In Base.t.sol - Add helper functions
function _setPaySpendLimitCall(PassKey memory k, address token, GuardedExecutor.SpendPeriod period, uint256 limit) internal returns (ERC7821.Call memory);
function _removePaySpendLimitCall(PassKey memory k, address token, GuardedExecutor.SpendPeriod period) internal returns (ERC7821.Call memory);
```

## Implementation Options

### Option 1: Add Separate Payment Spend Functions
- Create `setPaySpendLimit()`, `paySpendInfos()`, etc.
- Update tests to use payment-specific functions
- Maintains clear separation between execution and payment spending

### Option 2: Unified Spend Limit Management
- Modify existing functions to manage both `spends` and `paySpends`
- Add a parameter or flag to specify which type of spending
- Update `spendInfos()` to return combined data

### Option 3: Automatic Mirroring
- Automatically copy spend limits from `spends` to `paySpends` when set
- Maintain backward compatibility
- May not provide the desired separation of concerns

## Recommended Approach

**Option 1** is recommended as it:
- Maintains clear separation of execution vs payment spending
- Allows for different spend limits for different operation types
- Provides explicit control over payment spending limits
- Aligns with the architectural decision to separate payment spending

## Test Files Requiring Updates

1. **`test/GuardedExecutor.t.sol`** - Primary file with payment spending tests
2. **`test/Base.t.sol`** - May need helper function additions
3. **`test/Account.t.sol`** - If it contains payment-related tests
4. **`test/Orchestrator.t.sol`** - If it validates payment spending behavior

## Next Steps

1. Implement the missing payment spend limit functions in `GuardedExecutor.sol`
2. Add corresponding helper functions in test files
3. Update test cases to use payment-specific spend limit setup
4. Verify all payment-related spending tests pass with the new separation