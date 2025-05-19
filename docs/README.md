# Overview

There are two main contracts:

- **Account** – Can be used by the EOA directly or via a relayer with a signed payload to `execute`.
- **Orchestrator** – Used when compensating the relayer for gas paid to call `execute`.

## Account

Calling `Account` directly is unreliable for relayers.

Even if an EOA has a valid account during transaction preparation, the account can be swapped to a invalid account right before the transaction is mined, preventing compensation.

## Orchestrator

`Orchestrator` ensures atomic execution of compensation, Intent validation, and execution. It also enables Intent batching across EOAs, optimizing gas via address and storage access warming.

### Execution Flow (Single Intent)

1. Check remaining gas using the 63/64 rule (reverts on insufficient gas).
2. Invalidate the Intent nonce (non-reverting).
3. If step 2 succeeds, make a gas-limited compensation call (non-reverting).
4. If step 3 succeeds, make a gas-limited call for Intent validation and execution (non-reverting).
5. Refund excess payment (will not revert).

Non-reverting steps return an error code instead of reverting to prevent griefing. A revert would still debit gas from the relayer while undoing any compensation.

Gas-limited calls use a self-call with a gas stipend to perform calls to untrusted external contracts. On revert, the error selector is extracted from returndata and returned.

### Execution Flow (Multi Intent)

This is just a loop across an array of encoded Intents. Only reverts if there is insufficient gas provided to the transaction.

The total amount of required gas can be reliably determined during transaction preparation via the `combinedGas` parameter in each Intent.

## Upgradeability

There are 2 ways which an EOA can upgrade their `Account`:

- Execution layer: Sign a new EIP7702 transaction with the EOA key to redelegate.
  Supports direct account to the `Account` itself, or via an `EIP7702Proxy`.

- Application layer: Delegate to an `EIP7702Proxy` (a novel proxy pattern tailored for EIP7702).
  Upon fresh account, the initial implementation will be the latest official implementation on the proxy.
  A call to `execute` on the EOA is required for this initial implementation to be written to storage.
  Subsequent upgrades can be signed by an authorized passkey or the EOA key.

The `Orchestrator` is currently behind a minimal ERC1967 transparent proxy. This proxy can be upgraded if the expected `Account` ABI does not change, and this requires no action on the EOAs.
