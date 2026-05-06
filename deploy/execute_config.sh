#!/bin/bash

# Comprehensive deployment testing script for multiple chains
# This script deploys contracts, configures LayerZero, and funds signers
#
# Usage: bash deploy/test_deployment.sh [chain_id1] [chain_id2] ...
#
# Examples:
#   bash deploy/test_deployment.sh                    # Deploy to all chains in config.toml
#   bash deploy/test_deployment.sh 84532              # Deploy only to Base Sepolia
#   bash deploy/test_deployment.sh 84532 11155420     # Deploy to Base Sepolia and Optimism Sepolia
#   bash deploy/test_deployment.sh 11155111 84532 11155420  # Deploy to all three chains

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

# Function to get all chain IDs from config.toml
get_all_chains() {
    grep '^\[' deploy/config.toml | grep -v '\.' | sed 's/\[//g' | sed 's/\]//g'
}

# Parse command-line arguments
REQUESTED_CHAINS=()
if [ $# -gt 0 ]; then
    # User provided specific chain IDs to deploy to
    REQUESTED_CHAINS=("$@")
    log_info "Requested deployment for chain IDs: ${REQUESTED_CHAINS[*]}"
else
    # Get all chains from config.toml
    REQUESTED_CHAINS=($(get_all_chains))
    log_info "No specific chains requested, will deploy to all chains in config.toml: ${REQUESTED_CHAINS[*]}"
fi

# Start deployment process
log_info "Starting comprehensive deployment test"
if [ ${#REQUESTED_CHAINS[@]} -gt 0 ]; then
    log_info "Deploying to chains: ${REQUESTED_CHAINS[*]}"
fi
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

# Check RPC URLs for requested chains
for chain_id in "${REQUESTED_CHAINS[@]}"; do
    RPC_VAR="RPC_${chain_id}"
    if [ -z "${!RPC_VAR}" ]; then
        log_error "$RPC_VAR is not set in .env for chain $chain_id"
        log_info "Please set $RPC_VAR in your .env file"
        exit 1
    fi
done

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

# Update salt in config.toml for all requested chains
for chain_id in "${REQUESTED_CHAINS[@]}"; do
    if grep -q "^\[${chain_id}\.bytes32\]" deploy/config.toml; then
        # Get chain name if available
        CHAIN_NAME=$(sed -n "/^\[${chain_id}\.string\]/,/^\[/p" deploy/config.toml | grep "^name" | cut -d'"' -f2)
        if [ -z "$CHAIN_NAME" ]; then
            CHAIN_NAME="Chain $chain_id"
        fi
        
        log_info "Updating salt for $CHAIN_NAME ($chain_id) in config.toml"
        sed -i.bak "/^\[${chain_id}\.bytes32\]/,/^\[/ s/^salt = .*/salt = \"$RANDOM_SALT\"/" deploy/config.toml
    else
        log_warning "No bytes32 section found for chain $chain_id, skipping salt update"
    fi
done

# Clean up backup files
rm -f deploy/config.toml.bak

log_info "Salt updated in config.toml for all requested chains"
log_warning "⚠️  IMPORTANT: Save this salt value if you need to deploy to the same addresses on other chains: $RANDOM_SALT"
echo ""

# Step 4: Deploy contracts to Base Sepolia and Optimism Sepolia
echo "========================================================================"
# Build chain array string for forge script
CHAIN_ARRAY="["
for i in "${!REQUESTED_CHAINS[@]}"; do
    if [ $i -gt 0 ]; then
        CHAIN_ARRAY="${CHAIN_ARRAY},"
    fi
    CHAIN_ARRAY="${CHAIN_ARRAY}${REQUESTED_CHAINS[$i]}"
done
CHAIN_ARRAY="${CHAIN_ARRAY}]"

log_info "STEP 1: Deploying contracts to chains: $CHAIN_ARRAY"
echo "========================================================================"

forge script deploy/DeployMain.s.sol:DeployMain \
    --broadcast --multi --slow \
    --sig "run(uint256[])" "$CHAIN_ARRAY" \
    --private-key $PRIVATE_KEY \
    -vvv

check_success "Contract deployment"
echo ""

# Step 5: Configure LayerZero for cross-chain communication
echo "========================================================================"
log_info "STEP 2: Configuring LayerZero for cross-chain communication"
echo "========================================================================"

# Note: Using the same PRIVATE_KEY as requested (instead of L0_SETTLER_OWNER_PK)
forge script deploy/ConfigureLayerZeroSettler.s.sol:ConfigureLayerZeroSettler \
    --broadcast --multi --slow \
    --sig "run(uint256[])" "$CHAIN_ARRAY" \
    --private-key $PRIVATE_KEY \
    -vvv

check_success "LayerZero configuration"
echo ""

# Base Sepolia LayerZero verification
if [ ! -z "$LAYERZERO_SETTLER_BASE" ]; then
    log_info "Base Sepolia LayerZero configuration:"
    
    # Get LayerZero endpoint from config
    LZ_ENDPOINT_BASE=$(sed -n "/^\[84532\.address\]/,/^\[/p" deploy/config.toml | grep "layerzero_endpoint" | cut -d'"' -f2)
    LZ_EID_BASE=$(sed -n "/^\[84532\.uint\]/,/^\[/p" deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')
    LZ_SEND_ULN_BASE=$(sed -n "/^\[84532\.address\]/,/^\[/p" deploy/config.toml | grep "layerzero_send_uln302" | cut -d'"' -f2)
    LZ_RECEIVE_ULN_BASE=$(sed -n "/^\[84532\.address\]/,/^\[/p" deploy/config.toml | grep "layerzero_receive_uln302" | cut -d'"' -f2)
    
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
    LZ_ENDPOINT_OP=$(sed -n "/^\[11155420\.address\]/,/^\[/p" deploy/config.toml | grep "layerzero_endpoint" | cut -d'"' -f2)
    LZ_EID_OP=$(sed -n "/^\[11155420\.uint\]/,/^\[/p" deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')
    LZ_SEND_ULN_OP=$(sed -n "/^\[11155420\.address\]/,/^\[/p" deploy/config.toml | grep "layerzero_send_uln302" | cut -d'"' -f2)
    LZ_RECEIVE_ULN_OP=$(sed -n "/^\[11155420\.address\]/,/^\[/p" deploy/config.toml | grep "layerzero_receive_uln302" | cut -d'"' -f2)
    
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
LZ_EID_BASE=$(sed -n "/^\[84532\.uint\]/,/^\[/p" deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')
LZ_EID_OP=$(sed -n "/^\[11155420\.uint\]/,/^\[/p" deploy/config.toml | grep "layerzero_eid" | awk -F' = ' '{print $2}')

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

# Step 3: Fund signers and set them as gas wallets
echo "========================================================================"
log_info "STEP 3: Funding signers and setting them as gas wallets"
echo "========================================================================"

if [ -z "$GAS_SIGNER_MNEMONIC" ]; then
    log_error "Cannot proceed with FundSigners - GAS_SIGNER_MNEMONIC not set"
    exit 1
fi

forge script deploy/FundSigners.s.sol:FundSigners \
    --broadcast --multi --slow \
    --sig "run(uint256[])" "$CHAIN_ARRAY" \
    --private-key $PRIVATE_KEY \
    -vvv

check_success "Signer funding"
echo ""

# Final Step: Run comprehensive verification for all deployed contracts and configurations
echo "========================================================================"
log_info "FINAL VERIFICATION: Running comprehensive verification"
echo "========================================================================"

log_info "Running verification script for all deployments and configurations..."
bash deploy/verify_config.sh "${REQUESTED_CHAINS[@]}"
check_success "Comprehensive verification"

echo ""
echo "========================================================================"
log_info "DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "========================================================================"
log_info "✅ All contracts deployed to requested chains"
log_info "✅ LayerZero configured for cross-chain communication"
log_info "✅ Signers funded and set as gas wallets"
log_info "✅ All verifications passed"
echo ""
log_info "Deployment and configuration completed successfully for chains: ${REQUESTED_CHAINS[*]}"
exit 0

# The old verification code below is no longer needed since verify_config.sh handles everything
: '
# Old verification code starts here

# Derive signer addresses from mnemonic (first 3 for verification)
log_info "Checking signer balances..."

# First signer address (derived from the mnemonic)
SIGNER_0="0x33097354Acf259e1fD19fB91159BAE6ccf912Fdb"
SIGNER_1="0x49e1f963ddb4122BD3ccC786eB8F9983dABa8658"
SIGNER_2="0x46C66f82B32f04bf04D05ED92e10b57188BF408A"

# Get target balance from config
TARGET_BALANCE_BASE=$(sed -n "/^\[84532\.uint\]/,/^\[/p" deploy/config.toml | grep "target_balance" | awk -F' = ' '{print $2}' | tr -d '"')

# Check balances on Base Sepolia
log_info "Base Sepolia (84532) signer balances (target: $TARGET_BALANCE_BASE wei):"
BALANCE_0_BASE=$(cast balance $SIGNER_0 --rpc-url $RPC_84532 2>/dev/null || echo "0")
BALANCE_1_BASE=$(cast balance $SIGNER_1 --rpc-url $RPC_84532 2>/dev/null || echo "0")
BALANCE_2_BASE=$(cast balance $SIGNER_2 --rpc-url $RPC_84532 2>/dev/null || echo "0")

# Check if balances meet target
if [ "$BALANCE_0_BASE" -ge "$TARGET_BALANCE_BASE" ]; then
    log_info "  Signer 0 ($SIGNER_0): $BALANCE_0_BASE wei ✓"
else
    log_warning "  Signer 0 ($SIGNER_0): $BALANCE_0_BASE wei (below target)"
fi

if [ "$BALANCE_1_BASE" -ge "$TARGET_BALANCE_BASE" ]; then
    log_info "  Signer 1 ($SIGNER_1): $BALANCE_1_BASE wei ✓"
else
    log_warning "  Signer 1 ($SIGNER_1): $BALANCE_1_BASE wei (below target)"
fi

if [ "$BALANCE_2_BASE" -ge "$TARGET_BALANCE_BASE" ]; then
    log_info "  Signer 2 ($SIGNER_2): $BALANCE_2_BASE wei ✓"
else
    log_warning "  Signer 2 ($SIGNER_2): $BALANCE_2_BASE wei (below target)"
fi

# Get target balance from config
TARGET_BALANCE_OP=$(sed -n "/^\[11155420\.uint\]/,/^\[/p" deploy/config.toml | grep "target_balance" | awk -F' = ' '{print $2}' | tr -d '"')

# Check balances on Optimism Sepolia
log_info "Optimism Sepolia (11155420) signer balances (target: $TARGET_BALANCE_OP wei):"
BALANCE_0_OP=$(cast balance $SIGNER_0 --rpc-url $RPC_11155420 2>/dev/null || echo "0")
BALANCE_1_OP=$(cast balance $SIGNER_1 --rpc-url $RPC_11155420 2>/dev/null || echo "0")
BALANCE_2_OP=$(cast balance $SIGNER_2 --rpc-url $RPC_11155420 2>/dev/null || echo "0")

# Check if balances meet target
if [ "$BALANCE_0_OP" -ge "$TARGET_BALANCE_OP" ]; then
    log_info "  Signer 0 ($SIGNER_0): $BALANCE_0_OP wei ✓"
else
    log_warning "  Signer 0 ($SIGNER_0): $BALANCE_0_OP wei (below target)"
fi

if [ "$BALANCE_1_OP" -ge "$TARGET_BALANCE_OP" ]; then
    log_info "  Signer 1 ($SIGNER_1): $BALANCE_1_OP wei ✓"
else
    log_warning "  Signer 1 ($SIGNER_1): $BALANCE_1_OP wei (below target)"
fi

if [ "$BALANCE_2_OP" -ge "$TARGET_BALANCE_OP" ]; then
    log_info "  Signer 2 ($SIGNER_2): $BALANCE_2_OP wei ✓"
else
    log_warning "  Signer 2 ($SIGNER_2): $BALANCE_2_OP wei (below target)"
fi

# Verify gas wallets and orchestrators in SimpleFunder
log_info "Checking SimpleFunder configuration..."

# Read orchestrator addresses from config.toml
# supported_orchestrators is an array like ["0xAddr1", "0xAddr2"]
# For simplicity, we'll extract the first orchestrator address
ORCHESTRATOR_BASE_CONFIG=$(sed -n "/^\[84532\.address\]/,/^\[/p" deploy/config.toml | grep "supported_orchestrators" | sed 's/.*\["\([^"]*\)".*/\1/')
ORCHESTRATOR_OP_CONFIG=$(sed -n "/^\[11155420\.address\]/,/^\[/p" deploy/config.toml | grep "supported_orchestrators" | sed 's/.*\["\([^"]*\)".*/\1/')

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
'  # End of commented old verification code