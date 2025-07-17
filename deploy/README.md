# Deployment System

This directory contains the unified deployment system for the Ithaca Account contracts.

## Overview

The deployment system uses a single configuration file (`deploy-config.json`) that contains all chain-specific settings including contract addresses, deployment parameters, and stage configurations. This eliminates the previous separation between devnets, testnets, and mainnets, providing a simpler and more flexible deployment approach.

## Configuration Structure

All deployment configuration is stored in `deploy/deploy-config.json`:

```json
{
  "chainId": {
    "name": "Chain Name",
    "layerZeroEndpoint": "0x...",
    "layerZeroEid": 30101,
    "isTestnet": false,
    "pauseAuthority": "0x...",
    "funderSigner": "0x...",
    "funderOwner": "0x...",
    "settlerOwner": "0x...",
    "l0SettlerOwner": "0x...",
    "stages": ["basic", "interop", "simpleSettler"],
    "maxRetries": 3,
    "retryDelay": 5
  }
}
```

### Configuration Fields

- **name**: Human-readable chain name
- **layerZeroEndpoint**: LayerZero endpoint address for cross-chain messaging
- **layerZeroEid**: LayerZero endpoint ID for this chain
- **isTestnet**: Boolean indicating if this is a testnet
- **pauseAuthority**: Address that can pause contract operations
- **funderSigner**: Address authorized to sign funding operations
- **funderOwner**: Owner of the SimpleFunder contract
- **settlerOwner**: Owner of the SimpleSettler contract
- **l0SettlerOwner**: Owner of the LayerZeroSettler contract
- **stages**: Array of deployment stages to execute for this chain
- **maxRetries**: Maximum number of deployment retry attempts
- **retryDelay**: Delay in seconds between retry attempts

## Available Stages

The deployment system is modular with the following stages:

- **basic**: Core contracts (Orchestrator, IthacaAccount, Proxy, Simulator)
- **interop**: Interoperability contracts (SimpleFunder, Escrow)
- **simpleSettler**: Single-chain settlement contract
- **layerzeroSettler**: Cross-chain settlement contract
- **layerzeroConfig**: Configure LayerZero peer connections between deployed settlers

### Stage Dependencies

- **interop** requires **basic** to be deployed first
- **layerzeroConfig** requires **layerzeroSettler** to be deployed on at least 2 chains

## Deployment Scripts

### Deploy All Configured Stages

Deploy all stages configured for the specified chains:

```bash
# Deploy to all chains in config
forge script deploy/DeployAll.s.sol:DeployAll \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[]"

# Deploy to specific chains
forge script deploy/DeployAll.s.sol:DeployAll \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[1,42161,8453]"

# With verification
forge script deploy/DeployAll.s.sol:DeployAll \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --sig "run(uint256[])" \
  "[11155111]"
```

### Deploy Individual Stages

Deploy specific stages only:

```bash
# Deploy basic contracts
forge script deploy/DeployBasic.s.sol:DeployBasic \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[11155111]"

# Deploy interop contracts
forge script deploy/DeployInterop.s.sol:DeployInterop \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[11155111]"

# Deploy SimpleSettler
forge script deploy/DeploySimpleSettler.s.sol:DeploySimpleSettler \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[28404]"

# Deploy LayerZeroSettler
forge script deploy/DeployLayerZeroSettler.s.sol:DeployLayerZeroSettler \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[1,42161,8453]"

# Configure LayerZero peers
forge script deploy/ConfigureLayerZero.s.sol:ConfigureLayerZero \
  --rpc-url $RPC_URL \
  --broadcast \
  --sig "run(uint256[])" \
  "[1,42161,8453]"
```

## Environment Variables

### Required Environment Variables

#### RPC URLs
Format: `RPC_{chainId}`

```bash
# Mainnet
RPC_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_42161=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_8453=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY

# Testnet
RPC_11155111=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
RPC_421614=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
RPC_84532=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY

# Local
RPC_28404=http://localhost:8545
```

#### Private Key
```bash
PRIVATE_KEY=0x... # Your deployment private key
```

### Optional Environment Variables

#### Verification API Keys
Format: `VERIFICATION_KEY_{chainId}`

```bash
VERIFICATION_KEY_1=YOUR_ETHERSCAN_API_KEY
VERIFICATION_KEY_42161=YOUR_ARBISCAN_API_KEY
VERIFICATION_KEY_8453=YOUR_BASESCAN_API_KEY
VERIFICATION_KEY_11155111=YOUR_SEPOLIA_ETHERSCAN_API_KEY
VERIFICATION_KEY_421614=YOUR_ARBITRUM_SEPOLIA_API_KEY
VERIFICATION_KEY_84532=YOUR_BASE_SEPOLIA_API_KEY
```

## Adding New Chains

To add a new chain to the deployment system:

1. **Add chain configuration** to `deploy-config.json`:
   ```json
   "137": {
     "name": "Polygon",
     "layerZeroEndpoint": "0x1a44076050125825900e736c501f859c50fE728c",
     "layerZeroEid": 30109,
     "isTestnet": false,
     "pauseAuthority": "0x...",
     "funderSigner": "0x...",
     "funderOwner": "0x...",
     "settlerOwner": "0x...",
     "l0SettlerOwner": "0x...",
     "stages": ["basic", "interop", "layerzeroSettler", "layerzeroConfig"],
     "maxRetries": 3,
     "retryDelay": 5
   }
   ```

2. **Set environment variables**:
   ```bash
   export RPC_137=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
   export VERIFICATION_KEY_137=YOUR_POLYGONSCAN_API_KEY
   ```

3. **Run deployment**:
   ```bash
   forge script deploy/DeployAll.s.sol:DeployAll \
     --rpc-url $RPC_137 \
     --broadcast \
     --verify \
     --sig "run(uint256[])" \
     "[137]"
   ```

## Multi-Settler Support

Chains can deploy both SimpleSettler and LayerZeroSettler by including both stages in the configuration:

```json
"stages": ["basic", "interop", "simpleSettler", "layerzeroSettler", "layerzeroConfig"]
```

This is useful for chains that need:
- SimpleSettler for fast, single-chain settlements
- LayerZeroSettler for cross-chain interoperability

## Deployment State Management

The deployment system maintains state in the `deploy/registry/` directory:

- **Contract addresses**: `{chainName}-{chainId}.json`
  - Contains deployed contract addresses for each chain
  - Automatically updated after each successful deployment

- **Deployment state**: `{stage}-state.json`
  - Tracks deployment progress for each stage
  - Allows resuming deployments if interrupted

Example registry file (`Ethereum Mainnet-1.json`):
```json
{
  "Orchestrator": "0x...",
  "AccountImpl": "0x...",
  "AccountProxy": "0x...",
  "Simulator": "0x...",
  "SimpleFunder": "0x...",
  "Escrow": "0x...",
  "SimpleSettler": "0x...",
  "LayerZeroSettler": "0x..."
}
```

## Dry Run Mode

To test deployments without broadcasting transactions, simply omit the `--broadcast` flag when running forge scripts:

```bash
# Dry run (simulation only)
forge script deploy/DeployAll.s.sol:DeployAll --sig "run(uint256[])" "[1,42161]"

# Actual deployment
forge script deploy/DeployAll.s.sol:DeployAll --sig "run(uint256[])" "[1,42161]" --broadcast
```

Dry run mode (without `--broadcast`) will:
- Simulate all deployment transactions
- Show gas estimates
- Verify the deployment logic
- Not send any actual transactions

## LayerZero Configuration

For cross-chain functionality, the LayerZero configuration stage:

1. Collects all deployed LayerZeroSettler contracts
2. Sets up peer relationships between chains
3. Configures trusted remote addresses

Requirements:
- LayerZeroSettler must be deployed on at least 2 chains
- Valid LayerZero endpoints must be configured
- `layerzeroConfig` stage must be included for participating chains

## Troubleshooting

### Common Issues

1. **"Chain ID mismatch"**
   - Ensure RPC URL matches the chain ID in config
   - Verify the RPC endpoint is correct

2. **"Orchestrator not found - run DeployBasic first"**
   - Deploy stages in order: basic → interop → settlers
   - Check registry files for missing contracts

3. **"Less than 2 LayerZero settlers found"**
   - Deploy LayerZeroSettler on multiple chains before configuring
   - Ensure `layerzeroSettler` stage is included in chain configs

4. **Verification failures**
   - Check VERIFICATION_KEY environment variables
   - Ensure the chain is supported by the block explorer
   - Verify API key has correct permissions

### Recovery from Failed Deployments

The system automatically tracks deployment state and can resume from failures:

1. Fix the underlying issue (gas, RPC, configuration)
2. Re-run the same deployment command
3. The system will skip already-deployed contracts and continue

To force a fresh deployment, delete the relevant files in `deploy/registry/`.

## Best Practices

1. **Test on testnets first** - Use Sepolia, Arbitrum Sepolia, etc.
2. **Use dry run mode** - Test configuration before mainnet deployment
3. **Verify addresses** - Double-check all configured addresses
4. **Monitor gas prices** - Ensure sufficient ETH for deployment
5. **Keep registry files** - Back up the `deploy/registry/` directory
6. **Use appropriate stages** - Only include necessary stages per chain

## Security Considerations

1. **Private Key Management**
   - Never commit private keys to version control
   - Use hardware wallets for mainnet deployments
   - Consider using a dedicated deployment address

2. **Address Verification**
   - Verify all owner and authority addresses before deployment
   - Use multi-signature wallets for critical roles
   - Document address ownership

3. **Post-Deployment**
   - Verify all contracts on block explorers
   - Test contract functionality after deployment
   - Transfer ownership to final addresses if needed