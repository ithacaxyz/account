# Deployment Configuration Reference

This document provides a quick reference for all deployment configuration files.

## Configuration Files Overview

```
deploy/config/
├── chains.json                 # Global chain information
├── chains/                     # Target chains per environment
│   ├── mainnet.json
│   ├── testnet.json
│   └── devnet.json
├── contracts/                  # Contract addresses per environment
│   ├── mainnet.json
│   ├── testnet.json
│   └── devnet.json
└── deployment/                 # Deployment parameters per environment
    ├── mainnet.json
    ├── testnet.json
    └── devnet.json
```

## Configuration File Formats

### chains.json
Global chain configuration with network details:

```json
{
  "1": {
    "name": "Ethereum Mainnet",
    "layerZeroEndpoint": "0x1a44076050125825900e736c501f859c50fE728c",
    "layerZeroEid": 30101,
    "isTestnet": false
  }
}
```

### chains/{environment}.json
Specifies which chains to deploy to:

```json
{
  "chains": [1, 42161, 8453]
}
```

### contracts/{environment}.json
Contract addresses and configuration:

```json
{
  "pauseAuthority": "0x...",
  "funderSigner": "0x...",
  "funderOwner": "0x...",
  "settlerOwner": "0x...",
  "l0SettlerOwner": "0x...",
  "settlerType": "layerzero"  // or "simple"
}
```

### deployment/{environment}.json
Deployment execution parameters:

```json
{
  "environment": "mainnet",
  "dryRun": false,
  "maxRetries": 3,
  "retryDelay": 5
}
```

## Environment Variables

Required format for RPC URLs:
```bash
RPC_{chainId}=https://rpc-url...
```

Example:
```bash
RPC_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_42161=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
```

## Adding a New Environment

1. Create new files:
   - `deploy/config/chains/myenv.json`
   - `deploy/config/contracts/myenv.json`
   - `deploy/config/deployment/myenv.json`

2. Configure each file according to the formats above

3. Run deployment:
   ```bash
   forge script deploy/DeployAll.s.sol:DeployAll --sig "run(string)" "myenv" --broadcast
   ```

## Settler Type Configuration

The `settlerType` in contracts config determines which settler to deploy:
- `"simple"` - Deploys SimpleSettler (single chain)
- `"layerzero"` - Deploys LayerZeroSettler (cross-chain)

LayerZero settlers require:
- At least 2 chains in the deployment
- Valid LayerZero endpoints configured in chains.json
- Running ConfigureLayerZero script after deployment