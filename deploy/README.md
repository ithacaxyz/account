# Ithaca Account Multichain Deployment System

A composable, retry-enabled deployment system for deploying Ithaca Account infrastructure across multiple EVM chains using Foundry scripts.

## Overview

The deployment system is split into four independent stages that can be run separately or together:

1. **Basic** - Core contracts (Orchestrator, IthacaAccount, Proxy, Simulator)
2. **Interop** - Interoperability contracts (SimpleFunder, Escrow)
3. **Settlement** - Settlement contracts (SimpleSettler or LayerZeroSettler)
4. **LayerZero Config** - Cross-chain peer configuration

Each stage tracks its own deployment state and supports automatic retries on failure.

## Quick Start

### Deploy Everything to Testnet

```bash
# Set up environment variables
export TESTNET_PAUSE_AUTHORITY=0x...
export TESTNET_FUNDER_SIGNER=0x...
export TESTNET_FUNDER_OWNER=0x...
export TESTNET_SETTLER_OWNER=0x...
export TESTNET_L0_SETTLER_OWNER=0x...

# Deploy all stages
forge script deploy/DeployAll.s.sol:DeployAll \
  --broadcast \
  --sig "run(string)" \
  "deploy/config/deployment/testnet.json"
```

### Deploy Individual Stages

```bash
# Deploy only basic contracts
forge script deploy/DeployBasic.s.sol:DeployBasic \
  --broadcast \
  --sig "run(string)" \
  "deploy/config/deployment/mainnet.json"

# Deploy only interop contracts
forge script deploy/DeployInterop.s.sol:DeployInterop \
  --broadcast \
  --sig "run(string)" \
  "deploy/config/deployment/mainnet.json"

# Deploy settlement contracts
forge script deploy/DeploySettlement.s.sol:DeploySettlement \
  --broadcast \
  --sig "run(string)" \
  "deploy/config/deployment/mainnet.json"

# Configure LayerZero peers
forge script deploy/ConfigureLayerZero.s.sol:ConfigureLayerZero \
  --broadcast \
  --sig "run(string)" \
  "deploy/config/deployment/mainnet.json"
```

### Check Deployment Status

```bash
# View comprehensive deployment status
forge script deploy/DeploymentStatus.s.sol:DeploymentStatus \
  --sig "run(string)" \
  "mainnet"
```

## Configuration

### Directory Structure

```
deploy/
├── config/
│   ├── chains/               # Chain lists per environment
│   │   ├── mainnet.json     # Mainnet chain IDs
│   │   ├── testnet.json     # Testnet chain IDs
│   │   └── devnet.json      # Local devnet configuration
│   ├── contracts/            # Contract parameters per environment
│   │   ├── mainnet.json     # Mainnet addresses and settings
│   │   ├── testnet.json     # Testnet addresses and settings
│   │   └── devnet.json      # Devnet addresses and settings
│   └── deployment/           # Deployment behavior configuration
│       ├── mainnet.json     # Mainnet deployment settings
│       ├── testnet.json     # Testnet deployment settings
│       └── devnet.json      # Devnet deployment settings
├── registry/                 # Deployment state (auto-generated)
│   ├── basic-contracts.json
│   ├── interop-contracts.json
│   ├── settlement-contracts.json
│   └── lz-peer-config.json
└── *.sol                     # Deployment scripts
```

### Environment Variables

The system uses environment variables for sensitive configuration:

```bash
# Mainnet
export MAINNET_PAUSE_AUTHORITY=0x...
export MAINNET_FUNDER_SIGNER=0x...
export MAINNET_FUNDER_OWNER=0x...
export MAINNET_SETTLER_OWNER=0x...
export MAINNET_L0_SETTLER_OWNER=0x...

# Testnet (use TESTNET_ prefix)
# Devnet (use DEVNET_ prefix or hardcoded in config)

# RPC URLs (required for each chain)
export MAINNET_RPC_URL=https://...
export SEPOLIA_RPC_URL=https://...
# etc...
```

### Adding New Chains

1. Add chain to `/deploy/config/chains.json`:
```json
{
  "250": {
    "name": "Fantom",
    "rpcUrl": "${FANTOM_RPC_URL}",
    "layerZeroEndpoint": "0x...",
    "layerZeroEid": 30112
  }
}
```

2. Add chain ID to environment config:
```json
// deploy/config/chains/mainnet.json
{
  "chains": [1, 42161, 8453, 250]
}
```

## Features

### Automatic Retry

Failed deployments automatically retry based on configuration:
- `maxRetries`: Number of retry attempts (default: 3)
- `retryDelay`: Seconds between retries (default: 5)

### State Persistence

Deployment state is saved to `registry/` allowing:
- Resume from failure without re-deploying successful contracts
- Track deployment progress across multiple runs
- Audit trail of all deployments

### Composable Settlement

Choose settlement type per environment:
- **SimpleSettler**: For devnets and testing
- **LayerZeroSettler**: For cross-chain production deployments

Configure in `contracts/{environment}.json`:
```json
{
  "default": {
    "settlerType": "simple"  // or "layerzero"
  }
}
```

### Clean Status Display

The `DeploymentStatus` script provides:
- Progress bars for each chain
- Color-coded status indicators
- Next steps guidance
- Cross-chain configuration overview

## Deployment Flow

### 1. Basic Deployment
- Deploys Orchestrator with pause authority
- Deploys IthacaAccount implementation
- Deploys account proxy
- Deploys Simulator

### 2. Interop Deployment
- Requires Basic contracts
- Deploys SimpleFunder with signer and owner
- Deploys Escrow

### 3. Settlement Deployment
- Requires Basic contracts
- Deploys SimpleSettler OR LayerZeroSettler based on config
- For LayerZero: stores endpoint and EID information

### 4. LayerZero Configuration
- Requires 2+ LayerZero settlers
- Sets up bidirectional peer connections
- Enables cross-chain messaging

## Troubleshooting

### Deployment Failures

1. Check the specific error in console output
2. Fix the issue (funding, configuration, etc.)
3. Run the same command again - it will retry only failed deployments

### "Contract not found" Errors

Ensure you run stages in order:
1. Basic (always first)
2. Interop and/or Settlement (can run in parallel)
3. LayerZero Config (only after Settlement with LZ settlers)

### RPC Issues

- Ensure RPC URLs are set for all target chains
- Check rate limits on your RPC provider
- Consider using `--slow` flag for Forge

### Gas Issues

- Ensure deployer has sufficient native tokens
- Adjust gas settings in Foundry configuration
- Use `--gas-price` flag if needed

## Advanced Usage

### Dry Run Mode

Test deployment without broadcasting:
```json
// deploy/config/deployment/testnet.json
{
  "dryRun": true
}
```

### Custom Stage Selection

Deploy only specific stages:
```bash
forge script deploy/DeployAll.s.sol:DeployAll \
  --broadcast \
  --sig "run(string,string[])" \
  "deploy/config/deployment/mainnet.json" \
  '["basic","settlement"]'
```

### Chain-Specific Configuration

Override default settings per chain:
```json
// deploy/config/contracts/mainnet.json
{
  "default": {
    "pauseAuthority": "0xAAA..."
  },
  "8453": {  // Base-specific override
    "pauseAuthority": "0xBBB..."
  }
}
```

## Security Considerations

1. **Never commit private keys** - Use hardware wallets or secure key management
2. **Verify addresses** - Double-check all configuration before mainnet deployment
3. **Test on testnet first** - Always deploy to testnet before mainnet
4. **Review registry files** - Check deployed addresses match expectations
5. **Validate cross-chain config** - Ensure correct peer addresses for LayerZero

## Contributing

When adding new contracts or deployment stages:

1. Extend `BaseDeployment` for retry and state management
2. Follow the naming convention: `Deploy{Stage}.s.sol`
3. Update `DeployAll` to include new stage
4. Add registry file for state tracking
5. Update `DeploymentStatus` to display new contracts