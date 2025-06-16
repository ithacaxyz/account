# Deployment Guide

This guide explains how to deploy Ithaca Account contracts to a new chain.

## Prerequisites

1. Ensure Safe Singleton Factory is deployed at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`
   - Check deployment status at https://github.com/safe-global/safe-singleton-factory
   - If not deployed, request deployment for your chain

2. Have environment variables ready:
   - `PAUSE_AUTHORITY`: Address that can pause/unpause the orchestrator
   - `PRIVATE_KEY`: Deployer private key with sufficient funds

## Step 1: Deploy the Factory

Deploy the IthacaFactory contract using Safe Singleton Factory:

```bash
forge script script/DeployFactory.s.sol \
  --rpc-url <YOUR_RPC_URL> \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

This will output the factory address. Save it for the next step.

## Step 2: Deploy All Contracts

Set the factory address and deploy all contracts:

```bash
export ITHACA_FACTORY=<FACTORY_ADDRESS_FROM_STEP_1>

forge script script/DeployAllViaFactory.s.sol \
  --rpc-url <YOUR_RPC_URL> \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

This will:
1. Deploy Orchestrator
2. Deploy IthacaAccount implementation
3. Deploy Account proxy
4. Deploy Simulator

All addresses are deterministic and will be the same on every chain.

## Deployment Order

If deploying manually instead of using scripts:

1. **Factory** - Deploy once per chain via Safe Singleton Factory
2. **Orchestrator** - Deploy first, needs pause authority
3. **IthacaAccount** - Deploy second, needs orchestrator address
4. **Account Proxy** - Deploy third, needs implementation address
5. **Simulator** - Can be deployed anytime

## Salt Values

Default salt values used:
- Factory: `keccak256("ithaca.factory.v1")`
- Contracts: `keccak256("ithaca.account.v1")`

Change these for different deployment sets or versions.

## Verification

Before deployment, you can predict addresses:

```solidity
// In your script or console
factory.predictAddresses(pauseAuthority, salt);
```

After deployment, verify the addresses match predictions.

## Troubleshooting

- **"Factory not deployed"**: Ensure Safe Singleton Factory is deployed on your chain
- **"Orchestrator not deployed"**: Deploy contracts in the correct order
- **Different addresses**: Ensure you're using the same salt and pause authority