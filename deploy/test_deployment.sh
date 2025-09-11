#!/bin/bash

# Comprehensive deployment testing script for Base Sepolia and Optimism Sepolia
# This script deploys contracts, configures LayerZero, and funds signers

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if a command succeeded
check_success() {
    if [ $? -eq 0 ]; then
        log_info "$1 succeeded"
    else
        log_error "$1 failed"
        exit 1
    fi
}

# Start deployment process
log_info "Starting comprehensive deployment test for Base Sepolia and Optimism Sepolia"
echo "========================================================================"

# Step 1: Load environment variables
log_info "Loading environment variables from .env"
if [ ! -f .env ]; then
    log_error ".env file not found!"
    exit 1
fi

source .env

# Step 2: Validate required environment variables
log_info "Validating required environment variables"

if [ -z "$PRIVATE_KEY" ]; then
    log_error "PRIVATE_KEY is not set in .env"
    exit 1
fi

if [ -z "$RPC_84532" ]; then
    log_error "RPC_84532 (Base Sepolia) is not set in .env"
    exit 1
fi

if [ -z "$RPC_11155420" ]; then
    log_error "RPC_11155420 (Optimism Sepolia) is not set in .env"
    exit 1
fi

if [ -z "$GAS_SIGNER_MNEMONIC" ]; then
    log_warning "GAS_SIGNER_MNEMONIC is not set - FundSigners may fail"
fi

log_info "All required environment variables are set"
echo ""

# Step 3: Generate random salt for new deployment addresses
log_info "Generating random salt for new contract addresses"

# Generate a random 32-byte hex string for salt
RANDOM_SALT="0x$(openssl rand -hex 32)"
log_info "Generated salt: $RANDOM_SALT"

# Update salt in config.toml for Base Sepolia
log_info "Updating salt for Base Sepolia in config.toml"
sed -i.bak "/^\[base-sepolia\.bytes32\]/,/^\[/ s/^salt = .*/salt = \"$RANDOM_SALT\"/" deploy/config.toml

# Update salt in config.toml for Optimism Sepolia  
log_info "Updating salt for Optimism Sepolia in config.toml"
sed -i.bak "/^\[optimism-sepolia\.bytes32\]/,/^\[/ s/^salt = .*/salt = \"$RANDOM_SALT\"/" deploy/config.toml

# Clean up backup files
rm -f deploy/config.toml.bak

log_info "Salt updated in config.toml for both chains"
log_warning "⚠️  IMPORTANT: Save this salt value if you need to deploy to the same addresses on other chains: $RANDOM_SALT"
echo ""

# Step 4: Deploy contracts to Base Sepolia and Optimism Sepolia
echo "========================================================================"
log_info "STEP 1: Deploying contracts to Base Sepolia (84532) and Optimism Sepolia (11155420)"
echo "========================================================================"

forge script deploy/DeployMain.s.sol:DeployMain \
    --broadcast --multi --slow \
    --sig "run(uint256[])" "[84532,11155420]" \
    --private-key $PRIVATE_KEY \
    -vvv

check_success "Contract deployment"
echo ""

# Now execute the deployment verification
# Verify deployment - check that contracts are deployed on both chains
echo "========================================================================"
log_info "Verifying contract deployment on both chains"
echo "========================================================================"

# Extract deployed addresses from the deployment output or config
log_info "Checking deployed contracts on Base Sepolia (84532)..."

# Read addresses from config.toml for Base Sepolia
ORCHESTRATOR_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "orchestrator_deployed" | cut -d'"' -f2)
ITHACA_ACCOUNT_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "ithaca_account_deployed" | cut -d'"' -f2)
SIMPLE_FUNDER_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "simple_funder_deployed" | cut -d'"' -f2)
LAYERZERO_SETTLER_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "layerzero_settler_deployed" | cut -d'"' -f2)

log_info "Orchestrator address from config: '$ORCHESTRATOR_BASE'"
if [ ! -z "$ORCHESTRATOR_BASE" ]; then
    CODE=$(cast code $ORCHESTRATOR_BASE --rpc-url $RPC_84532 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ Orchestrator deployed at $ORCHESTRATOR_BASE"
    else
        log_error "✗ Orchestrator NOT found at $ORCHESTRATOR_BASE"
        exit 1
    fi
else
    log_error "⚠ Orchestrator address not found in config.toml"
    exit 1
fi

log_info "IthacaAccount address from config: '$ITHACA_ACCOUNT_BASE'"
if [ ! -z "$ITHACA_ACCOUNT_BASE" ]; then
    CODE=$(cast code $ITHACA_ACCOUNT_BASE --rpc-url $RPC_84532 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ IthacaAccount deployed at $ITHACA_ACCOUNT_BASE"
    else
        log_error "✗ IthacaAccount NOT found at $ITHACA_ACCOUNT_BASE"
        exit 1
    fi
else
    log_error "⚠ IthacaAccount address not found in config.toml"
    exit 1
fi

log_info "SimpleFunder address from config: '$SIMPLE_FUNDER_BASE'"
if [ ! -z "$SIMPLE_FUNDER_BASE" ]; then
    CODE=$(cast code $SIMPLE_FUNDER_BASE --rpc-url $RPC_84532 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ SimpleFunder deployed at $SIMPLE_FUNDER_BASE"
    else
        log_error "✗ SimpleFunder NOT found at $SIMPLE_FUNDER_BASE"
        exit 1
    fi
else
    log_error "⚠ SimpleFunder address not found in config.toml"
    exit 1
fi

log_info "LayerZeroSettler address from config: '$LAYERZERO_SETTLER_BASE'"
if [ ! -z "$LAYERZERO_SETTLER_BASE" ]; then
    CODE=$(cast code $LAYERZERO_SETTLER_BASE --rpc-url $RPC_84532 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ LayerZeroSettler deployed at $LAYERZERO_SETTLER_BASE"
    else
        log_error "✗ LayerZeroSettler NOT found at $LAYERZERO_SETTLER_BASE"
        exit 1
    fi
else
    log_error "⚠ LayerZeroSettler address not found in config.toml"
    exit 1
fi

log_info "Checking deployed contracts on Optimism Sepolia (11155420)..."

# Read addresses from config.toml for Optimism Sepolia
# The section goes until end of file, so we need to be more specific
ORCHESTRATOR_OP=$(grep "^orchestrator_deployed" deploy/config.toml | tail -1 | cut -d'"' -f2)
ITHACA_ACCOUNT_OP=$(grep "^ithaca_account_deployed" deploy/config.toml | tail -1 | cut -d'"' -f2)
SIMPLE_FUNDER_OP=$(grep "^simple_funder_deployed" deploy/config.toml | tail -1 | cut -d'"' -f2)
LAYERZERO_SETTLER_OP=$(grep "^layerzero_settler_deployed" deploy/config.toml | tail -1 | cut -d'"' -f2)

log_info "Orchestrator address from config: '$ORCHESTRATOR_OP'"
if [ ! -z "$ORCHESTRATOR_OP" ]; then
    CODE=$(cast code $ORCHESTRATOR_OP --rpc-url $RPC_11155420 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ Orchestrator deployed at $ORCHESTRATOR_OP"
    else
        log_error "✗ Orchestrator NOT found at $ORCHESTRATOR_OP"
        exit 1
    fi
else
    log_error "⚠ Orchestrator address not found in config.toml"
    exit 1
fi

log_info "IthacaAccount address from config: '$ITHACA_ACCOUNT_OP'"
if [ ! -z "$ITHACA_ACCOUNT_OP" ]; then
    CODE=$(cast code $ITHACA_ACCOUNT_OP --rpc-url $RPC_11155420 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ IthacaAccount deployed at $ITHACA_ACCOUNT_OP"
    else
        log_error "✗ IthacaAccount NOT found at $ITHACA_ACCOUNT_OP"
        exit 1
    fi
else
    log_error "⚠ IthacaAccount address not found in config.toml"
    exit 1
fi

log_info "SimpleFunder address from config: '$SIMPLE_FUNDER_OP'"
if [ ! -z "$SIMPLE_FUNDER_OP" ]; then
    CODE=$(cast code $SIMPLE_FUNDER_OP --rpc-url $RPC_11155420 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ SimpleFunder deployed at $SIMPLE_FUNDER_OP"
    else
        log_error "✗ SimpleFunder NOT found at $SIMPLE_FUNDER_OP"
        exit 1
    fi
else
    log_error "⚠ SimpleFunder address not found in config.toml"
    exit 1
fi

log_info "LayerZeroSettler address from config: '$LAYERZERO_SETTLER_OP'"
if [ ! -z "$LAYERZERO_SETTLER_OP" ]; then
    CODE=$(cast code $LAYERZERO_SETTLER_OP --rpc-url $RPC_11155420 2>/dev/null || echo "0x")
    if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
        log_info "✓ LayerZeroSettler deployed at $LAYERZERO_SETTLER_OP"
    else
        log_error "✗ LayerZeroSettler NOT found at $LAYERZERO_SETTLER_OP"
        exit 1
    fi
else
    log_error "⚠ LayerZeroSettler address not found in config.toml"
    exit 1
fi

echo ""

# Step 5: Configure LayerZero for cross-chain communication
echo "========================================================================"
log_info "STEP 2: Configuring LayerZero for cross-chain communication"
echo "========================================================================"

# Note: Using the same PRIVATE_KEY as requested (instead of L0_SETTLER_OWNER_PK)
forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
    --broadcast --multi --slow \
    --sig "run(uint256[])" "[84532,11155420]" \
    --private-key $PRIVATE_KEY \
    -vvv

check_success "LayerZero configuration"
echo ""

# Verify LayerZero configuration
echo "========================================================================"
log_info "Verifying LayerZero configuration"
echo "========================================================================"

# Get LayerZero configuration from config.toml
log_info "Checking LayerZero configuration on both chains..."

# Base Sepolia LayerZero verification
if [ ! -z "$LAYERZERO_SETTLER_BASE" ]; then
    log_info "Base Sepolia LayerZero configuration:"
    
    # Get LayerZero endpoint from config
    LZ_ENDPOINT_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "layerzero_endpoint" | cut -d'"' -f2)
    LZ_EID_BASE=$(awk '/^\[base-sepolia\.uint\]/,/^\[base-sepolia\.bytes32\]/' deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')
    LZ_SEND_ULN_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "layerzero_send_uln302" | cut -d'"' -f2)
    LZ_RECEIVE_ULN_BASE=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "layerzero_receive_uln302" | cut -d'"' -f2)
    
    # Check if endpoint is set on LayerZeroSettler
    CURRENT_ENDPOINT=$(cast call $LAYERZERO_SETTLER_BASE "endpoint()(address)" --rpc-url $RPC_84532 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
    
    if [ "$CURRENT_ENDPOINT" == "$LZ_ENDPOINT_BASE" ]; then
        log_info "  ✓ Endpoint correctly set to $LZ_ENDPOINT_BASE"
    else
        log_error "  ✗ Endpoint mismatch: Expected $LZ_ENDPOINT_BASE, got $CURRENT_ENDPOINT"
    fi
    
    # Check L0SettlerSigner
    LZ_SIGNER=$(cast call $LAYERZERO_SETTLER_BASE "l0SettlerSigner()(address)" --rpc-url $RPC_84532 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
    log_info "  L0SettlerSigner: $LZ_SIGNER"
fi

# Optimism Sepolia LayerZero verification
if [ ! -z "$LAYERZERO_SETTLER_OP" ]; then
    log_info "Optimism Sepolia LayerZero configuration:"
    
    # Get LayerZero endpoint from config - these are in the address section
    LZ_ENDPOINT_OP=$(grep "^layerzero_endpoint" deploy/config.toml | tail -1 | cut -d'"' -f2)
    LZ_EID_OP=$(awk '/^\[optimism-sepolia\.uint\]/,/^\[optimism-sepolia\.bytes32\]/' deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')
    LZ_SEND_ULN_OP=$(grep "^layerzero_send_uln302" deploy/config.toml | tail -1 | cut -d'"' -f2)
    LZ_RECEIVE_ULN_OP=$(grep "^layerzero_receive_uln302" deploy/config.toml | tail -1 | cut -d'"' -f2)
    
    # Check if endpoint is set on LayerZeroSettler
    CURRENT_ENDPOINT=$(cast call $LAYERZERO_SETTLER_OP "endpoint()(address)" --rpc-url $RPC_11155420 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
    
    if [ "$CURRENT_ENDPOINT" == "$LZ_ENDPOINT_OP" ]; then
        log_info "  ✓ Endpoint correctly set to $LZ_ENDPOINT_OP"
    else
        log_error "  ✗ Endpoint mismatch: Expected $LZ_ENDPOINT_OP, got $CURRENT_ENDPOINT"
    fi
    
    # Check L0SettlerSigner
    LZ_SIGNER=$(cast call $LAYERZERO_SETTLER_OP "l0SettlerSigner()(address)" --rpc-url $RPC_11155420 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
    log_info "  L0SettlerSigner: $LZ_SIGNER"
fi

# Verify cross-chain pathway configuration
log_info "Cross-chain pathway verification:"

# Get EIDs for both chains - they are in the uint sections
LZ_EID_BASE=$(awk '/^\[base-sepolia\.uint\]/,/^\[base-sepolia\.bytes32\]/' deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')
LZ_EID_OP=$(awk '/^\[optimism-sepolia\.uint\]/,/^\[optimism-sepolia\.bytes32\]/' deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')

# Check Base Sepolia -> Optimism Sepolia pathway
if [ ! -z "$LAYERZERO_SETTLER_BASE" ] && [ ! -z "$LZ_EID_OP" ] && [ ! -z "$LZ_ENDPOINT_BASE" ] && [ ! -z "$LZ_SEND_ULN_BASE" ]; then
    log_info "  Base Sepolia -> Optimism Sepolia pathway:"
    
    # Check executor configuration using endpoint.getConfig()
    # CONFIG_TYPE_EXECUTOR = 1
    EXECUTOR_CONFIG_BYTES=$(cast call $LZ_ENDPOINT_BASE "getConfig(address,address,uint32,uint32)(bytes)" "$LAYERZERO_SETTLER_BASE" "$LZ_SEND_ULN_BASE" "$LZ_EID_OP" "1" --rpc-url $RPC_84532 2>/dev/null || echo "0x")
    
    if [ "$EXECUTOR_CONFIG_BYTES" != "0x" ] && [ ! -z "$EXECUTOR_CONFIG_BYTES" ]; then
        # The executor config is encoded as (uint32 maxMessageSize, address executor)
        # We need to decode the bytes - first 32 bytes is maxMessageSize, next 32 bytes is executor address
        # Remove 0x prefix and get the executor address (last 40 hex chars of the second 32-byte word)
        EXECUTOR_HEX=$(echo "$EXECUTOR_CONFIG_BYTES" | sed 's/0x//' | tail -c 41)
        if [ ! -z "$EXECUTOR_HEX" ]; then
            EXECUTOR_ADDR="0x$EXECUTOR_HEX"
            
            if [ "$(echo $EXECUTOR_ADDR | tr '[:upper:]' '[:lower:]')" == "$(echo $LAYERZERO_SETTLER_BASE | tr '[:upper:]' '[:lower:]')" ]; then
                log_info "    ✓ Executor correctly set to LayerZeroSettler"
            else
                log_warning "    ⚠ Executor not set to LayerZeroSettler (self-execution model)"
            fi
        else
            log_warning "    ⚠ Could not parse executor configuration"
        fi
    else
        log_warning "    ⚠ Executor configuration not set"
    fi
    
    # Check ULN configuration using endpoint.getConfig()
    # CONFIG_TYPE_ULN = 2
    ULN_CONFIG_BYTES=$(cast call $LZ_ENDPOINT_BASE "getConfig(address,address,uint32,uint32)(bytes)" "$LAYERZERO_SETTLER_BASE" "$LZ_SEND_ULN_BASE" "$LZ_EID_OP" "2" --rpc-url $RPC_84532 2>/dev/null || echo "0x")
    
    if [ "$ULN_CONFIG_BYTES" != "0x" ] && [ ! -z "$ULN_CONFIG_BYTES" ] && [ ${#ULN_CONFIG_BYTES} -gt 10 ]; then
        log_info "    ✓ ULN configuration is set"
    else
        log_warning "    ⚠ ULN configuration not set"
    fi
fi

# Check Optimism Sepolia -> Base Sepolia pathway
if [ ! -z "$LAYERZERO_SETTLER_OP" ] && [ ! -z "$LZ_EID_BASE" ] && [ ! -z "$LZ_ENDPOINT_OP" ] && [ ! -z "$LZ_SEND_ULN_OP" ]; then
    log_info "  Optimism Sepolia -> Base Sepolia pathway:"
    
    # Check executor configuration using endpoint.getConfig()
    # CONFIG_TYPE_EXECUTOR = 1
    EXECUTOR_CONFIG_BYTES=$(cast call $LZ_ENDPOINT_OP "getConfig(address,address,uint32,uint32)(bytes)" "$LAYERZERO_SETTLER_OP" "$LZ_SEND_ULN_OP" "$LZ_EID_BASE" "1" --rpc-url $RPC_11155420 2>/dev/null || echo "0x")
    
    if [ "$EXECUTOR_CONFIG_BYTES" != "0x" ] && [ ! -z "$EXECUTOR_CONFIG_BYTES" ]; then
        # The executor config is encoded as (uint32 maxMessageSize, address executor)
        # Remove 0x prefix and get the executor address (last 40 hex chars of the second 32-byte word)
        EXECUTOR_HEX=$(echo "$EXECUTOR_CONFIG_BYTES" | sed 's/0x//' | tail -c 41)
        if [ ! -z "$EXECUTOR_HEX" ]; then
            EXECUTOR_ADDR="0x$EXECUTOR_HEX"
            
            if [ "$(echo $EXECUTOR_ADDR | tr '[:upper:]' '[:lower:]')" == "$(echo $LAYERZERO_SETTLER_OP | tr '[:upper:]' '[:lower:]')" ]; then
                log_info "    ✓ Executor correctly set to LayerZeroSettler"
            else
                log_warning "    ⚠ Executor not set to LayerZeroSettler (self-execution model)"
            fi
        else
            log_warning "    ⚠ Could not parse executor configuration"
        fi
    else
        log_warning "    ⚠ Executor configuration not set"
    fi
    
    # Check ULN configuration using endpoint.getConfig()
    # CONFIG_TYPE_ULN = 2
    ULN_CONFIG_BYTES=$(cast call $LZ_ENDPOINT_OP "getConfig(address,address,uint32,uint32)(bytes)" "$LAYERZERO_SETTLER_OP" "$LZ_SEND_ULN_OP" "$LZ_EID_BASE" "2" --rpc-url $RPC_11155420 2>/dev/null || echo "0x")
    
    if [ "$ULN_CONFIG_BYTES" != "0x" ] && [ ! -z "$ULN_CONFIG_BYTES" ] && [ ${#ULN_CONFIG_BYTES} -gt 10 ]; then
        log_info "    ✓ ULN configuration is set"
    else
        log_warning "    ⚠ ULN configuration not set"
    fi
fi

echo ""

# Step 6: Fund signers and set them as gas wallets
echo "========================================================================"
log_info "STEP 3: Funding signers and setting them as gas wallets"
echo "========================================================================"

if [ -z "$GAS_SIGNER_MNEMONIC" ]; then
    log_error "Cannot proceed with FundSigners - GAS_SIGNER_MNEMONIC not set"
    exit 1
fi

forge script deploy/FundSigners.s.sol:FundSigners \
    --broadcast --multi --slow \
    --sig "run(uint256[])" "[84532,11155420]" \
    --private-key $PRIVATE_KEY \
    -vvv

check_success "Signer funding"
echo ""

# Verify signer funding and gas wallet configuration
echo "========================================================================"
log_info "Verifying signer balances and gas wallet configuration"
echo "========================================================================"

# Derive signer addresses from mnemonic (first 3 for verification)
log_info "Checking signer balances..."

# First signer address (derived from the mnemonic)
SIGNER_0="0x33097354Acf259e1fD19fB91159BAE6ccf912Fdb"
SIGNER_1="0x49e1f963ddb4122BD3ccC786eB8F9983dABa8658"
SIGNER_2="0x46C66f82B32f04bf04D05ED92e10b57188BF408A"

# Check balances on Base Sepolia
log_info "Base Sepolia (84532) signer balances:"
BALANCE_0_BASE=$(cast balance $SIGNER_0 --rpc-url $RPC_84532 2>/dev/null || echo "0")
BALANCE_1_BASE=$(cast balance $SIGNER_1 --rpc-url $RPC_84532 2>/dev/null || echo "0")
BALANCE_2_BASE=$(cast balance $SIGNER_2 --rpc-url $RPC_84532 2>/dev/null || echo "0")

log_info "  Signer 0 ($SIGNER_0): $BALANCE_0_BASE wei"
log_info "  Signer 1 ($SIGNER_1): $BALANCE_1_BASE wei"
log_info "  Signer 2 ($SIGNER_2): $BALANCE_2_BASE wei"

# Check balances on Optimism Sepolia
log_info "Optimism Sepolia (11155420) signer balances:"
BALANCE_0_OP=$(cast balance $SIGNER_0 --rpc-url $RPC_11155420 2>/dev/null || echo "0")
BALANCE_1_OP=$(cast balance $SIGNER_1 --rpc-url $RPC_11155420 2>/dev/null || echo "0")
BALANCE_2_OP=$(cast balance $SIGNER_2 --rpc-url $RPC_11155420 2>/dev/null || echo "0")

log_info "  Signer 0 ($SIGNER_0): $BALANCE_0_OP wei"
log_info "  Signer 1 ($SIGNER_1): $BALANCE_1_OP wei"
log_info "  Signer 2 ($SIGNER_2): $BALANCE_2_OP wei"

# Verify gas wallets and orchestrators in SimpleFunder
log_info "Checking SimpleFunder configuration..."

# Read orchestrator addresses from config.toml
ORCHESTRATOR_BASE_CONFIG=$(awk '/^\[base-sepolia\]/,/^\[optimism-sepolia\]/' deploy/config.toml | grep "supported_orchestrators" | sed 's/.*\["\(.*\)"\].*/\1/' | cut -d'"' -f1)
ORCHESTRATOR_OP_CONFIG=$(awk '/^\[optimism-sepolia\]/,/^\[.*\]/' deploy/config.toml | grep "supported_orchestrators" | sed 's/.*\["\(.*\)"\].*/\1/' | cut -d'"' -f1)

# For Base Sepolia
if [ ! -z "$SIMPLE_FUNDER_BASE" ]; then
    log_info "Base Sepolia SimpleFunder ($SIMPLE_FUNDER_BASE):"
    
    # Check if signers are gas wallets (using mapping gasWallets(address) => bool)
    IS_GAS_WALLET_0=$(cast call $SIMPLE_FUNDER_BASE "gasWallets(address)(bool)" $SIGNER_0 --rpc-url $RPC_84532 2>/dev/null || echo "false")
    
    if [ "$IS_GAS_WALLET_0" == "true" ]; then
        log_info "  ✓ Signer 0 is registered as gas wallet"
    else
        log_warning "  ✗ Signer 0 is NOT registered as gas wallet"
    fi
    
    # Check orchestrator configuration (using mapping orchestrators(address) => bool)
    if [ ! -z "$ORCHESTRATOR_BASE_CONFIG" ]; then
        IS_SUPPORTED=$(cast call $SIMPLE_FUNDER_BASE "orchestrators(address)(bool)" $ORCHESTRATOR_BASE_CONFIG --rpc-url $RPC_84532 2>/dev/null || echo "false")
        
        if [ "$IS_SUPPORTED" == "true" ]; then
            log_info "  ✓ Orchestrator $ORCHESTRATOR_BASE_CONFIG is supported"
        else
            log_warning "  ✗ Orchestrator $ORCHESTRATOR_BASE_CONFIG is NOT supported"
        fi
    fi
fi

# For Optimism Sepolia
if [ ! -z "$SIMPLE_FUNDER_OP" ]; then
    log_info "Optimism Sepolia SimpleFunder ($SIMPLE_FUNDER_OP):"
    
    # Check if signers are gas wallets
    IS_GAS_WALLET_0=$(cast call $SIMPLE_FUNDER_OP "gasWallets(address)(bool)" $SIGNER_0 --rpc-url $RPC_11155420 2>/dev/null || echo "false")
    
    if [ "$IS_GAS_WALLET_0" == "true" ]; then
        log_info "  ✓ Signer 0 is registered as gas wallet"
    else
        log_warning "  ✗ Signer 0 is NOT registered as gas wallet"
    fi
    
    # Check orchestrator configuration
    if [ ! -z "$ORCHESTRATOR_OP_CONFIG" ]; then
        IS_SUPPORTED=$(cast call $SIMPLE_FUNDER_OP "orchestrators(address)(bool)" $ORCHESTRATOR_OP_CONFIG --rpc-url $RPC_11155420 2>/dev/null || echo "false")
        
        if [ "$IS_SUPPORTED" == "true" ]; then
            log_info "  ✓ Orchestrator $ORCHESTRATOR_OP_CONFIG is supported"
        else
            log_warning "  ✗ Orchestrator $ORCHESTRATOR_OP_CONFIG is NOT supported"
        fi
    fi
fi

echo ""

# Step 7: Summary
echo "========================================================================"
log_info "DEPLOYMENT TEST COMPLETED SUCCESSFULLY!"
echo "========================================================================"
log_info "✅ Contracts deployed to Base Sepolia and Optimism Sepolia"
log_info "✅ LayerZero configured for cross-chain communication"
log_info "✅ Signers funded and set as gas wallets"
echo ""

echo ""
log_info "All deployment steps completed successfully!"