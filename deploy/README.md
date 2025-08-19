# Deployment System

Unified deployment and configuration system for the Ithaca Account Abstraction System. 
We use a single TOML config for fast and easy scripting.

## Available Scripts

1. **`DeployMain.s.sol`** - Deploy contracts to multiple chains
2. **`ConfigureLayerZeroSettler.s.sol`** - Configure LayerZero for interop
3. **`FundSigners.s.sol`** - Fund signers and set them as gas wallets
4. **`FundSimpleFunder.s.sol`** - Fund the SimpleFunder contract with ETH or tokens

All scripts read from `deploy/config.toml` for unified configuration management.

For chains without interop, you can skip the `ConfigureLayerZeroSettler` script.

## Prerequisites

### Environment Setup

Create a `.env` file with your configuration:

```bash
# Primary deployment key
export PRIVATE_KEY=0x...

# Script-specific keys
export L0_SETTLER_OWNER_PK=0x...  # For ConfigureLayerZeroSettler
export GAS_SIGNER_MNEMONIC="twelve word mnemonic phrase"  # For FundSigners

# RPC URLs (format: RPC_{chainId})
export RPC_1=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
export RPC_84532=https://sepolia.base.org
export RPC_11155420=https://sepolia.optimism.io
export RPC_11155111=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Verification API keys (optional)
# You only need one ETHERSCAN key, if etherscan supports verification for your chains.
export ETHERSCAN_API_KEY=YOUR_KEY
```

### Contract Verification

Configure `foundry.toml` for automatic verification:

```toml
[etherscan]
mainnet = { key = "${ETHERSCAN_API_KEY}" }
sepolia = { key = "${ETHERSCAN_API_KEY}" }
base = { key = "${ETHERSCAN_API_KEY}" }
base-sepolia = { key = "${ETHERSCAN_API_KEY}" }
optimism = { key = "${ETHERSCAN_API_KEY}" }
optimism-sepolia = { key = "${ETHERSCAN_API_KEY}" }
```

## Configuration Structure

All configuration is in `deploy/config.toml`:

```toml
[profile.deployment]
registry_path = "deploy/registry/"

[forks.base-sepolia]
rpc_url = "${RPC_84532}"

[forks.base-sepolia.vars]
# Chain identification
chain_id = 84532
name = "Base Sepolia"
is_testnet = true

# Contract ownership
pause_authority = "0x..."         # Can pause contracts
funder_owner = "0x..."            # Owns SimpleFunder
funder_signer = "0x..."           # Signs funding operations
settler_owner = "0x..."           # Owns SimpleSettler
l0_settler_owner = "0x..."        # Owns LayerZeroSettler

# Deployment configuration
salt = "0x0000..."                # CREATE2 salt (SAVE THIS!)
contracts = ["ALL"]               # Or specific: ["Orchestrator", "IthacaAccount"]

# Funding configuration (only needed for Funding Script)
target_balance = 1000000000000000 # Target balance per signer (0.001 ETH)
simple_funder_address = "0x..."   # SimpleFunder address
default_num_signers = 10          # Number of signers to fund

# LayerZero configuration (only needed for ConfigureLayerZero)
layerzero_settler_address = "0x..."
layerzero_endpoint = "0x..."
layerzero_eid = 40245
layerzero_send_uln302 = "0x..."
layerzero_receive_uln302 = "0x..."
layerzero_destination_chain_ids = [11155420]
layerzero_required_dvns = ["dvn_layerzero_labs"]
layerzero_optional_dvns = []
layerzero_optional_dvn_threshold = 0
layerzero_confirmations = 1
layerzero_max_message_size = 10000

dvn_layerzero_labs = "0x..."
dvn_google_cloud = "0x..."
```

### Available Contracts

- **Orchestrator**
- **IthacaAccount** 
- **AccountProxy** 
- **Simulator** 
- **SimpleFunder** 
- **Escrow** (Only needed for Interop Chains)
- **SimpleSettler** (Only needed for Interop testing)
- **LayerZeroSettler** (Only needed for Interop Chains)
- **ALL** - Deploys all contracts

**Dependencies**: 
IthacaAccount requires Orchestrator; 
AccountProxy requires IthacaAccount; 
SimpleFunder requires Orchestrator.

## Quick Start - Complete Workflow

Standard deployment process in order:

```bash
# 1. Setup environment
source .env

# 2. Deploy contracts
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast --multi --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532,11155420]"

# 3. Configure LayerZero (if deployed)
forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
  --broadcast --multi --slow \
  --sig "run(uint256[])" \
  --private-key $L0_SETTLER_OWNER_PK \
  "[84532,11155420]"

# 4. Fund and setup gas signers
forge script deploy/FundSigners.s.sol:FundSigners \
  --broadcast --multi --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532,11155420]"

# 5. Fund SimpleFunder contract 
SIMPLE_FUNDER=$(cat deploy/registry/deployment_84532_*.json | jq -r .SimpleFunder)

forge script deploy/FundSimpleFunder.s.sol:FundSimpleFunder \
  --broadcast --multi --slow \
  --sig "run(address,(uint256,address,uint256)[])" \
  --private-key $PRIVATE_KEY \
  $SIMPLE_FUNDER \
  "[(84532,0x0000000000000000000000000000000000000000,1000000000000000000),\
    (11155420,0x0000000000000000000000000000000000000000,1000000000000000000)]"
```

## Script Details

### 1. DeployMain - Contract Deployment

**Purpose**: Deploy contracts using CREATE2 for deterministic addresses.

**When to use**: Initial deployment, adding chains, or redeploying with different configuration.

```bash
# Deploy to all configured chains
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast  --verify --multi --slow \
  --sig "run()" \
  --private-key $PRIVATE_KEY 

# Deploy to specific chains
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast  --verify --multi --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532,11155420]"

# Single chain (no --multi needed)
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532]"

# Dry run (no --broadcast)
forge script deploy/DeployMain.s.sol:DeployMain \
  --sig "run(uint256[])" \
  "[84532]"

# With verification
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast --verify \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532]"
```

### 2. ConfigureLayerZeroSettler - Cross-Chain Setup

**Purpose**: Configure LayerZero messaging pathways between chains.

**Prerequisites**: 
- LayerZeroSettler deployed on source and destination chains
- Caller must be l0_settler_owner

```bash
# Configure all chains
forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
  --broadcast --multi --slow \
  --sig "run()" \
  --private-key $L0_SETTLER_OWNER_PK

# Configure specific chains
forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
  --broadcast --multi --slow \
  --sig "run(uint256[])" \
  --private-key $L0_SETTLER_OWNER_PK \
  "[84532,11155420]"
```

### 3. FundSigners - Gas Wallet Setup

**Purpose**: Fund signers and register them as gas wallets in SimpleFunder.

**Prerequisites**: 
- SimpleFunder deployed
- Caller must be funder_owner
- GAS_SIGNER_MNEMONIC environment variable set

**What it does**:
1. Derives signer addresses from mnemonic
2. Tops up signers below target_balance
3. Registers signers as gas wallets in SimpleFunder

```bash
# Fund default number of signers (from config)
forge script deploy/FundSigners.s.sol:FundSigners \
  --broadcast --multi --slow \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[84532,11155420]"

# Fund custom number of signers
forge script deploy/FundSigners.s.sol:FundSigners \
  --broadcast --multi --slow \
  --sig "run(uint256[],uint256)" \
  --private-key $PRIVATE_KEY \
  "[84532]" 5
```

### 4. FundSimpleFunder - Contract Funding

**Purpose**: Fund SimpleFunder with ETH or ERC20 tokens for gas sponsorship.

**Prerequisites**: SimpleFunder deployed, caller has sufficient funds.

```bash
# Fund with native ETH
forge script deploy/FundSimpleFunder.s.sol:FundSimpleFunder \
  --broadcast --multi --slow \
  --sig "run(address,(uint256,address,uint256)[])" \
  --private-key $PRIVATE_KEY \
  0xSimpleFunderAddress \
  "[(84532,0x0000000000000000000000000000000000000000,1000000000000000000)]"

# Fund with ERC20 tokens
forge script deploy/FundSimpleFunder.s.sol:FundSimpleFunder \
  --broadcast --multi --slow \
  --sig "run(address,(uint256,address,uint256)[])" \
  --private-key $PRIVATE_KEY \
  0xSimpleFunderAddress \
  "[(84532,0xUSDCAddress,1000000)]"
```

**Parameters**:
- SimpleFunder address (same across chains if using CREATE2)
- Array of (chainId, tokenAddress, amount)
  - Use `0x0000000000000000000000000000000000000000` for native ETH

## Important Flags

- `--multi`: Required for multi-chain deployments
- `--slow`: Ensures proper transaction ordering
- `--broadcast`: Send actual transactions (omit for dry run)
- `--verify`: Verify contracts on block explorers

## CREATE2 Deployment

All contracts deploy via Safe Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`) for deterministic addresses.

**Key Points**:
- Same salt + same bytecode = same address on every chain
- Addresses can be predicted before deployment
- **⚠️ SAVE YOUR SALT VALUES** - Required for deploying to same addresses on new chains

## Registry Files

Deployment addresses are saved in `deploy/registry/deployment_{chainId}_{salt}.json`:

```json
{
  "Orchestrator": "0xb33adF2c2257a94314d408255aC843fd53B1a7e1",
  "IthacaAccount": "0x5a87ef243CDA70a855828d4989Fad61B56A467d3",
  "AccountProxy": "0x4ACD713815fbb363a89D9Ff046C56cEdC7EF3ad7",
  "SimpleFunder": "0xA47C5C472449979a2F37dF2971627cD6587bADb8"
}
```

Registry files are for reference only - deployment decisions are based on on-chain state.

## Adding New Chains

1. Add configuration to `deploy/config.toml`:

```toml
[forks.new-chain]
rpc_url = "${RPC_CHAINID}"

[forks.new-chain.vars]
chain_id = CHAINID
name = "Chain Name"
# ... all required fields
contracts = ["ALL"]
```

2. Set RPC environment variable:

```bash
export RPC_CHAINID=https://rpc.url
```

3. Deploy:

```bash
forge script deploy/DeployMain.s.sol:DeployMain \
  --broadcast \
  --sig "run(uint256[])" \
  --private-key $PRIVATE_KEY \
  "[CHAINID]"
```

## Troubleshooting

### Common Issues

**"No chains found in configuration"**
- Verify config.toml has properly configured chains
- Check RPC URLs are set for target chains

**"Safe Singleton Factory not deployed"**
- Factory must exist at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`
- Most major chains have this deployed

**Contract already deployed**
- Normal for CREATE2 - existing contracts are skipped
- Change salt value to deploy to new addresses

**RPC errors**
- Verify RPC URLs are correct and accessible
- Check rate limits on public RPCs
- Consider paid RPC services for production

## Best Practices

1. **Always dry run first** - Test without `--broadcast`
2. **Save salt values** - Required for same addresses on new chains
3. **Use `["ALL"]` for contracts** - If you want complete deployment
4. **Commit registry files** - Provides deployment history
5. **Use `--multi --slow`** - Ensures proper multi-chain ordering
6. **Verify while deploying** - Use `--verify` flag

## Configuration Field Reference

| Field | Used By | Purpose |
|-------|---------|---------|
| `chain_id`, `name`, `is_testnet` | All scripts | Chain identification |
| `pause_authority` | DeployMain | Contract pause permissions |
| `funder_owner`, `funder_signer` | DeployMain, FundSigners | SimpleFunder control |
| `settler_owner` | DeployMain | SimpleSettler ownership |
| `l0_settler_owner` | DeployMain, ConfigureLayerZero | LayerZeroSettler ownership |
| `salt` | DeployMain | CREATE2 deployment salt |
| `contracts` | DeployMain | Which contracts to deploy |
| `target_balance` | FundSigners | Minimum signer balance |
| `simple_funder_address` | FundSigners, FundSimpleFunder | SimpleFunder location |
| `default_num_signers` | FundSigners | Number of signers |
| `layerzero_*` fields | ConfigureLayerZeroSettler | LayerZero configuration |

## Test Token Deployment

### DeployEXP - Test ERC20 Token

**Purpose**: Deploy a simple test ERC20 token for testing.

**Usage**:
```bash
# Deploy test token to a specific chain
forge script deploy/DeployEXP.s.sol:DeployEXP \
  --broadcast \
  --sig "run()" \
  --private-key $PRIVATE_KEY \
  --rpc-url $RPC_<CHAIN_ID>
```

The test token includes basic ERC20 functionality and can be minted by anyone. 
It should only be used for testing purposes.