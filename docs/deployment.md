# Deployment Guide

This guide explains how to deploy the Ithaca Account contracts across multiple chains using the simplified JSON-based configuration system.

## Overview

The deployment system uses Foundry scripts with JSON configuration files to manage multi-chain deployments. All contract addresses and parameters are stored directly in JSON files, while only RPC URLs and private keys are provided via environment variables.

## Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Access to RPC endpoints for target chains
- Deployment private key with sufficient funds on all target chains

## Configuration Structure

### 1. Chain Configuration (`deploy/config/chains.json`)

Defines all supported chains with their network details:

```json
{
  "1": {
    "name": "Ethereum Mainnet",
    "layerZeroEndpoint": "0x1a44076050125825900e736c501f859c50fE728c",
    "layerZeroEid": 30101
  },
  "42161": {
    "name": "Arbitrum One",
    "layerZeroEndpoint": "0x1a44076050125825900e736c501f859c50fE728c",
    "layerZeroEid": 30110
  }
}
```

### 2. Contract Configuration (`deploy/config/contracts/{environment}.json`)

Defines deployment addresses for each environment (mainnet, testnet, devnet):

```json
{
  "pauseAuthority": "0x1234567890123456789012345678901234567890",
  "funderSigner": "0x2345678901234567890123456789012345678901",
  "funderOwner": "0x3456789012345678901234567890123456789012",
  "settlerOwner": "0x4567890123456789012345678901234567890123",
  "l0SettlerOwner": "0x5678901234567890123456789012345678901234",
  "settlerType": "layerzero"
}
```

### 3. Deployment Parameters (`deploy/config/deployment/{environment}.json`)

Controls deployment behavior:

```json
{
  "environment": "mainnet",
  "dryRun": false,
  "maxRetries": 3,
  "retryDelay": 5
}
```

### 4. Target Chains (`deploy/config/chains/{environment}.json`)

Specifies which chains to deploy to:

```json
{
  "chains": [1, 42161, 8453]
}
```

## Environment Variables

### Required for All Deployments

```bash
# Private key for deployment
PRIVATE_KEY=0x...

# RPC URLs for each chain (format: RPC_{chainId})
RPC_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_42161=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_8453=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
```

### Optional for Verification

```bash
# Block explorer API keys
ETHERSCAN_API_KEY=YOUR_KEY
ARBISCAN_API_KEY=YOUR_KEY
BASESCAN_API_KEY=YOUR_KEY
```

## Deployment Scripts

### 1. Deploy Basic Contracts

Deploys core contracts: Orchestrator, IthacaAccount, Proxy, and Simulator.

```bash
forge script deploy/DeployBasic.s.sol:DeployBasic \
  --sig "run(string)" "mainnet" \
  --broadcast \
  --verify
```

### 2. Deploy Interop Contracts

Deploys SimpleFunder and Escrow contracts (requires Basic contracts).

```bash
forge script deploy/DeployInterop.s.sol:DeployInterop \
  --sig "run(string)" "mainnet" \
  --broadcast \
  --verify
```

### 3. Deploy Settlement Contracts

Deploys settlement infrastructure (SimpleSettler or LayerZeroSettler based on config).

```bash
forge script deploy/DeploySettlement.s.sol:DeploySettlement \
  --sig "run(string)" "mainnet" \
  --broadcast \
  --verify
```

### 4. Configure LayerZero

Sets up cross-chain peer connections for LayerZero settlers (requires at least 2 chains).

```bash
forge script deploy/ConfigureLayerZero.s.sol:ConfigureLayerZero \
  --sig "run(string)" "mainnet" \
  --broadcast
```

### 5. Deploy All Stages

Runs all deployment stages in sequence:

```bash
forge script deploy/DeployAll.s.sol:DeployAll \
  --sig "run(string)" "mainnet" \
  --broadcast \
  --verify
```

Or deploy specific stages:

```bash
forge script deploy/DeployAll.s.sol:DeployAll \
  --sig "runWithStages(string,string[])" "mainnet" '["basic","interop"]' \
  --broadcast
```

## Multi-Chain Deployment Example

Deploy to Ethereum, Arbitrum, and Base mainnet:

```bash
# Set environment variables
export PRIVATE_KEY=0x...
export RPC_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
export RPC_42161=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY  
export RPC_8453=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY

# Run deployment
forge script deploy/DeployAll.s.sol:DeployAll \
  --sig "run(string)" "mainnet" \
  --broadcast \
  --verify \
  --slow
```

## Deployment Status

Check deployment status across all chains:

```bash
forge script deploy/DeploymentStatus.s.sol:DeploymentStatus \
  --sig "run(string)" "mainnet"
```

## Registry Files

Deployed contract addresses are saved to registry files:

- `deploy/registry/{chainName}-{chainId}.json` - Per-chain deployed addresses
- `deploy/registry/{stage}-state.json` - Deployment state tracking
- `deploy/registry/lz-peer-config.json` - LayerZero peer configurations

Example registry file:

```json
{
  "Orchestrator": "0x...",
  "AccountImpl": "0x...",
  "AccountProxy": "0x...",
  "Simulator": "0x...",
  "SimpleFunder": "0x...",
  "Escrow": "0x...",
  "Settler": "0x..."
}
```

## Dry Run Mode

Test deployment without sending transactions:

1. Set `dryRun: true` in deployment config
2. Run deployment scripts normally
3. Review console output for what would be deployed

## Retry Logic

If deployment fails:

1. Script automatically retries based on `maxRetries` setting
2. State is saved between attempts
3. Re-run the same command to resume from failure point

## Adding New Chains

1. Add chain info to `deploy/config/chains.json`
2. Add chain ID to appropriate `deploy/config/chains/{environment}.json`
3. Provide RPC URL as `RPC_{chainId}` environment variable

## Troubleshooting

### Common Issues

1. **"Environment variable not found"**: Ensure RPC URLs are set as `RPC_{chainId}`
2. **"Chain ID mismatch"**: RPC URL doesn't match expected chain
3. **"Contract not found"**: Run deployment stages in order (Basic → Interop → Settlement → LZ Config)

### Debug Mode

Run with verbose output:

```bash
forge script deploy/DeployBasic.s.sol:DeployBasic \
  --sig "run(string)" "mainnet" \
  -vvvv
```

## Security Considerations

1. **Never commit private keys** - Use environment variables
2. **Verify addresses** - Double-check all addresses in contract config files
3. **Test on testnet first** - Use testnet configuration before mainnet
4. **Review registry files** - Verify deployed addresses match expectations

## Configuration Best Practices

1. **Use separate configs per environment** - Don't mix mainnet/testnet addresses
2. **Document address purposes** - Add comments in config files
3. **Version control configs** - Track all configuration changes
4. **Backup registry files** - Save deployed addresses externally