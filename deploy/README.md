# Deployment System

This directory contains the unified deployment system for the Ithaca Account contracts.

## Overview

The deployment system uses a single configuration file (`DefaultConfig.sol`) that contains all chain-specific settings including contract addresses, deployment parameters, and stage configurations. This eliminates the previous separation between devnets, testnets, and mainnets, providing a simpler and more flexible deployment approach.
## Quickstart

Follow these steps for your first deployment using the provided scripts.

1. **Review the default configuration in `deploy/DefaultConfig.sol`.**  
   The configuration for all chains is defined in Solidity. For example, chain **28404** (Porto Devnet) is configured as:

```solidity
configs[6] = BaseDeployment.ChainConfig({
    chainId: 28404,
    name: "Porto Devnet",
    isTestnet: true,
    pauseAuthority: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
    funderOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
    funderSigner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
    settlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
    l0SettlerOwner: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
    layerZeroEndpoint: 0x0000000000000000000000000000000000000000,
    layerZeroEid: 0,
    stages: _getDevnetStages() // Returns [Core, Interop, SimpleSettler]
});
```

2. **Dry-run the deployment script (no broadcast).**  
   This prints the loaded configuration in the console.
   IMPORTANT: Verify that the configuration values are correct before proceeding.

```bash
# Export your private key
export PRIVATE_KEY=0x...
export RPC_28404=https://porto-dev.rpc.ithaca.xyz/
forge script deploy/DeployMain.s.sol:DeployMain \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[28404]"
```

> **Note**: Intentionally omit the `--broadcast` flag for this first run to verify configuration.

3. **Broadcast the deployment.**  
   Once satisfied, repeat the command **with** `--broadcast` to actually deploy:

```bash
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[28404]"
```

After a successful deployment:

- Commit the generated `deploy/registry/deployment_28404.json` file so others (and CI) can reference the deployed addresses.

## Configuration Structure

All deployment configuration is defined in `deploy/DefaultConfig.sol` using Solidity structs:

```solidity
struct ChainConfig {
    uint256 chainId;
    string name;
    bool isTestnet;
    address pauseAuthority;
    address funderOwner;
    address funderSigner;
    address settlerOwner;
    address l0SettlerOwner;
    address layerZeroEndpoint;
    uint32 layerZeroEid;
    Stage[] stages;
}
```

The configuration is type-safe and validated at compile time, eliminating JSON parsing errors.

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

## Available Stages

The deployment system is modular with the following stages:

- **core**: Core contracts (Orchestrator, IthacaAccount, Proxy, Simulator)
- **interop**: Interoperability contracts (SimpleFunder, Escrow)
- **simpleSettler**: Single-chain settlement contract
- **layerzeroSettler**: Cross-chain settlement contract

### Stage Dependencies

- **interop** requires **core** to be deployed first

## Deployment Scripts

### Main Deployment Script

The primary way to deploy is using the main deployment script, which executes all configured stages for the specified chains:

```bash
# Export your private key
export PRIVATE_KEY=0x...

# Deploy to all chains in config
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[]"

# Deploy to specific chains
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[1,42161,8453]"

# Single chain deployment (no --multi needed)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[11155111]"

# With verification (multi-chain)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --verify \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[1,42161,8453]"
```

**Important flags for multi-chain deployments:**
- `--multi`: Enables multi-chain deployment sequences
- `--slow`: Ensures transactions are sent only after previous ones are confirmed

The script automatically deploys stages in the correct order:
1. `core` - Core contracts (Orchestrator, IthacaAccount, Proxy, Simulator)
2. `interop` - Interoperability contracts (SimpleFunder, Escrow)
3. `simpleSettler` and/or `layerzeroSettler` - Settlement contracts

The DeployMain script handles all deployment stages automatically based on the configuration in `DefaultConfig.sol`. Each chain will only deploy the stages specified in its configuration.

### Complete Deployment Example

To deploy all configured stages for a chain:

```bash
# Set environment variables
export RPC_11155111=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
export PRIVATE_KEY=0x...

# Deploy all stages configured in DefaultConfig.sol
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[11155111]"
```

The script will:
- Check which stages are configured for the chain
- Deploy contracts in the correct order
- Skip already deployed contracts
- Save deployment addresses to the registry

**Note about multi-chain deployments**: When deploying to multiple chains, always use the `--multi` and `--slow` flags:
```bash
export PRIVATE_KEY=0x...
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
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

1. **Modify `deploy/DefaultConfig.sol`** to add the new chain configuration:
   ```solidity
   // In getConfigs() function, increase the array size
   configs = new BaseDeployment.ChainConfig[](8); // was 7
   
   // Add new chain configuration
   configs[7] = BaseDeployment.ChainConfig({
       chainId: 137,
       name: "Polygon",
       isTestnet: false,
       pauseAuthority: 0x...,
       funderOwner: 0x...,
       funderSigner: 0x...,
       settlerOwner: 0x...,
       l0SettlerOwner: 0x...,
       layerZeroEndpoint: 0x1a44076050125825900e736c501f859c50fE728c,
       layerZeroEid: 30109,
       stages: _getAllStages() // or custom stages array
   });
   ```

2. **Set environment variables**:
   ```bash
   export RPC_137=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
   export VERIFICATION_KEY_137=YOUR_POLYGONSCAN_API_KEY
   ```

3. **Run deployment**:
   ```bash
   export PRIVATE_KEY=0x...
   
   # For single chain
   forge script deploy/DeployMain.s.sol:DeployMain \
     --broadcast \
     --verify \
     --sig "run(uint256[])" \
     --private-key $PRIVATE_KEY \
     "[137]"
   
   # For multiple chains including this one
   forge script deploy/DeployMain.s.sol:DeployMain \
     --broadcast \
     --multi \
     --slow \
     --verify \
     --sig "run(uint256[])" \
     --private-key $PRIVATE_KEY \
     "[137,42161,8453]"
   ```

## Multi-Settler Support

Chains can deploy both SimpleSettler and LayerZeroSettler by including both stages in the configuration:

```json
"stages": ["core", "interop", "simpleSettler", "layerzeroSettler"]
```

This is useful for chains that need:
- SimpleSettler for fast, single-chain settlements
- LayerZeroSettler for cross-chain interoperability

## Deployment Registry

The deployment system maintains deployed contract addresses in the `deploy/registry/` directory:

- **Contract addresses**: `deployment_{chainId}.json`
  - Contains deployed contract addresses for each chain
  - Automatically updated after each successful deployment
  - **Deployments are skipped if file exists** (footgun prevention)

### Important: Fresh Deployments

**To perform a fresh deployment, you must manually delete the `deployment_{chainId}.json` file from the `deploy/registry/` directory.**

This safety mechanism prevents accidental redeployments to chains that already have contracts deployed. The deployment script will skip any chain that has an existing registry file.

```bash
# To redeploy to chain 11155111 (Sepolia)
rm deploy/registry/deployment_11155111.json

# Then run the deployment
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[11155111]"
```

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
export PRIVATE_KEY=0x...
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[1,42161]"
```

Dry run mode (without `--broadcast`) will:
- Simulate all deployment transactions
- Show gas estimates
- Verify the deployment logic
- Not send any actual transactions

## Custom Configuration

To use a custom configuration:

1. **Copy `DefaultConfig.sol`** to a new file (e.g., `MyConfig.sol`)
2. **Modify the configuration** as needed
3. **Update the import** in `BaseDeployment.sol` to use your config:
   ```solidity
   import {MyConfig as DefaultConfig} from "./MyConfig.sol";
   ```
4. **Deploy** using the standard commands

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
   - Ensure `core` stage is included in the chain's stages configuration
   - The DeployMain script automatically handles stage ordering

3. **"Less than 2 LayerZero settlers found"**
   - Deploy LayerZeroSettler on multiple chains before configuring
   - Ensure `layerzeroSettler` stage is included in chain configs

4. **Verification failures**
   - Check VERIFICATION_KEY environment variables
   - Ensure the chain is supported by the block explorer
   - Verify API key has correct permissions

### Redeployments

- **Deployments are automatically skipped** if the registry file exists (footgun prevention)
- **To force redeployment**: You must manually delete the relevant `deployment_{chainId}.json` file from `deploy/registry/`
- **Warning**: Only delete registry files if you intend to perform a fresh deployment. This safety mechanism prevents accidental double deployments.

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

