sequenceDiagram
      participant User as User
      participant Relayer as Relayer
      participant Orch as Orchestrator
      participant Account as IthacaAccount

      User->>Relayer: Submit signed intent
      Relayer->>Orch: execute(encodedIntent)

      Note over Orch: Verify signature
      Orch->>Account: unwrapAndValidateSignature(digest, signature)
      Account-->>Orch: (isValid, keyHash)

      Note over Orch: Increment nonce
      Orch->>Account: checkAndIncrementNonce(nonce)

      Note over Orch: Process payment
      Orch->>Account: pay(paymentAmount, keyHash, digest, intent)
      Account-->>Relayer: ERC20 transfer (paymentAmount)

      Note over Orch: Execute intent
      Orch->>Account: execute(executionData)

      Orch-->>Relayer: Return success/error code
      Relayer-->>User: Execution result