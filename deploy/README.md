# Deployment System

This directory contains the unified deployment system for the Ithaca Account contracts.

## Overview

The deployment system uses a single configuration file (`deploy-config.json`) that contains all chain-specific settings including contract addresses, deployment parameters, and stage configurations. This eliminates the previous separation between devnets, testnets, and mainnets, providing a simpler and more flexible deployment approach.

## Configuration Structure

All deployment configuration is stored in `deploy/deploy-config.json`:

```json
{
  "chainId": {
    "funderOwner": "0x...",
    "funderSigner": "0x...",
    "isTestnet": false,
    "l0SettlerOwner": "0x...",
    "layerZeroEndpoint": "0x...",
    "layerZeroEid": 30101,
    "maxRetries": 3,
    "name": "Chain Name",
    "pauseAuthority": "0x...",
    "retryDelay": 5,
    "salt": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "settlerOwner": "0x...",
    "stages": ["basic", "interop", "simpleSettler"]
  }
}
```

⚠️ **IMPORTANT**: Configuration fields MUST be in alphabetical order! Foundry's JSON parsing requires struct fields to match the alphabetical order of keys in the JSON file. Failure to maintain alphabetical ordering will cause deployment failures.

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
- **salt**: (Optional) Salt for deterministic CREATE2 deployment. If omitted or set to `0x0000...0000`, contracts will be deployed using regular CREATE
- **stages**: Array of deployment stages to execute for this chain
- **maxRetries**: Maximum number of deployment retry attempts
- **retryDelay**: Delay in seconds between retry attempts

## Available Stages

The deployment system is modular with the following stages:

- **basic**: Core contracts (Orchestrator, IthacaAccount, Proxy, Simulator)
- **interop**: Interoperability contracts (SimpleFunder, Escrow)
- **simpleSettler**: Single-chain settlement contract
- **layerzeroSettler**: Cross-chain settlement contract

### Stage Dependencies

- **interop** requires **basic** to be deployed first

## Deployment Scripts

### Main Deployment Script

The primary way to deploy is using the main deployment script, which executes all configured stages for the specified chains:

```bash
# Deploy to all chains in config
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  "[]"

# Deploy to specific chains
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  "[1,42161,8453]"

# Single chain deployment (no --multi needed)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  "[11155111]"

# With verification (multi-chain)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --verify \
  --sig "run(uint256[])" \
  "[1,42161,8453]"
```

**Important flags for multi-chain deployments:**
- `--multi`: Enables multi-chain deployment sequences
- `--slow`: Ensures transactions are sent only after previous ones are confirmed

The script automatically deploys stages in the correct order:
1. `basic` - Core contracts (Orchestrator, IthacaAccount, Proxy, Simulator)
2. `interop` - Interoperability contracts (SimpleFunder, Escrow)
3. `simpleSettler` and/or `layerzeroSettler` - Settlement contracts

The DeployMain script handles all deployment stages automatically based on the configuration in `deploy-config.json`. Each chain will only deploy the stages specified in its configuration.

### Complete Deployment Example

To deploy all configured stages for a chain:

```bash
# Set environment variables
export RPC_11155111=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
export PRIVATE_KEY=0x...

# Deploy all stages configured in deploy-config.json
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  "[11155111]"
```

The script will:
- Check which stages are configured for the chain
- Deploy contracts in the correct order
- Skip already deployed contracts
- Save deployment addresses to the registry

**Note about multi-chain deployments**: When deploying to multiple chains, always use the `--multi` and `--slow` flags:
```bash
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  "[1,42161,8453]"
```

These flags ensure:
- `--multi`: Proper handling of multi-chain deployment sequences
- `--slow`: Transactions are sent only after previous ones are confirmed

**Note**: LayerZero peer configuration across multiple chains will be added in a future update.

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

1. **Add chain configuration** to `deploy-config.json` (fields must be in alphabetical order):
   ```json
   "137": {
     "funderOwner": "0x...",
     "funderSigner": "0x...",
     "isTestnet": false,
     "l0SettlerOwner": "0x...",
     "layerZeroEndpoint": "0x1a44076050125825900e736c501f859c50fE728c",
     "layerZeroEid": 30109,
     "maxRetries": 3,
     "name": "Polygon",
     "pauseAuthority": "0x...",
     "retryDelay": 5,
     "salt": "0x0000000000000000000000000000000000000000000000000000000000000000",
     "settlerOwner": "0x...",
     "stages": ["basic", "interop", "layerzeroSettler"]
   }
   ```

2. **Set environment variables**:
   ```bash
   export RPC_137=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
   export VERIFICATION_KEY_137=YOUR_POLYGONSCAN_API_KEY
   ```

3. **Run deployment**:
   ```bash
   # For single chain
   forge script deploy/DeployMain.s.sol:DeployMain \
     --broadcast \
     --verify \
     --sig "run(uint256[])" \
     "[137]"
   
   # For multiple chains including this one
   forge script deploy/DeployMain.s.sol:DeployMain \
     --broadcast \
     --multi \
     --slow \
     --verify \
     --sig "run(uint256[])" \
     "[137,42161,8453]"
   ```

## Multi-Settler Support

Chains can deploy both SimpleSettler and LayerZeroSettler by including both stages in the configuration:

```json
"stages": ["basic", "interop", "simpleSettler", "layerzeroSettler"]
```

This is useful for chains that need:
- SimpleSettler for fast, single-chain settlements
- LayerZeroSettler for cross-chain interoperability

## Deployment State Management

The deployment system maintains state in the `deploy/registry/` directory:

- **Contract addresses**: `deployment_{chainId}.json`
  - Contains deployed contract addresses for each chain
  - Automatically updated after each successful deployment

- **Deployment state**: `{stage}-state.json`
  - Tracks deployment progress for each stage
  - Allows resuming deployments if interrupted

Example registry file (`deployment_1.json`):
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
forge script deploy/DeployMain.s.sol:DeployMain --sig "run(uint256[])" "[1,42161]"

# Actual deployment (multi-chain)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  "[1,42161]"
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
- LayerZero peer configuration will be added in a future update

## Troubleshooting

### Common Issues

1. **"Chain ID mismatch"**
   - Ensure RPC URL matches the chain ID in config
   - Verify the RPC endpoint is correct

2. **"Orchestrator not found"**
   - Ensure `basic` stage is included in the chain's stages configuration
   - The DeployMain script automatically handles stage ordering

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

## CREATE2 Deterministic Deployments

The deployment system supports deterministic address deployment using CREATE2 via the Safe Singleton Factory.

### Using CREATE2

To deploy contracts with deterministic addresses, add a `salt` field to your chain configuration:

```json
"1": {
  "name": "Ethereum Mainnet",
  "salt": "0x0000000000000000000000000000000000000000000000000000000000000001",
  // ... other fields
}
```

### Benefits of CREATE2

- **Deterministic addresses**: Contract addresses can be computed before deployment
- **Cross-chain consistency**: Same addresses across multiple chains (with same salt)
- **Pre-funding**: Addresses can receive funds before deployment
- **Easier integration**: Partners can integrate with known addresses

### CREATE2 Requirements

1. **Safe Singleton Factory** must be deployed at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`
2. The factory is deployed on most major chains
3. If not deployed, the deployment will revert with `SafeSingletonFactoryNotDeployed()`

### Salt Configuration Examples

```json
// Use regular CREATE (default)
"salt": "0x0000000000000000000000000000000000000000000000000000000000000000"

// Use CREATE2 with custom salt
"salt": "0x0000000000000000000000000000000000000000000000000000000000000001"

// Use CREATE2 with meaningful salt
"salt": "0x697468616361000000000000000000000000000000000000000000000000001" // "ithaca" + version
```

### Computing Addresses

When using CREATE2, addresses can be pre-computed. The deployment script will log both the deployed address and the predicted address for verification.

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

4. **CREATE2 Considerations**
   - Salt values should be carefully chosen and documented
   - Same salt + same code = same address across chains
   - Changing constructor parameters changes the address
   - Lost salts cannot be recovered