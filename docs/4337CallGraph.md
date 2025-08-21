sequenceDiagram
      participant User as User
      participant Bundler as Bundler
      participant EntryPoint as EntryPoint
      participant Paymaster as Paymaster
      participant Account as ERC4337 Account

      User->>Bundler: Submit signed UserOperation + paymasterAndData
      Bundler->>EntryPoint: handleOps([userOp])

      Note over EntryPoint: Validation Phase
      EntryPoint->>Account: validateUserOp(userOp, userOpHash, missingAccountFunds)
      Account-->>EntryPoint: validationData

      Note over EntryPoint: Paymaster validation & deposit check
      EntryPoint->>Paymaster: validatePaymasterUserOp(userOp, userOpHash, maxCost)
      Note over Paymaster: Validate user agreed to pay in USDC
      Paymaster-->>EntryPoint: (context, validationData)


      Note over EntryPoint: Execution Phase
      EntryPoint->>Account: execute(userOp.callData)

      Note over EntryPoint: Payment Phase - ETH movement
      EntryPoint-->>Bundler: ETH transfer (actualGasCost)

      EntryPoint->>Paymaster: postOp(mode, context, actualGasCost)
      Note over Paymaster: Calculate USDC amount needed
      Account-->>Paymaster: USDC transfer (calculated amount)

      EntryPoint-->>Bundler: Execution result
      Bundler-->>User: UserOp result