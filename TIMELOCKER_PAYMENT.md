# Timelocker Payment Implementation Plan

## Executive Summary

This document outlines the implementation plan for adding a fee mechanism to the Timelocker system, providing incentives for relayers to execute timelocked transactions. The design takes inspiration from the Intent payment system in `Orchestrator.sol` while considering that only the account owner will be the fee payer.

## Current State Analysis

### Intent Payment System (Orchestrator.sol)

The Intent system has a sophisticated payment mechanism:

1. **Payment Fields in Intent struct:**
   - `payer`: The account paying the payment token (defaults to EOA)
   - `paymentToken`: ERC20 or native token for gas payment
   - `paymentMaxAmount`: Maximum token amount to pay
   - `paymentAmount`: Actual payment amount requested by filler
   - `paymentRecipient`: Payment recipient (replaceable by filler)

2. **Payment Flow:**
   - Payment validation happens before execution
   - Uses `TokenTransferLib.safeTransfer()` for secure transfers
   - Tracks spending through `GuardedExecutor` spend limits
   - Atomic compensation ensures relayer gets paid even on revert

3. **Key Features:**
   - Gas-limited execution to prevent griefing
   - Fair compensation capped by signed amounts
   - Protection against account draining
   - Support for both ERC20 and native tokens

### Current Timelocker Implementation

1. **Timelocker struct:**
   - `executed`: Boolean tracking execution status
   - `keyHash`: Associated key that created the timelock
   - `readyTimestamp`: Unix timestamp for execution readiness

2. **executeTimelock function:**
   - Verifies timelock readiness and execution status
   - Recalculates digest from calls and nonce
   - Executes calls with appropriate key context
   - Updates storage to mark as executed

## Proposed Fee Structure

### 1. Enhanced Timelocker Struct

```solidity
struct Timelocker {
    bool executed;
    bytes32 keyHash;
    uint40 readyTimestamp;
    // New fee-related fields
    address paymentToken;      // Token for fee payment (address(0) for ETH)
    uint256 paymentAmount;     // Fee amount for execution
    address payer;             // Account paying the fee (always the account itself)
}
```

### 2. Fee Configuration During Timelock Creation

When creating a timelock (in the `execute` function with timelock-enabled keys):

```solidity
function _addTimelock(
    Timelocker memory timelocker,
    bytes32 digest,
    address paymentToken,
    uint256 paymentAmount
) internal virtual returns (bytes32 timelockHash) {
    // Store timelock with fee information
    AccountStorage storage $ = _getAccountStorage();
    $.timelockStorage[digest].set(
        abi.encode(
            timelocker.executed,
            timelocker.keyHash,
            timelocker.readyTimestamp,
            paymentToken,
            paymentAmount,
            address(this)  // payer is always the account itself
        )
    );
    $.timelockHashes.add(digest);
    return digest;
}
```

### 3. Enhanced executeTimelock Function

```solidity
function executeTimelock(
    Call[] calldata calls,
    uint256 nonce,
    address paymentRecipient  // Relayer specifies where to receive payment
) public virtual {
    // Recalculate digest from calls and nonce
    bytes32 digest = computeDigest(calls, nonce);

    // Get timelock with fee information
    Timelocker memory timelocker = getTimelock(digest);

    // Check if timelock is ready and not executed
    if (timelocker.readyTimestamp > block.timestamp) revert TimelockNotReady();
    if (timelocker.executed) revert TimelockAlreadyExecuted();

    // Process payment to relayer BEFORE execution (ensure compensation)
    if (timelocker.paymentAmount > 0) {
        TokenTransferLib.safeTransfer(
            timelocker.paymentToken,
            paymentRecipient,
            timelocker.paymentAmount
        );

        // Track spending if not super admin
        if (!_isSuperAdmin(timelocker.keyHash)) {
            SpendStorage storage spends = _getGuardedExecutorKeyStorage(timelocker.keyHash).spends;
            _incrementSpent(
                spends.executeSpends[timelocker.paymentToken],
                timelocker.paymentToken,
                timelocker.paymentAmount
            );
        }
    }

    // Execute the timelocked calls
    LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).push(timelocker.keyHash);
    _execute(calls, timelocker.keyHash);
    LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).pop();

    // Update storage to mark as executed
    AccountStorage storage $ = _getAccountStorage();
    bytes memory newData = abi.encode(
        true,  // executed
        timelocker.keyHash,
        timelocker.readyTimestamp,
        timelocker.paymentToken,
        timelocker.paymentAmount,
        timelocker.payer
    );
    $.timelockStorage[digest].set(newData);

    emit TimelockExecuted(digest, paymentRecipient, timelocker.paymentAmount);
}
```

## Implementation Considerations

### 1. Fee Configuration

- **During Timelock Creation**: When a transaction is queued with a timelock-enabled key, the user must specify:
  - Payment token (ETH or ERC20)
  - Payment amount (incentive for relayers)

- **Fee Storage**: Store fee information alongside timelock data in `timelockStorage`

### 2. Payment Security

- **Pre-execution Payment**: Pay relayer BEFORE execution to ensure compensation
- **Balance Checks**: Verify account has sufficient balance before payment
- **Spend Limits**: Integrate with GuardedExecutor spend tracking
- **Reentrancy Protection**: Use existing reentrancy guards

### 3. Relayer Incentives

- **Competitive Execution**: Any relayer can execute expired timelocks
- **Fair Compensation**: Fixed fee amount prevents bidding wars
- **Gas Coverage**: Fee should cover execution gas + profit margin
- **MEV Protection**: First-come-first-served for expired timelocks

### 4. Integration Points

- **GuardedExecutor**: Track timelock execution fees in spend limits
- **TokenTransferLib**: Use existing secure transfer infrastructure
- **Event System**: Emit enhanced events for indexing and monitoring

## Benefits

1. **Decentralized Execution**: Any relayer can execute expired timelocks
2. **Guaranteed Compensation**: Relayers paid even if execution fails
3. **Account Control**: Account owner sets and pays all fees
4. **Spending Limits**: Integrated with existing spend tracking
5. **Flexible Tokens**: Support for both ETH and ERC20 payments

## Risks and Mitigations

### Risk 1: Insufficient Fee
- **Risk**: Fee too low, no relayer executes
- **Mitigation**: Allow fee updates before execution deadline

### Risk 2: Account Drainage
- **Risk**: Malicious relayer drains account through fees
- **Mitigation**: Spend limits and one-time execution per timelock

### Risk 3: Front-running
- **Risk**: MEV bots compete for execution fees
- **Mitigation**: Fixed fees and first-come-first-served model

### Risk 4: Failed Execution
- **Risk**: Relayer loses gas on failed execution
- **Mitigation**: Pay before execution, similar to Intent system

## Next Steps

1. **Update Timelocker struct** with payment fields
2. **Modify _addTimelock** to accept and store fee parameters
3. **Enhance executeTimelock** with payment logic
4. **Update getTimelock** to decode new fields
5. **Add fee configuration** to timelock creation flow
6. **Integrate spend tracking** with GuardedExecutor
7. **Write comprehensive tests** for payment scenarios
8. **Gas optimization** and benchmarking
9. **Security audit** of payment flow

## Conclusion

The proposed fee mechanism for Timelocker execution follows proven patterns from the Intent system while simplifying for the single-payer model. This design ensures reliable incentivization for relayers while maintaining security and account control over spending.