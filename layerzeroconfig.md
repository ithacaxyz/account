# LayerZero Configuration Guide

This guide explains how to configure and manage LayerZero settings for cross-chain messaging, particularly for setting custom executors.

## Overview

LayerZero uses a configuration system that allows you to customize various aspects of cross-chain messaging, including:
- **Executor Configuration**: Specifies which contract executes messages on the destination chain
- **ULN Configuration**: Defines security parameters like required DVNs (Decentralized Verifier Networks)

## Configuration Types

| Config Type | Value | Description |
|------------|-------|-------------|
| Executor | 1 | Controls message execution settings |
| ULN | 2 | Controls verification and security settings |

## Executor Configuration Structure

```solidity
struct ExecutorConfig {
    uint32 maxMessageSize;  // Maximum size of messages in bytes
    address executor;       // Address of the executor contract
}
```

## Checking Current Configuration

To check the current configuration for a specific route:

```bash
cast call $ENDPOINT_ADDRESS \
  "getConfig(address,address,uint32,uint32)(bytes)" \
  $OAPP_ADDRESS \
  $SEND_LIBRARY_ADDRESS \
  $DESTINATION_EID \
  1 \
  --rpc-url $RPC_URL
```

### Parameters:
- `$ENDPOINT_ADDRESS`: LayerZero Endpoint V2 contract
- `$OAPP_ADDRESS`: Your OApp contract (e.g., LayerZeroSettler)
- `$SEND_LIBRARY_ADDRESS`: The send library for your source chain (e.g., SendUln302)
- `$DESTINATION_EID`: The endpoint ID of the destination chain
- `1`: Config type for executor configuration

### Decoding Configuration Results

To decode the returned bytes into readable format:

```bash
# Decode executor config (returns maxMessageSize and executor address)
cast abi-decode "decode(bytes)(uint32,address)" <RETURNED_BYTES>
```

## Setting Custom Configuration

To set a custom executor for a specific route:

```bash
cast send $ENDPOINT_ADDRESS \
  "setConfig(address,address,(uint32,uint32,bytes)[])" \
  $OAPP_ADDRESS \
  $SEND_LIBRARY_ADDRESS \
  "[($DESTINATION_EID,1,$ENCODED_EXECUTOR_CONFIG)]" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Encoding Executor Configuration

The `$ENCODED_EXECUTOR_CONFIG` should be the ABI-encoded ExecutorConfig struct. For example, to encode a config with maxMessageSize of 10000 and a specific executor address:

```bash
# Encode ExecutorConfig(maxMessageSize: 10000, executor: 0xYourExecutorAddress)
ENCODED_CONFIG=$(cast abi-encode "f((uint32,address))" "(10000,0xYourExecutorAddress)")
```

### Complete Example

```bash
# Set environment variables
export ENDPOINT_ADDRESS="0x..."      # LayerZero Endpoint V2
export OAPP_ADDRESS="0x..."          # Your LayerZeroSettler address
export SEND_LIBRARY_ADDRESS="0x..."  # Send library for your chain (Mostly ULN302)
export DESTINATION_EID="30101"       # e.g., 30101 for Arbitrum
export EXECUTOR_ADDRESS="0x..."      # Your custom executor
export RPC_URL="https://..."         # Your RPC endpoint

# Encode the executor configuration
ENCODED_CONFIG=$(cast abi-encode "f((uint32,address))" "(10000,$EXECUTOR_ADDRESS)")

# Set the configuration
cast send $ENDPOINT_ADDRESS \
  "setConfig(address,address,(uint32,uint32,bytes)[])" \
  $OAPP_ADDRESS \
  $SEND_LIBRARY_ADDRESS \
  "[($DESTINATION_EID,1,$ENCODED_CONFIG)]" \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```


## Finding Contract Addresses

To find the correct addresses for your chain:
1. **Endpoint V2**: Check LayerZero's deployment addresses
2. **Send Library**: Usually `SendUln302` for most chains
3. **OApp Address**: Your deployed contract address

## Troubleshooting

- **Empty result from getConfig**: The configuration might not be set yet
- **Transaction reverts on setConfig**: Ensure you have the correct permissions (owner/admin)
- **Decode errors**: Make sure you're using the correct format for decoding the configuration bytes