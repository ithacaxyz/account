# Deployment System

This directory contains the unified deployment system for the Ithaca Account contracts.

## Overview

The deployment system uses a TOML configuration file (`config.toml`) that contains all chain-specific settings and contract deployment specifications. It leverages Foundry's fork configuration features for a clean, maintainable deployment approach with CREATE2 for deterministic addresses across chains.

## Quick Start

1. **Set up environment variables**:
   ```bash
   # Copy .env.example to .env and fill in your values
   cp .env.example .env
   
   # Required: Set your private key
   export PRIVATE_KEY=0x...
   
   # Required: Set RPC URLs for each chain
   export RPC_84532=https://sepolia.base.org
   export RPC_11155420=https://sepolia.optimism.io
   export RPC_11155111=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
   ```

2. **Source the environment**:
   ```bash
   source .env
   ```

3. **Deploy contracts**:
   ```bash
   # Deploy to all configured chains
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
     "[84532,11155420]"
   
   # Deploy to single chain
   forge script deploy/DeployMain.s.sol:DeployMain \
     --broadcast \
     --sig "run(uint256[])" \
     --private-key $PRIVATE_KEY \
     "[84532]"
   ```

## Configuration Structure

All deployment configuration is in `deploy/config.toml`:

```toml
[deployment]
registry_path = "deploy/registry/"

[forks.chain-name]
rpc_url = "${RPC_CHAINID}"  # Environment variable reference

[forks.chain-name.vars]
chain_id = CHAINID
name = "Chain Name"
is_testnet = true/false
pause_authority = "0x..."
funder_owner = "0x..."
funder_signer = "0x..."
settler_owner = "0x..."
l0_settler_owner = "0x..."
layerzero_endpoint = "0x..."
layerzero_eid = EID
salt = "0x..."  # Salt for CREATE2 deployments
contracts = ["Orchestrator", "IthacaAccount", ...]  # Or ["ALL"] for all contracts
```

### Configuration Fields

- **chain_id**: The network chain ID
- **name**: Human-readable chain name
- **is_testnet**: Boolean indicating if this is a testnet
- **pause_authority**: Address that can pause contract operations
- **funder_owner**: Owner of the SimpleFunder contract
- **funder_signer**: Address authorized to sign funding operations
- **settler_owner**: Owner of the SimpleSettler contract
- **l0_settler_owner**: Owner of the LayerZeroSettler contract
- **layerzero_endpoint**: LayerZero endpoint address for cross-chain messaging
- **layerzero_eid**: LayerZero endpoint ID for this chain
- **salt**: Salt value for CREATE2 deployments (determines contract addresses)
- **contracts**: Array of contract names to deploy

## Contract Deployment

### Specifying Contracts to Deploy

The `contracts` array in the configuration determines which contracts to deploy:

```toml
# Deploy all available contracts
contracts = ["ALL"]

# Deploy specific contracts
contracts = ["Orchestrator", "IthacaAccount", "AccountProxy"]

# Deploy the full set explicitly
contracts = ["Orchestrator", "IthacaAccount", "AccountProxy", "Simulator", "SimpleFunder", "Escrow", "SimpleSettler", "LayerZeroSettler"]
```

### Available Contracts

- **Orchestrator**: Core orchestration contract
- **IthacaAccount**: Account implementation contract
- **AccountProxy**: EIP-7702 proxy for accounts
- **Simulator**: Simulation contract for testing
- **SimpleFunder**: Basic funding mechanism
- **Escrow**: Escrow contract for secure transfers
- **SimpleSettler**: Single-chain settlement contract
- **LayerZeroSettler**: Cross-chain settlement via LayerZero

### Contract Dependencies

The deployment script automatically handles dependencies:
- **IthacaAccount** requires **Orchestrator** to be deployed first
- **AccountProxy** requires **IthacaAccount** to be deployed first
- **SimpleFunder** requires **Orchestrator** to be deployed first

## Deployment Commands

### Deploy to All Chains

```bash
# Using empty array
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[]"

# Using run() without parameters
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run()" \
  --private-key $PRIVATE_KEY
```

### Deploy to Specific Chains

```bash
# Multiple chains
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --multi \
  --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532,11155420]"

# Single chain (no --multi needed)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532]"
```

### Important Flags

- `--multi`: Required for multi-chain deployments
- `--slow`: Ensures transactions are sent only after previous ones are confirmed
- `--broadcast`: Actually sends transactions (omit for dry run)
- `--verify`: Verify contracts on block explorers (requires API keys)

## CREATE2 Deployment

All contracts are deployed using CREATE2 via the Safe Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`), providing deterministic addresses across chains.

### How It Works

Contract addresses are determined by:
- The factory address (constant across all chains)
- The salt value (configured per chain)
- The contract bytecode

This means:
- **Same salt + same bytecode = same address** on every chain
- Contract addresses can be predicted before deployment
- You can deploy to the same addresses on new chains later

### Salt Configuration

The `salt` field in each chain configuration determines deployment addresses:

```toml
# Default salt (all zeros)
salt = "0x0000000000000000000000000000000000000000000000000000000000000000"

# Custom salt for different addresses
salt = "0x0000000000000000000000000000000000000000000000000000000000000001"
```

⚠️ **IMPORTANT**: 
- **Save your salt values!** Lost salts mean you cannot deploy to the same addresses on new chains
- **Use the same salt** across chains for identical addresses
- **Use different salts** if you need different addresses per chain

## Registry Files

The deployment system maintains contract addresses in `deploy/registry/`:

- **Format**: `deployment_{chainId}_{salt}.json`
- **Example**: `deployment_84532_0x0000000000000000000000000000000000000000000000000000000000000001.json`

Example registry file:
```json
{
  "Orchestrator": "0xb33adF2c2257a94314d408255aC843fd53B1a7e1",
  "IthacaAccount": "0x5a87ef243CDA70a855828d4989Fad61B56A467d3",
  "AccountProxy": "0x4ACD713815fbb363a89D9Ff046C56cEdC7EF3ad7",
  "Simulator": "0x65Ae218EB1987b8bd0F9eeb38D1B344726D41dA5",
  "SimpleFunder": "0xA47C5C472449979a2F37dF2971627cD6587bADb8",
  "Escrow": "0x24F50280cE3B51Ab1967F048746FB7ba3C7B4067",
  "SimpleSettler": "0xb934afBB50b8aBBe24959f9398fE024BEe9Bf716",
  "LayerZeroSettler": "0xB89f4A85d38C3A2407854269527fabD3b61fd56a"
}
```

### Important Notes

- Registry files are created automatically after successful deployments
- CREATE2 deployments automatically skip if contract already exists at predicted address
- Registry files do NOT control deployment decisions - on-chain state does
- Commit registry files to version control for reference

## Adding New Chains

To add a new chain:

1. **Add configuration to `deploy/config.toml`**:
   ```toml
   [forks.polygon]
   rpc_url = "${RPC_137}"
   
   [forks.polygon.vars]
   chain_id = 137
   name = "Polygon"
   is_testnet = false
   pause_authority = "0x..."
   funder_owner = "0x..."
   funder_signer = "0x..."
   settler_owner = "0x..."
   l0_settler_owner = "0x..."
   layerzero_endpoint = "0x1a44076050125825900e736c501f859c50fE728c"
   layerzero_eid = 30109
   salt = "0x0000000000000000000000000000000000000000000000000000000000000001"
   contracts = ["ALL"]  # Or specify individual contracts
   ```

2. **Set environment variable**:
   ```bash
   export RPC_137=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
   ```

3. **Deploy**:
   ```bash
   forge script deploy/DeployMain.s.sol:DeployMain \
     --broadcast \
     --sig "run(uint256[])" \
     --private-key $PRIVATE_KEY \
     "[137]"
   ```

## Environment Variables

### Required

```bash
# Deployment private key
PRIVATE_KEY=0x...

# RPC URLs (format: RPC_{chainId})
RPC_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
RPC_84532=https://sepolia.base.org
RPC_11155420=https://sepolia.optimism.io
```

### Optional

```bash
# Verification API keys (format: VERIFICATION_KEY_{chainId})
VERIFICATION_KEY_1=YOUR_ETHERSCAN_API_KEY
VERIFICATION_KEY_84532=YOUR_BASESCAN_API_KEY
VERIFICATION_KEY_11155420=YOUR_OPTIMISM_API_KEY
```

## Dry Run Mode

Test deployments without broadcasting transactions:

```bash
# Dry run (no --broadcast flag)
forge script deploy/DeployMain.s.sol:DeployMain \
  --sig "run(uint256[])" \
  "[84532]"
```

This will:
- Simulate all deployment transactions
- Show gas estimates
- Verify deployment logic
- Not send actual transactions

## Troubleshooting

### Common Issues

1. **"No chains found in configuration"**
   - Ensure config.toml has properly configured chains
   - Check that RPC URLs are set for all target chains

2. **"Safe Singleton Factory not deployed"**
   - The factory must exist at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`
   - Most major chains have this deployed

3. **Contract already deployed**
   - This is normal for CREATE2 - contracts at predicted addresses are skipped
   - To deploy to new addresses, change the salt value

4. **RPC errors**
   - Verify RPC URLs are correct and accessible
   - Check rate limits on public RPCs
   - Consider using paid RPC services for production

## Best Practices

1. **Always run a dry run first** - Test configuration before mainnet deployment
2. **Save your salt values** - Required for deploying to same addresses on new chains
3. **Use `["ALL"]` for complete deployments** - Ensures all contracts are deployed
4. **Commit registry files** - Provides deployment history and reference
5. **Use `--multi --slow` for multi-chain** - Ensures proper transaction ordering
6. **Verify contracts after deployment** - Use block explorer verification

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