# LayerZero Settlement System

## Overview

The LayerZeroSettler is a cross-chain settlement contract that uses LayerZero v2 for trustless message passing between chains. It implements the ISettler interface with a two-step process that separates settlement authorization from execution, enabling flexible execution patterns while maintaining security.

## Key Features

1. **Two-Step Settlement Process**: Separates authorization (by orchestrator) from execution (by anyone)
2. **Self-Execution Model**: Uses LayerZero without executor fees - messages must be manually executed on destination chains
3. **Direct msg.value Payment**: All fees are paid via msg.value when executing the settlement
4. **Endpoint ID Based**: Uses LayerZero endpoint IDs directly in settlerContext, no chain ID mapping needed
5. **Minimal Gas Usage**: No executor options means lower fees (only DVN verification costs)

## Architecture

```
Step 1: Authorization
Mainnet Orchestrator
    |
    v
LayerZeroSettler.send()
    |
    v
Stores authorization hash

Step 2: Execution (by anyone)
Executor with fees
    |
    v
LayerZeroSettler.executeSend{value: fees}()
    |
    +---> LayerZero Protocol ---> Arbitrum LayerZeroSettler
    |                              (records settlement)
    |
    +---> LayerZero Protocol ---> Base LayerZeroSettler
                                   (records settlement)
```

## Two-Step Settlement Flow

### Step 1: Authorization
The orchestrator authorizes a settlement after successfully executing the output intent:

```solidity
// Only the orchestrator can authorize settlements
settler.send(settlementId, settlerContext);
```

This stores a hash of `(sender, settlementId, settlerContext)` to validate future execution.

### Step 2: Execution
Anyone can execute a pre-authorized settlement by providing the exact parameters and fees:

```solidity
// Anyone can execute with proper fees
settler.executeSend{value: layerZeroFees}(
    orchestratorAddress,  // Original sender who authorized
    settlementId,         // Same settlement ID
    settlerContext        // Same settler context
);
```

## Usage

### 1. Prepare Settler Context
```solidity
// Encode LayerZero endpoint IDs for destination chains
uint32[] memory endpointIds = new uint32[](2);
endpointIds[0] = 30110; // Arbitrum endpoint ID
endpointIds[1] = 30184; // Base endpoint ID
bytes memory settlerContext = abi.encode(endpointIds);
```

### 2. Authorize Settlement (Orchestrator Only)
```solidity
// From orchestrator after successful output intent
settler.send(settlementId, settlerContext);
```

### 3. Execute Settlement (Anyone)
```solidity
// Can be called by orchestrator or any third party
// msg.value must cover all LayerZero fees
settler.executeSend{value: totalFees}(
    orchestratorAddress,
    settlementId,
    settlerContext
);
```

The fees are paid from msg.value, and any excess is refunded to the caller.

### 4. Execute Messages on Destination (Self-Execution)
After DVN verification, anyone can execute the messages on destination chains by calling `lzReceive` through the LayerZero endpoint.

### 5. Escrows Check Settlement Status
```solidity
// In escrow contract
bool isSettled = settler.read(settlementId, orchestrator, sourceChainId);
if (isSettled) {
    // Release funds
}
```

## Gas Costs

- **Authorization (send)**: ~50k gas (just stores a hash)
- **Execution (executeSend)**: ~90k gas base + ~45k per destination chain
- **Per Message Fee**: ~0.0005 ETH (DVN fees only, no executor fees)
- **Total Cost**: Number of chains × per-message fee
- **Payment**: All fees must be provided via msg.value in executeSend

## Common LayerZero Endpoint IDs

| Chain     | Endpoint ID |
|-----------|-------------|
| Mainnet   | 30101       |
| Arbitrum  | 30110       |
| Base      | 30184       |
| Optimism  | 30111       |
| Polygon   | 30109       |

## Security Benefits of Two-Step Process

1. **Authorization Control**: Only the orchestrator can authorize settlements
2. **Execution Flexibility**: Anyone can execute, enabling various execution patterns
3. **Replay Protection**: Each authorization is unique to (sender, settlementId, settlerContext)
4. **No Front-Running**: Authorization doesn't reveal fee amounts or timing
5. **Atomic Execution**: All messages sent in one transaction or none at all

## Benefits

1. **Trustless**: No reliance on centralized oracles
2. **Flexible Execution**: Separation of authorization and execution enables batching and third-party execution
3. **Cost-Effective**: Self-execution saves executor fees
4. **Simple**: Minimal code (~104 lines), easy to audit
5. **Compatible**: Works with existing escrow system
6. **No Balance Management**: Uses msg.value directly, no need to fund the settler
7. **Gas Efficient**: Two-step process minimizes storage operations