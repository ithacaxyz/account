## Deployment

### Build 
```bash
foundryup
forge build
export RPC_URL="https://..."
export PRIVATE_KEY="0x..."
```

### Deploy contracts

If you want to output the `deployment.json` with the deployed addresses, set 
```bash
export SAVE_DEPLOY=true
```

To deploy all contracts

```bash
forge script DeployAllScript \
  --rpc-url $RPC_URL \
  --broadcast
```

or to rollout account upgrades, just deploy new delegation contracts

```bash
forge script DeployDelegateScript \
  --rpc-url $RPC_URL \
  --broadcast
```

### Docs
1. Rollout new version with `npx changeset` 
2. Update `CHANGELOG.md`
3. Update deployed contracts `deployments.json`
4. Tag new version on github