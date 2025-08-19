```mermaid
sequenceDiagram
participant Relayer
participant Orchestrator
participant Account
participant Payer

    Relayer->>Orchestrator: submit(Intent)
    activate Orchestrator

    alt Account needs delegation
        note over Orchestrator,Account: 0. EIP-7702 Delegation (if not already delegated)
        Orchestrator->>Account: Delegate to Porto Account Proxy (via 7702)
        activate Account
        Account-->>Orchestrator: Delegation Complete
        deactivate Account
    end

    alt Intent includes encodedPreCalls
        note over Orchestrator,Account: 1. Handle PreCalls
        loop For each PreCall in encodedPreCalls
            Orchestrator->>Account: Process PreCall (Validate, Increment Nonce, Execute)
            activate Account
            Account-->>Orchestrator: PreCall Processed
            deactivate Account
        end
    end

    note over Orchestrator,Account: 2. Main Intent Validation
    Orchestrator->>Account: Validate Signature (unwrapAndValidateSignature)
    activate Account
    Account-->>Orchestrator: Signature OK
    deactivate Account

    Orchestrator->>Account: Check & Increment Nonce (checkAndIncrementNonce)
    activate Account
    Account-->>Orchestrator: Nonce OK & Incremented
    deactivate Account

    note over Orchestrator,Payer: 3. Pre Payment
    alt Intent includes prePaymentAmount > 0
        Orchestrator->>Payer: Process Pre-Payment \n(using Intent.paymentToken, Intent.prePaymentAmount)
        activate Payer
        Payer-->>Orchestrator: Pre-Payment Processed
        deactivate Payer
    end

    note over Orchestrator,Account: 4. Execution
    Orchestrator->>Account: execute(mode,executionData)
    activate Account
    Account-->>Orchestrator: Execution Successful
    deactivate Account

    Orchestrator-->>Relayer: Execution Succeeded
    deactivate Orchestrator
```