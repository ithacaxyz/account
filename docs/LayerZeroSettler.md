# LayerZero Settlement System

## Overview

The LayerZeroSettler is a cross-chain settlement contract that uses LayerZero v2 for trustless message passing between chains. It implements the ISettler interface and enables the orchestrator to notify multiple chains about successful settlements.

## Key Features

1. **Self-Execution Model**: Uses LayerZero without executor fees - messages must be manually executed on destination chains
2. **Overfund & Refund Pattern**: Contract holds ETH balance and pays exact fees per message
3. **Simple Interface**: Maintains compatibility with existing ISettler interface
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

### 1. Fund the Settler
```solidity
// Send ETH to settler for operation
payable(address(settler)).transfer(0.1 ether);
```

### 2. Send Settlement Notifications
```solidity
// From orchestrator after successful output intent
uint256[] memory inputChains = new uint256[](2);
inputChains[0] = 42161; // Arbitrum
inputChains[1] = 8453;  // Base

settler.send(settlementId, inputChains);
```

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

## Benefits

1. **Trustless**: No reliance on centralized oracles
2. **Cost-Effective**: Self-execution saves executor fees
3. **Simple**: Minimal code, easy to audit
4. **Compatible**: Works with existing escrow system