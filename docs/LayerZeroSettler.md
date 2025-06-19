# LayerZero Settlement System

## Overview

The LayerZeroSettler is a cross-chain settlement contract that uses LayerZero v2 for trustless message passing between chains. It implements the ISettler interface and enables the orchestrator to notify multiple chains about successful settlements.

## Key Features

1. **Self-Execution Model**: Uses LayerZero without executor fees - messages must be manually executed on destination chains
2. **Direct msg.value Payment**: All fees are paid via msg.value forwarded from the orchestrator
3. **Endpoint ID Based**: Uses LayerZero endpoint IDs directly in settlerContext, no chain ID mapping needed
4. **Minimal Gas Usage**: No executor options means lower fees (only DVN verification costs)

## Architecture

```
Mainnet Orchestrator
    |
    v
LayerZeroSettler (send)
    |
    +---> LayerZero Protocol ---> Arbitrum LayerZeroSettler
    |                              (records settlement)
    |
    +---> LayerZero Protocol ---> Base LayerZeroSettler
                                   (records settlement)
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

### 2. Send Settlement Notifications
```solidity
// From orchestrator after successful output intent
// msg.value is forwarded from the multi-chain intent execution
settler.send{value: msg.value}(settlementId, settlerContext);
```

The orchestrator automatically forwards all msg.value to the settler, which uses it to pay for LayerZero messaging fees. Any excess is refunded to the orchestrator.

### 3. Execute Messages (Self-Execution)
After DVN verification, anyone can execute the messages on destination chains by calling `lzReceive` through the LayerZero endpoint.

### 4. Escrows Check Settlement Status
```solidity
// In escrow contract
bool isSettled = settler.read(settlementId, orchestrator, sourceChainId);
if (isSettled) {
    // Release funds
}
```

## Gas Costs

- **Per Message**: ~0.0005 ETH (DVN fees only, no executor fees)
- **Total Cost**: Number of chains × per-message fee
- **Payment**: All fees must be provided via msg.value

## Common LayerZero Endpoint IDs

| Chain     | Endpoint ID |
|-----------|-------------|
| Mainnet   | 30101       |
| Arbitrum  | 30110       |
| Base      | 30184       |

## Benefits

1. **Trustless**: No reliance on centralized oracles
2. **Cost-Effective**: Self-execution saves executor fees
3. **Simple**: Minimal code, easy to audit
4. **Compatible**: Works with existing escrow system
5. **No Balance Management**: Uses msg.value directly, no need to fund the settler