#!/bin/bash

# Verification script for deployed contracts and configuration
# This script performs all verification checks from test_deployment.sh
# without running any deployments or modifications

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

# Start verification process
echo "========================================================================"
log_info "Configuration and Deployment Verification Script"
log_info "This script verifies the current state without making any changes"
echo "========================================================================"

# Load environment variables
log_info "Loading environment variables from .env"
if [ ! -f .env ]; then
    log_error ".env file not found!"
    exit 1
fi

source .env

# Validate required environment variables (just check core ones)
log_info "Validating required environment variables"
required_vars=("PRIVATE_KEY" "GAS_SIGNER_MNEMONIC")
missing_vars=()

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    log_error "Missing required environment variables: ${missing_vars[*]}"
    exit 1
fi

log_info "Core environment variables are set"
echo ""

# Function to extract value from TOML for a specific chain section
extract_value() {
    local chain=$1
    local key=$2
    local config_file=$3
    
    # Get the next section after the chain section
    local next_section=$(awk "/^\[$chain\]/,0" "$config_file" | grep '^\[' | grep -v "^\[$chain" | head -1)
    
    if [ -z "$next_section" ]; then
        # This is the last section, get everything after it
        awk "/^\[$chain\]/,0" "$config_file" | grep "^$key" | head -1 | cut -d'"' -f2
    else
        # Get content between this section and the next
        awk "/^\[$chain\]/,/^${next_section//[/\\[}/ { if (/^$key/) print }" "$config_file" | head -1 | cut -d'"' -f2
    fi
}

# Function to extract uint value from TOML for a specific chain section
extract_uint_value() {
    local chain=$1
    local key=$2
    local config_file=$3
    
    # Get the next section after the chain.uint section
    local section="[$chain.uint]"
    local next_section=$(awk "/^\[$chain\.uint\]/,0" "$config_file" | grep '^\[' | grep -v "^\[$chain\.uint" | head -1)
    
    if [ -z "$next_section" ]; then
        # This is the last section
        awk "/^\[$chain\.uint\]/,0" "$config_file" | grep "^$key" | head -1 | awk -F' = ' '{print $2}' | tr -d '"'
    else
        # Get content between this section and the next
        awk "/^\[$chain\.uint\]/,/^${next_section//[/\\[}/ { if (/^$key/) print }" "$config_file" | head -1 | awk -F' = ' '{print $2}' | tr -d '"'
    fi
}

# Get all chain sections from config.toml (excluding .uint, .bytes32, .address, .bool, .string subsections)
get_chains() {
    grep '^\[' deploy/config.toml | grep -v '\.' | sed 's/\[//g' | sed 's/\]//g'
}

# ========================================================================
# SECTION 1: Verify Contract Deployments
# ========================================================================

echo "========================================================================"
log_info "SECTION 1: Verifying Contract Deployments"
echo "========================================================================"

log_info "Reading deployed contract addresses from config.toml..."

# Contract types to verify
CONTRACT_TYPES=("orchestrator_deployed:Orchestrator" "ithaca_account_deployed:IthacaAccount" "account_proxy_deployed:AccountProxy" "simulator_deployed:Simulator" "simple_funder_deployed:SimpleFunder" "escrow_deployed:Escrow" "simple_settler_deployed:SimpleSettler" "layerzero_settler_deployed:LayerZeroSettler" "exp_token_deployed:ExpToken" "exp2_token_deployed:Exp2Token")

# Get all chains
CHAINS=($(get_chains))
log_info "Found ${#CHAINS[@]} chain(s): ${CHAINS[*]}"
echo ""

TOTAL_FAILED=0

# Iterate over each chain
for chain in "${CHAINS[@]}"; do
    log_info "Checking deployed contracts on $chain..."
    
    # Get chain ID from config
    CHAIN_ID=$(extract_uint_value "$chain" "chain_id" "deploy/config.toml")
    
    if [ -z "$CHAIN_ID" ]; then
        log_warning "  Chain ID not found for $chain, skipping..."
        continue
    fi
    
    # Get RPC URL from environment variable
    RPC_VAR="RPC_${CHAIN_ID}"
    RPC_URL=${!RPC_VAR}
    
    if [ -z "$RPC_URL" ]; then
        log_warning "  RPC URL not set for chain $chain (ID: $CHAIN_ID), skipping..."
        log_warning "  Set environment variable $RPC_VAR to enable verification"
        continue
    fi
    
    log_info "  Chain ID: $CHAIN_ID"
    log_info "  RPC URL: $RPC_URL"
    
    CHAIN_FAILED=0
    
    # Check each contract type
    for contract_type in "${CONTRACT_TYPES[@]}"; do
        IFS=":" read -r key name <<< "$contract_type"
        
        # Extract address for this contract on this chain
        addr=$(extract_value "$chain" "$key" "deploy/config.toml")
        
        if [ ! -z "$addr" ]; then
            CODE=$(cast code $addr --rpc-url $RPC_URL 2>/dev/null || echo "0x")
            if [ "$CODE" != "0x" ] && [ ! -z "$CODE" ]; then
                log_info "    ✓ $name deployed at $addr"
            else
                log_error "    ✗ $name NOT found at $addr"
                CHAIN_FAILED=$((CHAIN_FAILED + 1))
            fi
        else
            log_warning "    ⚠ $name address not found in config.toml"
        fi
    done
    
    if [ $CHAIN_FAILED -eq 0 ]; then
        log_info "  ✅ All contracts verified on $chain"
    else
        log_error "  ❌ $CHAIN_FAILED contract(s) failed verification on $chain"
        TOTAL_FAILED=$((TOTAL_FAILED + CHAIN_FAILED))
    fi
    echo ""
done

if [ $TOTAL_FAILED -eq 0 ]; then
    log_info "✅ All contracts verified successfully across all chains!"
else
    log_error "❌ Total contract verification failures: $TOTAL_FAILED"
fi
echo ""

# ========================================================================
# SECTION 2: Verify LayerZero Configuration
# ========================================================================

echo "========================================================================"
log_info "SECTION 2: Verifying LayerZero Configuration"
echo "========================================================================"

log_info "Checking LayerZero configuration on all chains..."

# Store LayerZero info for each chain (using arrays instead of associative arrays for compatibility)
LZ_CHAINS=()
LZ_SETTLERS=()
LZ_ENDPOINTS=()
LZ_EIDS=()
LZ_SEND_ULNS=()
LZ_RECEIVE_ULNS=()
LZ_CHAIN_IDS=()
LZ_RPC_URLS=()

# Collect LayerZero configuration for each chain
LZ_INDEX=0
for chain in "${CHAINS[@]}"; do
    # Get LayerZero settler address
    settler=$(extract_value "$chain" "layerzero_settler_deployed" "deploy/config.toml")
    
    if [ -z "$settler" ]; then
        log_info "  No LayerZero settler deployed on $chain, skipping LayerZero checks..."
        continue
    fi
    
    LZ_CHAINS+=("$chain")
    LZ_SETTLERS+=("$settler")
    
    # Get other LayerZero config
    LZ_ENDPOINTS+=($(extract_value "$chain" "layerzero_endpoint" "deploy/config.toml"))
    LZ_EIDS+=($(extract_uint_value "$chain" "layerzero_eid" "deploy/config.toml"))
    LZ_SEND_ULNS+=($(extract_value "$chain" "layerzero_send_uln302" "deploy/config.toml"))
    LZ_RECEIVE_ULNS+=($(extract_value "$chain" "layerzero_receive_uln302" "deploy/config.toml"))
    
    chain_id=$(extract_uint_value "$chain" "chain_id" "deploy/config.toml")
    LZ_CHAIN_IDS+=("$chain_id")
    
    # Get RPC URL
    RPC_VAR="RPC_${chain_id}"
    LZ_RPC_URLS+=(${!RPC_VAR})
done

# Verify LayerZero configuration for each chain
for i in "${!LZ_CHAINS[@]}"; do
    chain=${LZ_CHAINS[$i]}
    log_info "$chain LayerZero configuration:"
    
    settler=${LZ_SETTLERS[$i]}
    endpoint=${LZ_ENDPOINTS[$i]}
    eid=${LZ_EIDS[$i]}
    rpc_url=${LZ_RPC_URLS[$i]}
    
    if [ -z "$rpc_url" ]; then
        log_warning "  RPC URL not available for $chain, skipping checks..."
        continue
    fi
    
    log_info "  Settler: $settler"
    log_info "  Expected Endpoint: $endpoint"
    log_info "  EID: $eid"
    
    # Check if endpoint is set on LayerZeroSettler
    CURRENT_ENDPOINT=$(cast call $settler "endpoint()(address)" --rpc-url $rpc_url 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
    
    if [ "$CURRENT_ENDPOINT" == "$endpoint" ]; then
        log_info "  ✓ Endpoint correctly set to $endpoint"
    else
        log_error "  ✗ Endpoint mismatch: Expected $endpoint, got $CURRENT_ENDPOINT"
    fi
    
    # Check L0SettlerSigner
    LZ_SIGNER=$(cast call $settler "l0SettlerSigner()(address)" --rpc-url $rpc_url 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
    log_info "  L0SettlerSigner: $LZ_SIGNER"
    echo ""
done

# Verify cross-chain pathway configuration
log_info "Cross-chain pathway verification:"

# Check pathways between all pairs of chains
for i in "${!LZ_CHAINS[@]}"; do
    for j in "${!LZ_CHAINS[@]}"; do
        if [ "$i" == "$j" ]; then
            continue
        fi
        
        source_chain=${LZ_CHAINS[$i]}
        dest_chain=${LZ_CHAINS[$j]}
        
        source_settler=${LZ_SETTLERS[$i]}
        source_endpoint=${LZ_ENDPOINTS[$i]}
        source_send_uln=${LZ_SEND_ULNS[$i]}
        source_rpc=${LZ_RPC_URLS[$i]}
        dest_eid=${LZ_EIDS[$j]}
        
        if [ -z "$source_rpc" ]; then
            continue
        fi
        
        log_info "  $source_chain -> $dest_chain pathway:"
        
        # Check executor configuration using endpoint.getConfig()
        # CONFIG_TYPE_EXECUTOR = 1
        EXECUTOR_CONFIG_BYTES=$(cast call $source_endpoint "getConfig(address,address,uint32,uint32)(bytes)" "$source_settler" "$source_send_uln" "$dest_eid" "1" --rpc-url $source_rpc 2>/dev/null || echo "0x")
        
        if [ "$EXECUTOR_CONFIG_BYTES" != "0x" ] && [ ! -z "$EXECUTOR_CONFIG_BYTES" ]; then
            # Try to decode executor address using cast
            DECODED=$(cast abi-decode "f()(uint32,address)" "$EXECUTOR_CONFIG_BYTES" 2>/dev/null || echo "")
            if [ ! -z "$DECODED" ]; then
                EXECUTOR_ADDR=$(echo "$DECODED" | tail -1)
                if [ "$(echo $EXECUTOR_ADDR | tr '[:upper:]' '[:lower:]')" == "$(echo $source_settler | tr '[:upper:]' '[:lower:]')" ]; then
                    log_info "    ✓ Executor correctly set to LayerZeroSettler"
                else
                    log_error "    ⚠ Executor not set to LayerZeroSettler (self-execution model)"
                fi
            else
                log_error "    ⚠ Could not parse executor configuration"
            fi
        else
            log_error "    ⚠ Executor configuration not set"
        fi
        
        # Check ULN configuration using endpoint.getConfig()
        # CONFIG_TYPE_ULN = 2
        ULN_CONFIG_BYTES=$(cast call $source_endpoint "getConfig(address,address,uint32,uint32)(bytes)" "$source_settler" "$source_send_uln" "$dest_eid" "2" --rpc-url $source_rpc 2>/dev/null || echo "0x")
        
        if [ "$ULN_CONFIG_BYTES" != "0x" ] && [ ! -z "$ULN_CONFIG_BYTES" ] && [ ${#ULN_CONFIG_BYTES} -gt 10 ]; then
            log_info "    ✓ ULN configuration is set"
        else
            log_error "    ⚠ ULN configuration not set"
        fi
    done
done
echo ""

# ========================================================================
# SECTION 3: Verify Signer Funding and Gas Wallet Configuration
# ========================================================================

echo "========================================================================"
log_info "SECTION 3: Verifying Signer Funding and Gas Wallet Configuration"
echo "========================================================================"

# Derive signer addresses from mnemonic (first 3 for verification)
log_info "Checking signer balances..."

# First signer addresses (derived from the mnemonic)
SIGNER_0="0x33097354Acf259e1fD19fB91159BAE6ccf912Fdb"
SIGNER_1="0x49e1f963ddb4122BD3ccC786eB8F9983dABa8658"
SIGNER_2="0x46C66f82B32f04bf04D05ED92e10b57188BF408A"

# Check balances on all chains
for chain in "${CHAINS[@]}"; do
    # Get chain ID and RPC URL
    CHAIN_ID=$(extract_uint_value "$chain" "chain_id" "deploy/config.toml")
    RPC_VAR="RPC_${CHAIN_ID}"
    RPC_URL=${!RPC_VAR}
    
    if [ -z "$RPC_URL" ]; then
        log_warning "  RPC URL not set for $chain, skipping signer balance checks..."
        continue
    fi
    
    # Get target balance from config
    TARGET_BALANCE=$(extract_uint_value "$chain" "target_balance" "deploy/config.toml")
    
    if [ -z "$TARGET_BALANCE" ]; then
        log_error "  Target balance not set for $chain"
        continue
    fi
    
    log_info "$chain (Chain ID: $CHAIN_ID) signer balances (target: $TARGET_BALANCE wei):"
    
    # Check each signer's balance
    for i in 0 1 2; do
        SIGNER_VAR="SIGNER_${i}"
        SIGNER_ADDR=${!SIGNER_VAR}
        
        BALANCE=$(cast balance $SIGNER_ADDR --rpc-url $RPC_URL 2>/dev/null || echo "0")
        
        if [ "$BALANCE" -ge "$TARGET_BALANCE" ] 2>/dev/null; then
            log_info "  Signer $i ($SIGNER_ADDR): $BALANCE wei ✓"
        else
            log_error "  Signer $i ($SIGNER_ADDR): $BALANCE wei (below target)"
        fi
    done
    echo ""
done

# Verify gas wallets and orchestrators in SimpleFunder
log_info "Checking SimpleFunder configuration..."

for chain in "${CHAINS[@]}"; do
    # Get SimpleFunder address
    SIMPLE_FUNDER=$(extract_value "$chain" "simple_funder_deployed" "deploy/config.toml")
    
    if [ -z "$SIMPLE_FUNDER" ]; then
        log_info "  No SimpleFunder deployed on $chain, skipping..."
        continue
    fi
    
    # Get chain ID and RPC URL
    CHAIN_ID=$(extract_uint_value "$chain" "chain_id" "deploy/config.toml")
    RPC_VAR="RPC_${CHAIN_ID}"
    RPC_URL=${!RPC_VAR}
    
    if [ -z "$RPC_URL" ]; then
        log_warning "  RPC URL not set for $chain, skipping SimpleFunder checks..."
        continue
    fi
    
    log_info "$chain SimpleFunder ($SIMPLE_FUNDER):"
    
    # Check if signers are gas wallets
    GAS_WALLET_OK=0
    for i in 0 1 2; do
        SIGNER_VAR="SIGNER_${i}"
        SIGNER_ADDR=${!SIGNER_VAR}
        IS_GAS_WALLET=$(cast call $SIMPLE_FUNDER "gasWallets(address)(bool)" $SIGNER_ADDR --rpc-url $RPC_URL 2>/dev/null || echo "false")
        
        if [ "$IS_GAS_WALLET" == "true" ]; then
            log_info "  ✓ Signer $i is registered as gas wallet"
            GAS_WALLET_OK=$((GAS_WALLET_OK + 1))
        else
            log_error "  ✗ Signer $i is NOT registered as gas wallet"
        fi
    done
    
    # Check orchestrator configuration
    # Extract orchestrator from supported_orchestrators array
    ORCHESTRATOR_CONFIG=$(extract_value "$chain" "supported_orchestrators" "deploy/config.toml" | sed 's/.*\["\([^"]*\)".*/\1/')
    
    if [ ! -z "$ORCHESTRATOR_CONFIG" ]; then
        IS_SUPPORTED=$(cast call $SIMPLE_FUNDER "orchestrators(address)(bool)" $ORCHESTRATOR_CONFIG --rpc-url $RPC_URL 2>/dev/null || echo "false")
        
        if [ "$IS_SUPPORTED" == "true" ]; then
            log_info "  ✓ Orchestrator $ORCHESTRATOR_CONFIG is supported"
        else
            log_error "  ✗ Orchestrator $ORCHESTRATOR_CONFIG is NOT supported"
        fi
    fi
    
    # Check funder and owner
    FUNDER_ADDR=$(cast call $SIMPLE_FUNDER "funder()(address)" --rpc-url $RPC_URL 2>/dev/null || echo "0x0")
    OWNER_ADDR=$(cast call $SIMPLE_FUNDER "owner()(address)" --rpc-url $RPC_URL 2>/dev/null || echo "0x0")
    log_info "  Funder: $FUNDER_ADDR"
    log_info "  Owner: $OWNER_ADDR"
    echo ""
done

# ========================================================================
# FINAL SUMMARY
# ========================================================================

echo "========================================================================"
log_info "VERIFICATION COMPLETE"
echo "========================================================================"

log_info "Summary:"
log_info "  • Contract Deployments: Checked"
log_info "  • LayerZero Configuration: Checked"
log_info "  • Signer Funding: Checked"
log_info "  • Gas Wallet Configuration: Checked"
echo ""
log_info "Run 'bash deploy/test_deployment.sh' for full deployment and configuration"
log_info "This script only verifies the current state without making changes"