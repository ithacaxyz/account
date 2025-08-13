# porto-account

## 0.5.0

### Minor Changes

- Remove pre/post payment mechanism from contracts
  - Replaced `prePaymentAmount`, `prePaymentMaxAmount`, `totalPaymentAmount`, and `totalPaymentMaxAmount` with single `paymentAmount` and `paymentMaxAmount` fields
  - Post payments can now be done at execution data level by injecting a transfer call at the end of the batch, by the relay.
  - Simplified the Orchestrator's payment flow to a single payment step after execution
  - Updated Simulator to remove `isPrePayment` parameter from all simulation functions
  - This change reduces complexity and allows for more flexible payment handling

## 0.4.0

### Minor Changes

- Adds interop features to the account, using native merkle sigs.
- Adds `encodedFundTransfers` field to the `Intent` 712 struct. Transfers should be placed in strictly increasing order of token addresses.
- Add `multichain` flag which tells the execute function to use merkle sig verification instead of vanilla verification.
- Add `isMultiChain` bool to the execute function.
- Add `IFunder` interface, along with `funder` and `funderSignature` address in the non EIP 712 part of the intent.
## 0.3.2

### Patch Changes

- Rename PortoAccount to IthacaAccount

## 0.3.1

### Patch Changes

- Remove Account Registry, we don't need it with ephemeral private key deployments.

## 0.3.0

### Minor Changes

- Removes all PREP related fields from account storage.
- Removes`initializePREP` from contracts, porto will now use ephemeral private keys instead.
- `initCalls` now need to be sent as preCalls signed by the EOA key.
- Removes the ability to force execution of initialization calls, before executing anything else.
- Breaks storage structure for account.

## 0.2.0

### Minor Changes

- Rename contracts, to avoid confusion with 4337 concepts.
- `Delegation` -> `PortoAccount` (`account` is also used internally in some places)
- `EntryPoint` -> `Orchestrator`
- `UserOp` -> `Intent`
- `PreOp` -> struct to `SignedCall`, implementations to `PreCall`
- In tests `ep` has been substituted with `oc`.
- `PortoAccount` is used for all external facing interactions.
  Internally and in some places in tests we prefer to use the shorter `account`
- By following the replacement rules above, it should be easy for relay to upgrade.

## 0.1.4

### Patch Changes

- Removes support for delegate call executions in the account.

## 0.1.3

### Patch Changes

- Adds support for `External` keytype. Which allows external contracts that implement the `ISigner`
  to verify signatures.
- Adds a `MultiSigSigner` which adds multi-sig support to the account, using `External` keytype.
- Adds a stack of `context key hashes` to the account. External observers can check which key signed
  the account's current execution, by calling the `getContextKeyHash` function on the msg.sender.
  This has a variety of usecases like validating key operations, setting data in account registry etc.
- Only adds features. Should not have breaking changes for the relay.

## 0.1.2

### Patch Changes

- Add a `pauseAuthority` to Orchestrator that can pause all activities for all user accounts for upto 4 weeks.
- `pauseAuthority` can unpause the accounts whenever they want.
- Anyone can unpause the accounts after 4 weeks, to prevent censorship.
- Accounts cannot be paused again until 5 weeks after the last pause.
  This gives the users 1 week, to migrate their funds if they are being censored.
- Signature validation fails when an account is paused. So `pay`, `execute`, `isValidSignature` will all fail.

## 0.1.1

### Patch Changes

- All nonce related functions removed from EP.
- Orchestrator is not ownable anymore, anyone can call the `withdrawTokens` function.
- All fill related functions removed from EP.
- EP is now completely stateless, also does not have a constructor.
- PreCall with `nonce = type(uint256).max` is not replayable anymore.
- `OpDataTooShort` error, udpated to `OpDataError`, to enforce tighter validation of opdata.
- `checkAndIncrementNonce` function added to account. Can only be called by EP.
- 6b3294a: Optimize `_isSuperAdmin`

## 0.1.0

### Minor Changes

**Note: The pre/post payment mechanism described below was removed in v0.5.0. This is kept for historical reference only.**

- b38a5af: Refactor PreCalls to be a minimal call struct with extra nonce and EOA fields
- - `compensate` function is replaced with the `pay` function in the account.
  - `pay` can be called twice during a intent. Once before the execution, which we call prePayment, and once after the execution called postPayment.

  - `paymentPerGas` and `paymentMaxAmount` fields in the intent have been replaced with `prePaymentMaxAmount` and `totalPaymentMaxAmount` in the EIP-712.
    `paymentAmount` field is also removed, and replaced with `prePaymentAmount` and `totalPaymentAmount`

  - If `prePaymentAmount == 0` then the `pay` call before the execution is skipped. Similarly if `prePaymentAmount == totalPaymentAmount` then the post execution call is skipped.
    (as `postPayment = totalPayment-prePaymnent`)

  - If the `prePayment` fails, then the nonce is not incremented. If the `postPayment` fails, then the whole execution batch is reverted, but the nonce _is_ still incremented.
    An edge case: If prePayment is supposed to fail, but the prePayment amount is set to 0. Then `pay` will never be called before the execution, so we will treat it like the prePayment is successful, and the nonce will be incremented.

  - Payment recipient field in the intent is not substituted with address(Orchestrator) anymore, if the field is set to address(0).

  - A new `Simulator` contract is deployed, which can be customized to the needs of the relay.
    The only change required by the relay is to start calling `simulator.simulateV1Logs` , instead of calling the Orchestrator directly.
    More information about how to use the new simulate functions have been provided in the natspec of the Simulator contract.
    Also refer to the `_estimateGas` function in `Base.t.sol` to see an example of how to estimate gas for a intent.
    Note: the hardcoded offset values might be different for real transactions.

  - Added `combinedGasVerification` offset in `simulateV1Logs` that allows the relay to account for gas variation in P256 sig verification.
    Empirically, this field can be set to `0` for `secp256k1` sigs
    And `10_000` for `P256` sigs. Relay can adjust this value, if simulations start failing for certain keytypes. 10k works with P256 sigs for 50k fuzz runs.

  - Add back the INSUFFICIENT_GAS check, which prevents the relay from setting up the `execute` call on the
    account, in such a way causing it to intentionally fail.
    For the relay, gExecute now has to be set atleast as `gExecute > (gCombined + 100_000) * 64/63)`

### Patch Changes

- 2cd38ba: Remove `msg.sender == ORCHESTRATOR` check in `initializePREP`.
- cd643bc: Add account implementation check to Orchestrator
- 5190332: Block P256 superadmins
- 7a18e2d: Add compensate spend limits. Note that the `compensate` function is refactored to have a `keyHash` parameter.
- 37995e7: Benchmarks
- f23ff36: Optimize spend permissions storage
- 23297c5: Make simulateExecute fuzz tests touch paymentAmount=0
- da4f1ff: Make non-superadmins unable to spend without a spend limit
- 6dcfeb7: Fix simulateExecute missing revert if PaymentError"
- b428a31: Separate AccountRegistry from Orchestrator

## 0.0.2

### Patch Changes

- d592d00: Add new UnauthorizedCall error to GuardedExecutor
- 91a2db1: Bump solady to use latest P256
- 550e572: Initialize changeset.

  Add script to replace EIP-712 versions in Solidity upon `npx changeset version`.
