# Claude Code Agent Guide for Ithaca Account Repository
It is important for all claude agents to follow these instructions.

## Directory Structure and Purpose

Your projects directory contains various git repositories for reference and development. Each subdirectory is typically an independent git repository used for finding code examples, implementations, and reference material.

**CRITICAL**: Reference repositories are for REFERENCE ONLY. Do not modify git configurations or remotes in these repositories.

## Essential Workflow Rules

### 1. Working Directory Guidelines

- **Read/explore**: Your main projects directory (reference repositories)
- **Modify/experiment**: A dedicated workspace directory for isolated changes

**ALWAYS check if a repository is already cloned locally before attempting to fetch from the web!** Use `ls` or check the directory structure to see if the project you need is already present before cloning it for reference.

### 2. Code Modification Workflow

When working on code changes:

1. **Always work in a dedicated workspace directory**
2. **Use git worktrees** for creating isolated workspaces from existing repos
3. **Only use git clone if the repository doesn't exist locally**
4. **NEVER modify the remotes of existing reference repositories**

#### Git Worktree Workflow (Preferred)

Git worktrees allow multiple working directories from a single repository, perfect for parallel work:

```bash
# First, check if the repo exists in your workspace
cd ~/projects  # or your designated workspace directory
ls -la | grep REPO_NAME

# If repo exists, create a worktree
cd ~/projects/REPO_NAME
git worktree add ../REPO_NAME-FEATURE-PURPOSE -b feature-branch

# If repo doesn't exist, clone it first (check for your fork)
gh repo view YOUR_USERNAME/REPO_NAME --web 2>/dev/null || echo "No fork found"

# Clone from your fork if it exists
git clone git@github.com:YOUR_USERNAME/REPO_NAME.git REPO_NAME
cd REPO_NAME
git remote add upstream git@github.com:ORIGINAL_ORG/REPO_NAME.git

# Or clone from original if no fork
git clone git@github.com:ORIGINAL_ORG/REPO_NAME.git REPO_NAME
```

#### Worktree Management

```bash
# List all worktrees for a repo
git worktree list

# Create a new worktree for a feature
git worktree add ../repo-optimization -b optimize-feature

# Remove a worktree when done
git worktree remove ../repo-optimization

# Clean up worktree references
git worktree prune
```

Use descriptive worktree names that indicate purpose:
- `project-cpu-optimization`
- `repo-name-issue-123`
- `project-feature-description`

**Benefits of worktrees**:
- Share the same git history and objects (saves disk space)
- Switch between features instantly without stashing
- Keep multiple experiments running in parallel
- Easier cleanup - just remove the worktree directory

#### Workspace Maintenance

**Clean up build artifacts** when disk space is needed based on the project type.

**When to clean up workspaces**:
- After PR has been merged
- When changes have been abandoned
- Before removing a worktree

```bash
# Clean and remove a worktree
cd ~/projects/repo-name
git worktree remove ../repo-optimization
```

### 3. Git Workflow

When working on code:

1. Create feature branches for your work
2. Commit changes with clear messages
3. Use descriptive branch names: `name/fix-something`, `name/add-feature`, `name/improve-performance`

### 4. GitHub CLI (gh) Usage

The `gh` CLI tool is available for exploring GitHub repositories and understanding code context.

#### Allowed Operations

```bash
# Repository exploration
gh repo view owner/repo
gh repo clone owner/repo  # For initial clones

# Issues and PRs
gh issue list --repo owner/repo
gh issue view 123 --repo owner/repo
gh pr list --repo owner/repo
gh pr view 456 --repo owner/repo
gh pr diff 456 --repo owner/repo
gh pr checkout 456  # To examine PR branches locally

# API queries
gh api repos/owner/repo/pulls/123/comments
gh api repos/owner/repo/issues/123/comments

# Search operations
gh search issues "query" --repo owner/repo
gh search prs "query" --repo owner/repo

# Status and authentication
gh auth status
gh status

# Releases and workflows (read-only)
gh release list --repo owner/repo
gh release view v1.0.0 --repo owner/repo
gh workflow list --repo owner/repo
gh run list --workflow=ci.yml --repo owner/repo
```

#### Common Use Cases

1. **Examining PR discussions**:
   ```bash
   gh pr view 123 --comments
   gh api repos/owner/repo/pulls/123/comments | jq '.[].body'
   ```

2. **Finding related issues**:
   ```bash
   gh search issues "optimization" --repo owner/repo --state open
   ```

3. **Checking PR changes**:
   ```bash
   gh pr diff 456 --repo owner/repo
   ```

## Task-Specific Guidelines

### Performance Optimization

#### Key Performance Principles

1. **Always use existing benchmark infrastructure**
   ```bash
   # Check existing benchmarks in the project
   ls benches/
   ls test/
   ```

2. **Never create standalone benchmark files** - use the project's build system and create benchmarks runnable with the project's test framework.

3. **Proper benchmarking workflow**:
   ```bash
   # Start from main
   git checkout main
   git pull origin main
   
   # Run baseline benchmarks using the project's benchmark tools
   # Save baseline results for comparison
   
   # Create optimization branch
   git checkout -b optimize-operation-description
   
   # Implement changes and re-run benchmarks
   # Compare with baseline results
   ```

4. **Draw inspiration from reference projects based on the technology stack**

5. **Measure performance changes**, then understand the impact:
   - Use the project's benchmark tools
   - Compare results before and after changes
   - Reflect on the impact based on understanding of the new code
   - Repeat the process until satisfied with the results

### Writing Code

1. **Follow existing patterns** - Study how the project structures similar code
2. **Check dependencies first** - Never assume a library is available
3. **Maintain consistency** - Use the project's naming conventions and style
4. **Security first** - Never expose secrets or keys in code

### Commit Message Best Practices

Writing excellent commit messages is crucial - they become the permanent record of why changes were made.

#### Commit Title Format

Use semantic commit format with a clear, specific title:
- `feat:` - New features
- `fix:` - Bug fixes  
- `perf:` - Performance improvements
- `chore:` - Maintenance tasks
- `docs:` - Documentation
- `test:` - Test changes
- `refactor:` - Code restructuring

**Title guidelines**:
- Be specific: `perf: optimize database query for user lookup` not `perf: optimize query`
- Use imperative mood: "add" not "adds" or "added"
- Keep under 50 characters when possible
- Don't end with a period

#### Commit Description (Body)

The commit body is where you provide context and details about a specific commit. **This is different from PR descriptions**. Many commits do not have descriptions.

**When to add a body**:
- Breaking changes (note the impact)
- Non-obvious changes (explain why, not what)
- When a commit is very complex or cannot be split up, and is not the only distinct change in the branch or PR

**Format**:
```
<title line>
<blank line>
<body>
<blank line>
<footer>
```

#### Examples

**Performance improvement** (body required):
```
perf: optimize user lookup with indexed queries

Benchmarks show ~3x speedup for user searches:
- Before: ~120ms
- After: ~40ms

Added composite index on (email, status) columns which
are commonly queried together in the application.
```

**Bug fix** (explain the issue):
```
fix: correct session timeout calculation

The timeout was being calculated from the last request time
instead of the last activity time. This caused sessions to
expire prematurely when users were actively using the app.

Added test case that reproduces the issue.
```

**Simple feature** (title often sufficient):
```
feat: add CSV export for user data
```

**Complex change** (needs explanation):
```
refactor: split request processing into async workers

Previous implementation processed all requests synchronously,
creating a bottleneck during high load. This change:

- Separates I/O-bound and CPU-bound operations
- Processes requests in parallel worker pools
- Maintains request ordering where required
- Adds backpressure handling

Reduces average response time from 200ms to 50ms under load.
```

#### What NOT to Do

- Don't write generic descriptions: "Update code", "Fix bug"
- Don't use many bullet points unless listing multiple distinct changes
- Don't make up metrics without measurements
- Don't write essays - be concise but complete

#### Key Principles

1. **The title should make sense in a changelog**
2. **The body should explain to a future developer why this change was necessary**
3. **Include concrete measurements for performance claims**
4. **Reference issues when fixing bugs**: `Fixes #12345`
5. **Let improvements stand on their own merit** - don't invent generic justifications
6. **Match detail to complexity** - Simple changes need simple descriptions

### Pull Request Descriptions

PR descriptions should provide reviewers with the context they need to understand changes, while avoiding verbosity and AI-sounding language.

#### Core Principles

1. **Be descriptive but concise** - Include what reviewers need, nothing more
2. **Explain what and why** - Help reviewers understand the changes and motivation
3. **Include real measurements** - Only include numbers you've actually measured
4. **Link related work** - Reference issues, discussions, and dependencies
5. **Write well** - Use flowing prose, not bullet points. Good writing matters

#### PR Title

Clear, specific titles that make the purpose obvious:
- `feat: add user activity metrics`
- `fix: correct edge case in payment processing`
- `perf: optimize database connection pooling`

#### PR Body Patterns

**Bug fix with context**:
```
The validator was incorrectly handling empty request bodies, causing panics
during API calls. Fixed by adding proper validation before processing data.

Fixes #12345
```

**Feature with explanation**:
```
Needed for graceful shutdown and testing scenarios where we need to drop all 
connections without restarting the entire service. The method ensures all 
pending operations complete before clearing the pool.

Will be used in #15648
```

**Linking dependencies**:
```
The old authentication API is deprecated and will be removed in the next 
major version. This migrates to the new API which provides better performance
and cleaner error handling.

depends on https://github.com/org/repo/pull/16179
```

**Performance with evidence**:
```
Previously database queries took ~30% of request processing time

Main profile: https://share.firefox.dev/3S18zep
After: https://share.firefox.dev/4T29afq
```

**Feature with multiple aspects**:
```
API request processing was a black box - we had no visibility into where time 
was spent. Now we track processing times for authentication, validation, 
business logic, and database operations throughout request handling.

The metrics use our existing monitoring infrastructure and are exposed on the 
standard metrics endpoint. They're sampled at 10% by default to minimize overhead,
configurable via `--metrics-sample-rate`. Initial data shows database operations 
dominate execution time at 60-70% of total request processing.
```

#### Bad vs Good Examples

**Bad** (too verbose, AI-sounding):
```
fix: improve error handling in API module

## Description
This PR enhances the error handling capabilities of the API module by implementing
more granular error types. By introducing these changes, we ensure that users
receive more informative error messages, which will help with debugging.

## Changes Made
- 🚀 Added new error types for different failure scenarios
- 📝 Updated error messages to be more descriptive
- ✅ Added tests to verify error handling

## Benefits
This will improve the developer experience by providing clearer error messages.
```

**Bad** (too minimal, unhelpful):

```
fix: add API error types

Closes #5678
```

**Good** (descriptive with flowing prose):
```
fix: add specific API error types

Previously all API errors returned generic "internal error" messages, making it 
impossible for users to understand what went wrong or how to fix it. We now have
specific error types for common failure modes: `InvalidRequestFormat` when the 
request body is malformed, `ResourceNotFound` for missing entities, and 
`RateLimitExceeded` for throttling scenarios.

Users now receive actionable error messages that explain the problem and suggest
solutions, rather than opaque 500 errors that require diving into server logs.

Closes #5678
```

#### When More Detail is Needed

Some PRs benefit from more comprehensive descriptions:

1. **Performance improvements** - Include benchmarks, profiles, and methodology
2. **Breaking changes** - Explain what breaks and migration path
3. **Complex features** - Describe architecture and design decisions
4. **Bug fixes for subtle issues** - Explain root cause and fix approach
5. **External context** - Link to discussions, RFCs, or design docs

For complex changes, don't artificially limit yourself. Include what reviewers need to understand the change properly. The goal is clarity, not arbitrary brevity.

#### Writing Quality Matters

Good PR descriptions demonstrate strong technical writing skills. Use complete sentences that flow naturally from one to another. Avoid bullet-point lists when prose would be more effective. Your description should read like a well-written technical explanation to a colleague, not a checklist or template.

**Scale detail to match complexity**. A simple bug fix needs a paragraph explaining the issue and solution. A performance optimization might need two paragraphs covering the problem and the measured improvement. A major architectural change warrants the full story: what problem existed, why it mattered, how you solved it, and what the impact is.

The key is judgment - include enough context for reviewers to understand your change without overwhelming them with unnecessary detail for straightforward PRs.

#### Key Point

Good PR descriptions provide the context reviewers need without unnecessary verbosity. Write naturally, be specific about what changed and why, and include real measurements for performance claims. The goal is to help reviewers understand your changes quickly and thoroughly.

### CRITICAL: Never Make Up Measurements

**NEVER include performance numbers, benchmarks, or metrics unless you have actually measured them!** This is especially important for AI agents who might be tempted to invent plausible-sounding numbers.

#### Bad (made-up numbers):
```
perf: optimize database queries

~3x faster on production workloads
- Before: 120ms
- After: 40ms
```

#### Good (only what you measured):
```
perf: optimize database queries

Benchmarked with the project's performance test suite:
- Before: 120ms
- After: 40ms
```

#### Also Good (no numbers if not measured):
```
perf: optimize database queries with connection pooling

Previous implementation created new connections for each query.
Now maintains a connection pool with configurable size limits.
```

If you haven't run benchmarks, don't include numbers. Describe the optimization approach instead.

### Code Review Analysis

When analyzing code or PRs:

1. **Be specific and actionable** - Reference exact lines and types
2. **Suggest alternatives with code** - Don't just identify issues
3. **Consider performance implications** - Question allocations and algorithms
4. **Focus on what matters** - Correctness > Performance > Style

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
- Prefer `calldata` over `memory`.
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