## Solidity Contribution Guidelines

### 1. General Principles

- **Think first, code second**: Minimize the number of lines changed and consider ripple effects across the codebase.
- **Prefer simplicity**: Fewer moving parts ➜ fewer bugs and lower audit overhead.

### 2. Assembly Usage

| Rule | Rationale |
|------|-----------|
| Use assembly only when essential. | Keeps code readable and auditable. |
| Assembly is mandatory for low-level external calls. | Gives full control over call parameters & return data, and saves gas. |
| Precede every assembly block with: • A brief justification (1-2 lines). • Equivalent Solidity pseudocode. | Documents intent for reviewers. |
| Mark assembly blocks memory-safe when the Solidity docs' criteria are met. | Enables compiler optimizations. |

### 3. Gas Optimization

- Keep a dedicated **Gas Optimization** section in the PR description; justify any measurable gas deltas.
- Prefer `calldata` over `memory` for function arguments wherever possible, as `calldata` is cheaper. Note that `calldata` is read-only.
- Limit storage (`sstore`, `sload`) operations; cache in memory wherever possible.
- Use forge snapshot, forge test --match-test "benchmark", and npm scripts:
  ```bash
  npm run snapshot:main   # captures gas baseline from main
  npm run diff:main       # compares your branch vs. main
  ```
- Large regressions must be explained.

### 4. Handling "Stack Too Deep"

- **Struct hack (tests only)**: Bundle local variables into a temporary struct declared above the test.
- **Scoped blocks**: Wrap code in `{ ... }` to drop unused vars from the stack.
- **Internal helper functions**: Encapsulate logic to shorten call frames.
- **Refactor / delete unnecessary variables before other tricks**.

### 5. Security Checklist

- Review every change with an adversarial mindset.
- Favor the simplest design that meets requirements.
- After coding, ask: "What new attack surface did I introduce?"
- Reject any change that raises security risk without strong justification.

### 6. Verification Workflow

```bash
forge build                    # compile
forge test                     # full test suite
forge snapshot                 # gas snapshot (local)
forge test --match-test bench  # run benchmarks
npm run snapshot:main          # baseline gas (main)
npm run diff:main              # gas diff vs. main
```

### 7. Continuous Learning

- Consult official Solidity docs and relevant project references when uncertain.
- Borrow battle-tested patterns from audited codebases.

Apply these rules rigorously before opening a PR.


### Error Handling Style

Always use custom errors with the revert pattern instead of require statements:

```solidity
// ❌ Don't use require with string messages
require(amount > 0, "Amount must be positive");
require(to != address(0), "Cannot transfer to zero address");

// ✅ Do use custom errors with if/revert pattern
error AmountMustBePositive();
error CannotTransferToZeroAddress();

if (amount == 0) revert AmountMustBePositive();
if (to == address(0)) revert CannotTransferToZeroAddress();
```

**Benefits of custom errors**:
- More gas efficient than require strings
- Better error identification in tests and debugging
- Cleaner, more professional code
- Consistent with modern Solidity best practices

This applies to all Solidity code including contracts, libraries, and scripts.


## Testing Guidelines

### Core Testing Principles

**Every feature or change MUST have comprehensive tests before creating a PR**. This is non-negotiable for maintaining code quality and preventing regressions.

### 1. When to Write Tests

- **New Features**: Write tests that demonstrate the complete flow and all edge cases
- **Bug Fixes**: Add tests that reproduce the bug and verify the fix
- **Refactoring**: Ensure existing tests still pass; add new ones if behavior changes
- **Gas Optimizations**: Include benchmark tests showing before/after comparisons

### 2. Types of Required Tests

#### Unit Tests
- Write clear unit tests that demonstrate the general flow of your feature/change
- Test both happy paths and failure cases
- Include edge cases and boundary conditions
- Test revert conditions with specific error messages

#### Fuzz Tests
- **Fuzz tests are highly encouraged** for all new functionality
- Use Foundry's built-in fuzzing capabilities
- Apply random arguments to thoroughly test your implementation
- Use Solady's random library for composable randomness when needed

Example fuzz test pattern:
```solidity
function testFuzz_myFeature(uint256 amount, address user) public {
    // Bound inputs to reasonable ranges
    amount = bound(amount, 1, type(uint128).max);
    vm.assume(user != address(0));
    
    // Test your feature with random inputs
    myContract.myFeature(amount, user);
    
    // Assert expected outcomes
    assertEq(myContract.balanceOf(user), amount);
}
```

### 3. Testing Best Practices

- **Don't write redundant tests**: If something is already sufficiently tested, don't duplicate
- **Focus on what changed**: Ensure tests encapsulate your specific changes
- **Test downstream consequences**: Consider ripple effects of your changes
- **Update broken tests**: If your change breaks existing tests, update them thoughtfully
- **Use descriptive test names**: `test_FeatureName_SpecificScenario_ExpectedOutcome()`

### 4. Testing Checklist Before PR

Before opening any PR, ensure:
- [ ] All new functions have unit tests
- [ ] Critical paths have fuzz tests with random inputs
- [ ] Edge cases and revert scenarios are tested
- [ ] Gas benchmarks are included for optimizations
- [ ] All tests pass: `forge test`
- [ ] No test coverage regression: `forge coverage`

### 5. Using Test Utilities

The project includes helpful testing utilities:
- Solady's test utils for advanced testing patterns
- Forge-std's test helpers and cheat codes
- Project-specific mocks in `test/utils/mocks/`

Remember: **Well-tested code is trusted code**. Take the time to write thorough tests - they're an investment in the project's reliability and your peace of mind.

## Project-Specific Tools and Configuration

### Ithaca Account Repository Details

This is an EIP-7702 powered account contract repository for the Ithaca Porto system, focusing on secure, user-friendly crypto accounts with features like:
- WebAuthn/PassKey authentication
- Call batching and gas sponsorship
- Access control and session keys
- Multi-factor authentication (planned)
- Chain abstraction (planned)

### Foundry Configuration
You can always refer to the `foundry.toml` file to understand the environment the tests are running in.

### Available NPM Scripts

```bash
# Gas snapshot commands
npm run snapshot:main  # Capture gas baseline from main branch
npm run diff:main      # Compare current branch gas vs main
```

### Project Structure

- `src/`: Smart contract source files
  - Core contracts: `IthacaAccount.sol`, `Orchestrator.sol`, `GuardedExecutor.sol`
  - Supporting contracts: `MultiSigSigner.sol`, `PauseAuthority.sol`, `SimpleFunder.sol`, `Simulator.sol`
  - `interfaces/`: Contract interfaces
  - `libraries/`: Utility libraries (`LibNonce.sol`, `LibTStack.sol`, `TokenTransferLib.sol`)
- `test/`: Test files including benchmarks (`Benchmark.t.sol`)
- `script/`: Deployment scripts (`DeployAll.s.sol`)
- `lib/`: Dependencies (forge-std, solady, murky, openzeppelin)

### Testing and Benchmarks

- Run all tests: `forge test`
- Run specific test: `forge test --match-test testName`
- Run benchmarks: `forge test --match-contract Benchmark`
- Gas snapshots: Use npm scripts above
- Coverage: `forge coverage`

### Code Formatting

Use `forge fmt` to format Solidity code according to project standards.

## Common commands

Working with projects involves using the appropriate build tools and package managers for each language and framework.

### Before Committing

Run the checks that CI will run before committing. For specific projects, `.github` workflows can be used to find the standard build, lint, and formatting commands for that project.

Check the project's README, package.json, Makefile, or other build configuration files to determine the appropriate commands for:
- Running tests
- Formatting code
- Running linters
- Building the project

## Critical Reminders

### DO NOT

- Create documentation files unless explicitly requested
- Modify reference repositories
- Make up performance numbers or generic justifications for changes
- Create standalone test files instead of using test infrastructure. Use the project's build system and create tests runnable with the project's test framework.

### ALWAYS

- Check if repositories are already cloned locally
- Work in designated workspace directories for modifications (and work with git worktrees)
- Use existing benchmark infrastructure
- Follow project patterns and conventions
- Measure performance changes properly
- Let improvements stand on their technical merit
- Read relevant documentation before starting tasks


## Using Cast and Forge

### Cast - Command-Line Blockchain Interaction

Cast is Foundry's Swiss Army knife for interacting with Ethereum from the command line. **Use Cast for blockchain utilities and quick operations** rather than writing custom scripts for common tasks.

#### Common Cast Utilities

**Cryptographic Operations:**
```bash
# Compute keccak256 hash
cast keccak "transfer(address,uint256)"

# Generate function selector (4-byte signature)
cast sig "transfer(address,uint256)"

# Encode calldata
cast calldata "transfer(address,uint256)" 0x... 1000

# Decode calldata
cast calldata-decode "transfer(address,uint256)" 0xa9059cbb...
```

**Reading from Blockchain:**
```bash
# Read contract state (call)
cast call CONTRACT_ADDRESS "balanceOf(address)" USER_ADDRESS --rpc-url $RPC_URL

# Get storage at specific slot
cast storage CONTRACT_ADDRESS 0 --rpc-url $RPC_URL

# Get full storage layout (requires verified contract)
cast storage CONTRACT_ADDRESS --rpc-url $RPC_URL

# Get transaction receipt
cast receipt TX_HASH --rpc-url $RPC_URL

# Get current gas price
cast gas-price --rpc-url $RPC_URL

# Get account nonce
cast nonce ADDRESS --rpc-url $RPC_URL

# Get block number
cast block-number --rpc-url $RPC_URL

# Get contract bytecode
cast code CONTRACT_ADDRESS --rpc-url $RPC_URL
```

**Writing to Blockchain:**
```bash
# Send transaction (write operation)
cast send CONTRACT_ADDRESS "setNumber(uint256)" 42 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Estimate gas for transaction
cast estimate CONTRACT_ADDRESS "transfer(address,uint256)" RECIPIENT 1000 --rpc-url $RPC_URL
```

**Data Conversion Utilities:**
```bash
# Convert between units
cast to-wei 1 ether        # Convert to wei
cast from-wei 1000000000000000000  # Convert from wei

# Hex conversions
cast to-hex 255            # Decimal to hex
cast to-dec 0xff           # Hex to decimal
cast to-uint256 100        # Convert to uint256 format

# Address utilities
cast to-checksum-address 0x...  # EIP-55 checksum
cast compute-address DEPLOYER NONCE  # Compute deployment address
```

**ENS Operations:**
```bash
# Resolve ENS name to address
cast resolve-name "vitalik.eth" --rpc-url $RPC_URL

# Reverse ENS lookup
cast lookup-address 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 --rpc-url $RPC_URL

# Compute ENS namehash
cast namehash "vitalik.eth"
```

**Advanced Features:**
```bash
# Run transaction locally and get trace
cast run TX_HASH --rpc-url $RPC_URL

# Extract selectors from bytecode
cast selectors BYTECODE

# 4byte directory lookup
cast 4byte 0xa9059cbb  # Returns: transfer(address,uint256)
```

### When to Use Cast vs Custom Code

**Use Cast for:**
- Quick keccak256 hashing of function signatures or data
- Reading contract state, storage slots, balances
- Sending simple transactions
- Converting between data formats (hex, decimal, wei, ether)
- ENS lookups and resolution
- Getting blockchain data (gas price, nonce, block info)
- Debugging transactions with traces
- Computing contract addresses before deployment

**Write custom code when:**
- Building complex multi-step interactions
- Implementing business logic
- Creating reusable libraries or contracts
- Needing programmatic control flow
- Building user interfaces or applications

### Integration with Tests and Scripts

In Forge tests and scripts, you can leverage Cast-like functionality through the `vm` cheatcodes:

```solidity
// In tests - equivalent to cast keccak
bytes32 hash = keccak256("transfer(address,uint256)");

// Reading storage - equivalent to cast storage
bytes32 value = vm.load(address(contract), bytes32(uint256(0)));

// Labels for cast call-like clarity in traces
vm.label(address(token), "WETH");
```

### Best Practices

1. **Use Cast for prototyping**: Before writing a complex script, test your calls with Cast
2. **Verify with Cast**: After deployments, use Cast to verify contract state
3. **Debug with Cast**: Use `cast run` to debug failed transactions
4. **Prefer Cast for one-offs**: Don't write scripts for operations Cast can handle
5. **Chain Cast commands**: Combine Cast commands with shell scripting for powerful workflows

```bash
# Example: Get function selector and use it
SELECTOR=$(cast sig "transfer(address,uint256)")
cast call $CONTRACT $SELECTOR $RECIPIENT $AMOUNT --rpc-url $RPC_URL
```

Remember: Cast is your go-to tool for command-line blockchain interaction. It's faster and more reliable than writing custom utilities for common operations.