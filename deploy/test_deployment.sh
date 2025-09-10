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

# Step 3: Deploy contracts to Base Sepolia and Optimism Sepolia
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

# Step 4: Configure LayerZero for cross-chain communication
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

# Step 5: Fund signers and set them as gas wallets
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

# Step 6: Summary
echo "========================================================================"
log_info "DEPLOYMENT TEST COMPLETED SUCCESSFULLY!"
echo "========================================================================"
log_info "✅ Contracts deployed to Base Sepolia and Optimism Sepolia"
log_info "✅ LayerZero configured for cross-chain communication"
log_info "✅ Signers funded and set as gas wallets"
echo ""

# Optional: Display deployed contract addresses
log_info "Checking for deployment registry files..."
if ls deploy/registry/deployment_84532_*.json 1> /dev/null 2>&1; then
    log_info "Base Sepolia deployment registry:"
    ls -la deploy/registry/deployment_84532_*.json
fi

if ls deploy/registry/deployment_11155420_*.json 1> /dev/null 2>&1; then
    log_info "Optimism Sepolia deployment registry:"
    ls -la deploy/registry/deployment_11155420_*.json
fi

echo ""
log_info "All deployment steps completed successfully!"