# Timelock Implementation Plan

## Overview

Adding a comprehensive timelock system with `Timelocker` struct and `TimelockerStorage` to manage queued operations that must wait before execution.

## Proposed Structures

### Timelocker Struct

```solidity
/// @dev A queued operation waiting for timelock delay
struct Timelocker {
    /// @dev Whether this timelocker has been executed
    bool executed;
    /// @dev Hash of the key that queued this operation
    bytes32 keyHash;
    /// @dev Timestamp when this operation becomes ready for execution
    uint40 readyTimestamp;
    /// @dev The execution data (encoded calls)
    bytes executionData;
}
```

### TimelockerStorage Integration

```solidity
/// @dev Storage for timelock operations
struct TimelockerStorage {
    /// @dev Counter for unique timelocker IDs
    uint256 nextTimelockerId;
    /// @dev Mapping of timelocker ID to Timelocker data
    mapping(uint256 => Timelocker) timelocks;
    /// @dev Set of active timelocker IDs for enumeration
    EnumerableSetLib.Uint256Set activeTimelocks;
    /// @dev Mapping from key hash to their active timelocker IDs
    mapping(bytes32 => EnumerableSetLib.Uint256Set) keyTimelocks;
}
```

### AccountStorage Updates

```solidity
/// @dev Holds the storage.
struct AccountStorage {
    /// @dev The label.
    LibBytes.BytesStorage label;
    /// @dev Mapping for 4337-style 2D nonce sequences.
    mapping(uint192 => LibStorage.Ref) nonceSeqs;
    /// @dev Set of key hashes for onchain enumeration of authorized keys.
    EnumerableSetLib.Bytes32Set keyHashes;
    /// @dev Mapping of key hash to the key in encoded form.
    mapping(bytes32 => LibBytes.BytesStorage) keyStorage;
    /// @dev Mapping of key hash to the key's extra storage.
    mapping(bytes32 => LibStorage.Bump) keyExtraStorage;
    /// @dev Storage for timelock operations
    TimelockerStorage timelocks;
}
```

## Implementation Implications

### 1. Storage Layout Impact

**Backwards Compatibility**: ✅ **SAFE**
- Adding new fields to the end of `AccountStorage` is backwards compatible
- Existing storage slots remain unchanged
- No migration required for existing accounts

**Gas Costs**:
- **Queue Operation**: ~45,000 gas (new storage + enumeration updates)
- **Execute Operation**: ~25,000 gas (state updates + cleanup)
- **Cancel Operation**: ~20,000 gas (cleanup operations)

### 2. New Functions Required

#### Core Timelock Functions

```solidity
/// @dev Queue an operation for timelock delay
function queueOperation(ERC7821.Call[] calldata calls, bytes32 keyHash) 
    external returns (uint256 timelockerId);

/// @dev Execute a ready timelock operation
function executeTimelock(uint256 timelockerId) external;

/// @dev Cancel a pending timelock operation
function cancelTimelock(uint256 timelockerId) external;

/// @dev Get timelock operation details
function getTimelock(uint256 timelockerId) external view returns (Timelocker memory);

/// @dev Get all active timelocks for a key
function getKeyTimelocks(bytes32 keyHash) external view returns (uint256[] memory);
```

#### View Functions

```solidity
/// @dev Check if timelock operation is ready
function isTimelockReady(uint256 timelockerId) external view returns (bool);

/// @dev Get all active timelocks
function getActiveTimelocks() external view returns (uint256[] memory);

/// @dev Get timelock count
function getTimelockCount() external view returns (uint256);
```

### 3. Integration Points

#### Modified Execution Flow

```solidity
// In _execute() function (line 731):
if (getKey(keyHash).timelock > 0) {
    // Queue operation instead of immediate execution
    uint256 timelockerId = _queueOperation(calls, keyHash);
    emit OperationQueued(timelockerId, keyHash, block.timestamp + getKey(keyHash).timelock);
} else {
    // Immediate execution (current behavior)
    LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).push(keyHash);
    _execute(calls, keyHash);
    LibTStack.TStack(_KEYHASH_STACK_TRANSIENT_SLOT).pop();
}
```

#### Event Definitions

```solidity
/// @dev A timelock operation has been queued
event OperationQueued(uint256 indexed timelockerId, bytes32 indexed keyHash, uint256 readyTimestamp);

/// @dev A timelock operation has been executed
event OperationExecuted(uint256 indexed timelockerId, bytes32 indexed keyHash);

/// @dev A timelock operation has been cancelled
event OperationCancelled(uint256 indexed timelockerId, bytes32 indexed keyHash);
```

### 4. Security Considerations

#### Access Control
- **Queue**: Only the key holder can queue operations
- **Execute**: Anyone can execute ready operations (public good)
- **Cancel**: Only super admin keys or original key can cancel

#### Reentrancy Protection
- Use existing reentrancy guards from GuardedExecutor
- Prevent multiple executions of the same timelock
- Protect against cancellation during execution

#### Grace Period Handling
```solidity
uint256 public constant GRACE_PERIOD = 2 weeks;

modifier onlyWithinGracePeriod(uint256 timelockerId) {
    Timelocker storage tl = _getAccountStorage().timelocks.timelocks[timelockerId];
    if (block.timestamp > tl.readyTimestamp + GRACE_PERIOD) {
        revert GracePeriodExpired();
    }
    _;
}
```

### 5. Error Handling

```solidity
/// @dev The timelock operation does not exist
error TimelockNotFound();

/// @dev The timelock operation is not ready for execution
error TimelockNotReady();

/// @dev The timelock operation has already been executed
error TimelockAlreadyExecuted();

/// @dev The timelock grace period has expired
error GracePeriodExpired();

/// @dev Only authorized parties can cancel timelocks
error UnauthorizedCancellation();
```

## Implementation Phases

### Phase 1: Core Infrastructure (Week 1)
1. **Add struct definitions**
   - Timelocker struct
   - TimelockerStorage struct
   - Update AccountStorage

2. **Basic storage functions**
   - Storage pointer functions
   - Internal helpers for timelock management

3. **Core events**
   - Define all timelock-related events

### Phase 2: Core Functionality (Week 2)
1. **Queue operations**
   - Implement `queueOperation()` function
   - Integration with existing execution flow
   - Proper access control

2. **Execute operations**
   - Implement `executeTimelock()` function
   - Reentrancy protection
   - Grace period enforcement

3. **Cancel operations**
   - Implement `cancelTimelock()` function
   - Authorization checks

### Phase 3: View Functions & Utilities (Week 3)
1. **View functions**
   - All getter functions
   - Enumeration helpers
   - Status checking functions

2. **Integration testing**
   - Comprehensive test suite
   - Edge case testing
   - Gas optimization

### Phase 4: Advanced Features (Week 4)
1. **Batch operations**
   - Queue multiple operations
   - Cancel multiple operations

2. **Emergency controls**
   - Emergency pause for timelocks
   - Super admin overrides

3. **Gas optimizations**
   - Optimize storage access
   - Batch state updates

## Migration Strategy

### Deployment Strategy
1. **No storage migration required** - new fields are appended
2. **Gradual rollout** with feature flags
3. **Backwards compatibility maintained**

### Testing Strategy
1. **Unit tests** for each function
2. **Integration tests** with existing functionality  
3. **Fuzz testing** for edge cases
4. **Gas benchmarking** for performance analysis

## Integration with Existing Features

### GuardedExecutor Compatibility
- Timelock operations respect existing spend limits
- Super admin keys maintain override capabilities
- Call checkers apply to timelock executions

### Orchestrator Integration
- Intent-based operations can queue timelocks
- Payment flows work with queued operations
- Multi-chain compatibility maintained

### Key Management Harmony
- Timelock values are per-key configurable
- Key revocation cancels pending timelocks
- Super admin keys can bypass timelock delays

## Gas Cost Analysis

### Current vs New Costs

| Operation | Current Gas | With Timelock | Delta |
|-----------|-------------|---------------|-------|
| Immediate Execute | ~200,000 | ~200,000 | 0 |
| Queue Operation | N/A | ~245,000 | +45,000 |
| Execute Queued | N/A | ~225,000 | +25,000 |
| Cancel Operation | N/A | ~20,000 | +20,000 |

### Optimization Opportunities
1. **Packed storage** for Timelocker struct
2. **Batch operations** to amortize costs
3. **Lazy cleanup** for expired timelocks

## Conclusion

The proposed timelock implementation provides:
- ✅ **Complete backwards compatibility**
- ✅ **Comprehensive timelock functionality**
- ✅ **Flexible per-key configuration**
- ✅ **Robust security model**
- ✅ **Reasonable gas costs**
- ✅ **Clean integration patterns**

The phased implementation approach ensures minimal risk while delivering powerful timelock capabilities that enhance the security model of the IthacaAccount system.

**Recommendation**: Proceed with Phase 1 implementation, focusing on core infrastructure and maintaining the existing functionality while building the foundation for timelock operations.