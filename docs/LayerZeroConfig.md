# LayerZero Settler Configuration Guide

This guide covers the complete configuration process for the LayerZero Settler after deployment.

## Prerequisites

- LayerZero Settler deployed on all target chains
- Access to the owner wallet for each deployed settler
- Cast CLI tool installed
- RPC URLs for all target chains

## LayerZero V2 Mainnet Configuration

### Endpoint Addresses

All major EVM chains use the same LayerZero V2 endpoint address:
```
0x1a44076050125825900e736c501f859c50fE728c
```

You should verify all addresses and EIDs before mainnet deployments from here - https://docs.layerzero.network/v2/deployments/deployed-contracts

### Endpoint IDs (EIDs)

| Chain | Chain ID | Endpoint ID (EID) |
|-------|----------|-------------------|
| Ethereum | 1 | 30101 |
| Arbitrum One | 42161 | 30110 |
| Optimism | 10 | 30111 |
| Polygon | 137 | 30109 |
| Base | 8453 | 30184 |
| Avalanche | 43114 | 30106 |
| BSC | 56 | 30102 |

## Step 1: Deploy on All Target Chains

Deploy the LayerZero Settler on each chain:

```bash
# Example for Ethereum
L0_ENDPOINT=0x1a44076050125825900e736c501f859c50fE728c \
SETTLER_OWNER=0xYourOwnerAddress \
forge script script/DeployL0.s.sol:DeployL0Script \
  --rpc-url $ETH_RPC_URL \
  --broadcast \
  --verify

# Repeat for other chains with their respective RPC URLs
```

## Step 2: Configure Peers

After deployment, configure peers on each chain to enable cross-chain communication.

### Convert Addresses to bytes32

LayerZero uses bytes32 for peer addresses to support non-EVM chains:

```bash
# Convert address to bytes32
PEER_BYTES32=$(cast to-bytes32 0xPeerSettlerAddress)
```

### Set Peers Using Cast

For each deployed settler, set peers for all other chains:

```bash
# On Ethereum, set Arbitrum peer
cast send $ETH_SETTLER "setPeer(uint32,bytes32)" 30110 $(cast to-bytes32 $ARB_SETTLER) \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY

# On Ethereum, set Optimism peer
cast send $ETH_SETTLER "setPeer(uint32,bytes32)" 30111 $(cast to-bytes32 $OP_SETTLER) \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY

# Continue for all chain combinations...
```

### Verify Peer Configuration

Check that peers are correctly set:

```bash
# Check Arbitrum peer on Ethereum settler
cast call $ETH_SETTLER "peers(uint32)" 30110 --rpc-url $ETH_RPC_URL
```

## Step 3: Configure OApp Settings

### DVN (Decentralized Verifier Network) Configuration

Each messaging path requires DVN configuration for security. The settler inherits from OApp, which allows configuration through the endpoint.

```bash
# Example: Configure DVN for Ethereum -> Arbitrum path
# This is typically done through the LayerZero SDK or UI
```

