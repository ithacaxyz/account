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

All configuration is in `deploy/config.toml` using the StdConfig format:

```toml
[base-sepolia]
endpoint_url = "${RPC_84532}"

[base-sepolia.bool]
is_testnet = true

[base-sepolia.address]
# Chain identification
funder_owner = "0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4"
funder_signer = "0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4"
settler_owner = "0x0000000000000000000000000000000000000004"
l0_settler_owner = "0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4"
l0_settler_signer = "0x0000000000000000000000000000000000000006"
layerzero_endpoint = "0x6EDCE65403992e310A62460808c4b910D972f10f"
simple_funder_address = "0x09F6eF9525efAdb6167dFe71fFcfbE306De07988"
layerzero_settler_address = "0xd71d3c3ff2249A67cEa12030b20E66734fB1f833"
layerzero_send_uln302 = "0xC1868e054425D378095A003EcbA3823a5D0135C9"
layerzero_receive_uln302 = "0x12523de19dc41c91F7d2093E0CFbB76b17012C8d"
dvn_layerzero_labs = "0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6"
dvn_google_cloud = "0xFc9d8E5d3FaB22fB6E93E9E2C90916E9dCa83Ade"
exp_minter_address = "0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4"
supported_orchestrators = ["0xEd7c1e839381c489Dcd1ED3CE1B0e79DaE714f77"]

# Deployed contract addresses - automatically written during deployment
orchestrator_deployed = "0xC662Af195CD57bC330552f3E2Be5E03Ef69cB041"
ithaca_account_deployed = "0x49627C39cC7f39f95540C2100f18608f2365a59f"
account_proxy_deployed = "0xD2a48e4635fCB2437d2e482122137F06C8433706"
simulator_deployed = "0x332A5Cd675D9d26c4af3BF618A7175d0D623CABA"
simple_funder_deployed = "0x1ADE5D4CE3183D913791DEcaeaD42Fff193AeF8F"
escrow_deployed = "0xD1c7e21f2a50A2cDDCFaf554b998a800C3C35aD1"
simple_settler_deployed = "0x3291f7Ce832997920874d70d68A8186B388024F5"
layerzero_settler_deployed = "0xBDb45dA9e075a9fCbdf8fAa9d0c93A21b3D8671a"
exp_token_deployed = "0xaeB83430528fB0DeE5E15bF07A5056B6c0b37809"
exp2_token_deployed = "0x246c631Dac318a13023e98aB925499930c9801fB"

[base-sepolia.uint]
chain_id = 84532
layerzero_eid = 40245
target_balance = "1000000000000000"  # Target balance per signer (0.001 ETH) - must be quoted for large numbers
default_num_signers = 10             # Number of signers to fund
layerzero_confirmations = 1
layerzero_max_message_size = 10000
layerzero_optional_dvn_threshold = 0
exp_mint_amount = "5000000000000000000000"  # Amount to mint (in wei) - must be quoted
layerzero_destination_chain_ids = [11155420]

[base-sepolia.bytes32]
salt = "0x0000000000000000000000000000000000000000000000000000000000005678"  # CREATE2 salt (SAVE THIS!)

[base-sepolia.string]
name = "Base Sepolia"
contracts = ["ALL"]  # Or specific: ["Orchestrator", "IthacaAccount"]
layerzero_required_dvns = ["dvn_layerzero_labs"]
layerzero_optional_dvns = []
```

### Deployed Address Management

**Automatic Address Writing**: The deployment scripts automatically write deployed contract addresses to the config file during broadcast operations:

- ✅ **During `--broadcast`**: Deployed addresses are written to config.toml as `contract_name_deployed = "0x..."`
- ❌ **During simulation** (no `--broadcast`): No config writes occur - safe for testing
- 📍 **Address detection**: Scripts always check actual on-chain state, not config file data
- 🔄 **State synchronization**: Config file stays in sync with actual deployments

### Available Contracts

- **Orchestrator**
- **IthacaAccount**
- **AccountProxy**
- **Simulator**
- **SimpleFunder**
- **Escrow** (Only needed for Interop Chains)
- **SimpleSettler** (Only needed for Interop testing)
- **LayerZeroSettler** (Only needed for Interop Chains)
- **ExpToken** - Test ERC20 tokens (Testnet only, automatically included with "ALL")
- **ALL** - Deploys all contracts (+ ExpToken on testnets)

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
4. Sets configured orchestrators in SimpleFunder

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
- **Deployment decisions based on on-chain state** - Scripts check actual deployed contracts, not config file data

## Adding New Chains

1. Add configuration to `deploy/config.toml`:

```toml
[new-chain]
endpoint_url = "${RPC_CHAINID}"

[new-chain.bool]
is_testnet = true

[new-chain.address]
funder_owner = "0x..."
# ... all required fields

[new-chain.uint]
chain_id = CHAINID
# ... all required fields

[new-chain.bytes32]
salt = "0x0000000000000000000000000000000000000000000000000000000000005678"

[new-chain.string]
name = "Chain Name"
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
7. **Large numbers must be quoted in TOML** - Use `"1000000000000000000"` not `1000000000000000000`

## Configuration Field Reference

| Field                                   | Used By                        | Purpose                                          |
| --------------------------------------- | ------------------------------ | ------------------------------------------------ |
| `chain_id`, `name`, `is_testnet`        | All scripts                    | Chain identification                             |
| `pause_authority`                       | DeployMain                     | Contract pause permissions                       |
| `funder_owner`, `funder_signer`         | DeployMain, FundSigners        | SimpleFunder control                             |
| `settler_owner`                         | DeployMain                     | SimpleSettler ownership                          |
| `l0_settler_owner`                      | DeployMain, ConfigureLayerZero | LayerZeroSettler ownership                       |
| `salt`                                  | DeployMain                     | CREATE2 deployment salt                          |
| `contracts`                             | DeployMain                     | Which contracts to deploy                        |
| `target_balance`                        | FundSigners                    | Minimum signer balance                           |
| `simple_funder_address`                 | FundSigners, FundSimpleFunder  | SimpleFunder location                            |
| `default_num_signers`                   | FundSigners                    | Number of signers                                |
| `supported_orchestrators`               | FundSigners                    | Orchestrator addresses to enable in SimpleFunder |
| `layerzero_*` fields                    | ConfigureLayerZeroSettler      | LayerZero configuration                          |
| `exp_minter_address`, `exp_mint_amount` | DeployMain (testnet)           | ExpToken deployment                              |
| `*_deployed` fields                     | All scripts                    | Auto-written deployed contract addresses         |

## ExpToken Deployment (Testnets Only)

### Automatic ExpToken Deployment

**Purpose**: Deploy EXP and EXP2 test tokens automatically on testnet chains.

**Behavior**:

- **Testnets** (`is_testnet = true`): ExpToken automatically included when using `["ALL"]` contracts
- **Production** (`is_testnet = false`): ExpToken never deployed, regardless of configuration
- **Two tokens deployed**: "EXP" and "EXP2" with hardcoded names
- **Same configuration**: Both tokens use the same minter address and mint amount

### Configuration Requirements

For testnet chains, **both fields are required** (deployment will fail if missing):

```toml
[testnet-name.bool]
is_testnet = true

[testnet-name.address]
exp_minter_address = "0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4"  # REQUIRED

[testnet-name.uint]
exp_mint_amount = "5000000000000000000000"  # REQUIRED (5000 tokens in wei)

[testnet-name.string]
contracts = ["ALL"]  # ExpToken automatically included for testnets
```

### Deployment Details

**Two tokens are deployed**:

1. **EXP Token**: Name and symbol "EXP"
2. **EXP2 Token**: Name and symbol "EXP2"

**Both tokens**:

- Use CREATE2 for deterministic addresses
- Mint `exp_mint_amount` tokens to `exp_minter_address`
- Are deployed at the end of the contract deployment sequence
- Are saved to registry files as "ExpToken" and "Exp2Token"

### Examples

**Base Sepolia (Testnet)**:

```toml
[base-sepolia.bool]
is_testnet = true

[base-sepolia.address]
exp_minter_address = "0xB6918DaaB07e31556B45d7Fd2a33021Bc829adf4"

[base-sepolia.uint]
exp_mint_amount = "5000000000000000000000"

[base-sepolia.string]
contracts = ["ALL"]  # Deploys 8 core contracts + ExpToken
```

## Supporting Bash Scripts

### Overview

There are two main scripts that handle multi-chain deployments and configuration verification:

- **`deploy/execute_config.sh`** - Brings up the whole environment, by calling all scripts correctly.
- **`deploy/verify_config.sh`** - Verifies that the values in the config.toml are all set and configured correctly.

### Usage

#### Execute Deployment

```bash
# Deploy to specific chains
./deploy/execute_config.sh 84532 11155420

# Deploy to all chains in config.toml
./deploy/execute_config.sh
```

The script performs these steps:
1. Validates configuration for selected chains
2. Deploys core contracts (IthacaAccount, SimpleFunder, SimpleSettler, etc.)
3. Configures LayerZero cross-chain messaging
4. Funds signer accounts with gas tokens
5. Verifies all deployments match configuration

#### Verify Configuration

```bash
# Verify specific chains
./deploy/verify_config.sh 84532 11155420

# Verify all chains in config.toml
./deploy/verify_config.sh
```

The script checks:
- Required environment variables (RPC URLs, private keys)
- Contract deployment addresses match config.toml
- Signer accounts have sufficient gas balances
- LayerZero endpoints and DVN configurations
- Cross-chain pathway configurations

### Configuration

Both scripts read from `deploy/config.toml` which defines per-chain:
- RPC endpoints and chain metadata
- Contract addresses and owners
- LayerZero endpoint configurations
- Cross-chain destination mappings
- Gas funding amounts

Environment variables required:
- `PRIVATE_KEY` - Deployer private key
- `GAS_SIGNER_MNEMONIC` - Mnemonic for signer accounts
- `RPC_<chainId>` - RPC URL for each chain (e.g., `RPC_84532`)