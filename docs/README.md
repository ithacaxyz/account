# Overview

There are two main contracts:

- Delegation
- EntryPoint

The Delegation can be used by the EOA itself, or by a relayer via a signed payload to the `execute` function (if they are willing to fully pay for the gas themselves).

But we need to compensate the relayer for paying the gas to call `execute` with a signed function, we will need to use the EntryPoint. 

Directly calling the Delegation is insufficient. In the small lag between querying the EOA's delegation and mining the transaction, the EOA can swap out their delegation to one that does not compensate the relayer.

The EntryPoint enables compensation, UserOp validation and execution to be done in a single atomic transaction.

The EntryPoint enables batching of UserOps, even across different EOAs. This can save gas via address and storage access warming. 

