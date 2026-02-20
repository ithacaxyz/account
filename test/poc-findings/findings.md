# 01 | High

## `withdrawTokens` has no access control — anyone can drain the Orchestrator

`Orchestrator.withdrawTokens` (L152-156) is fully public with zero access control. Anyone can call it and sweep every token sitting on the contract.

### Where

`src/Orchestrator.sol` L152-156

```solidity
function withdrawTokens(address token, address recipient, uint256 amount) public virtual {
    TokenTransferLib.safeTransfer(token, recipient, amount);
}
```

### Why it matters

The Orchestrator accumulates ERC20 payment tokens during normal operation. Relayers set `paymentRecipient = address(orchestrator)` to collect gas compensation — this pattern is used all over the test suite (`Orchestrator.t.sol` L119, L603, L692, L1048). The EOA pays via `IthacaAccount.pay()` (L657), and tokens pile up on the contract.

On top of that, the Orchestrator accepts native ETH through `receive()` (L828) and `payable execute()` (L198, L210). So there are real, production paths for funds to land on this contract.

Once they're there, anyone can take them.

### The interface literally says "owner"

`IOrchestrator.sol` (L36):

```solidity
/// @dev Allows the orchestrator owner to withdraw tokens.
function withdrawTokens(address token, address recipient, uint256 amount) external;
```

The implementation allows **anyone**. `SimpleFunder.sol` (L69) has the exact same function signature with `onlyOwner`. The access control was clearly intended but never added.

### Live deployments

Orchestrator is deployed at `0x36A7Cd5b1F475122A2b52580FC8e170A2Cd312eF` across all chains (Base, Ethereum, Optimism, Arbitrum, BNB, Polygon, Celo, Berachain, Gnosis) via CREATE2. Callable by anyone on every deployment.

### POC

[`test/poc/TestFindings.t.sol::test_orchestratorPaymentsSweep`](../test/poc/TestFindings.t.sol)

Two legitimate intents execute with `paymentRecipient = address(oc)`. After both succeed, 0.6 ether of ERC20 payment tokens sit on the Orchestrator. An unprivileged attacker calls `withdrawTokens` and drains everything.

```bash
forge test --match-test test_orchestratorPaymentsSweep -vvv
```

### Fix

Add `onlyOwner` to `withdrawTokens`, same as `SimpleFunder` already does.

---

# 02 | High

## `initConfig` missing `_checkKeyHash` — session key can hijack a multisig super admin

`MultiSigSigner.initConfig` (L75-89) has no authorization check. Every other config mutation function calls `_checkKeyHash`, but `initConfig` doesn't. A session key with `initConfig` permission can front-run the legitimate owner and permanently take over any multisig key on the account.

### Where

`src/MultiSigSigner.sol` L75-89

```solidity
function initConfig(bytes32 keyHash, uint256 threshold, bytes32[] memory ownerKeyHashes) public {
    if (threshold == 0 || threshold > ownerKeyHashes.length) revert InvalidThreshold();
    Config storage config = _configs[msg.sender][keyHash];
    if (config.threshold > 0) { revert ConfigAlreadySet(); }
    _configs[msg.sender][keyHash] = Config({threshold: threshold, ownerKeyHashes: ownerKeyHashes});
}
```

Compare with the other mutators — they all gate on `_checkKeyHash`:

- `addOwner` (L93): `_checkKeyHash(keyHash)`
- `removeOwner` (L103): `_checkKeyHash(keyHash)`
- `setThreshold` (L129): `_checkKeyHash(keyHash)`

`_checkKeyHash` (L67-70) reads `getContextKeyHash()` from transient storage and reverts if it doesn't match the target `keyHash`. This is the whole point of the guard — only the key itself (or the EOA) should be able to mutate its own config. `initConfig` skips it entirely.

### Attack path

1. Account has an External key K (`isSuperAdmin = true`) pointing to `MultiSigSigner`. Config for K is not yet initialized.
2. A session key S has `setCanExecute(S, multiSigSigner, initConfig.selector, true)`.
3. Session key S sends an intent through the Orchestrator:
   ```
   initConfig(K_hash, 1, [attackerOwnerKeyHash])
   ```
4. `getContextKeyHash()` returns `S.keyHash` during execution, but `initConfig` never checks it. Config is written.
5. `ConfigAlreadySet` blocks any re-initialization — the hijack is permanent.
6. Attacker signs any digest with their owner key. `isValidSignatureWithKeyHash` returns `0x8afc93b4`. They now control a super admin key on the account.

### Why it's permanent

`initConfig` reverts with `ConfigAlreadySet` if `threshold > 0` (L83-85). Threshold can never go back to 0. The other mutation functions (`addOwner`, `removeOwner`, `setThreshold`) all require `_checkKeyHash` — which means the attacker's owner keys would need to authorize any fix. The legitimate owner is locked out.

### POC

[`test/poc/TestFindings.t.sol::test_initConfigNoAuthCheck`](../test/poc/TestFindings.t.sol)

The test sets up:
- External key K (`isSuperAdmin = true`) using MultiSigSigner
- Session key S (non-super-admin) with `initConfig` permission
- Attacker owner key

Session key S hijacks the config for K through the Orchestrator. The test verifies:
- Config is set to attacker's owners with threshold=1
- Re-initialization reverts with `ConfigAlreadySet`
- Attacker produces a valid multisig signature (`0x8afc93b4`) for an arbitrary digest

```bash
forge test --match-test test_initConfigNoAuthCheck -vvv
```

### Fix

Add authorization to `initConfig`. Note: naively adding `_checkKeyHash(keyHash)` creates a chicken-and-egg — the External key K can't validate before its config exists. The fix should restrict initialization to the EOA key (`contextKeyHash == bytes32(0)`) or super-admin keys only.

---
