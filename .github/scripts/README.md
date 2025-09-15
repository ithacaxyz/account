# Benchmark CI Scripts

This directory contains scripts for automated benchmark comparison in pull requests.

## Overview

The benchmark CI system automatically:
1. Runs benchmarks on both PR and main branches
2. Compares gas usage between versions
3. Generates detailed reports with tables and visualizations
4. Posts results as PR comments
5. Checks for regressions above threshold

## Scripts

### `benchmark_comparison.py`
Main comparison script that analyzes benchmark snapshots and generates reports.

**Features:**
- Compares gas usage between main and PR branches
- Calculates percentage changes and absolute differences
- Groups tests by operation type and account
- Generates comparison tables showing Ithaca vs other accounts
- Identifies top improvements and regressions

**Usage:**
```bash
python3 benchmark_comparison.py \
  --main snapshots-main.json \
  --pr snapshots-pr.json \
  --output comparison-report.md \
  --json comparison-data.json
```

### `check_regressions.py`
Validates benchmark results against regression thresholds.

**Features:**
- Checks for gas regressions above configurable threshold
- Provides warnings for minor increases
- Returns non-zero exit code if regressions found
- Calculates overall average changes

**Usage:**
```bash
python3 check_regressions.py \
  --data comparison-data.json \
  --threshold 5  # 5% regression threshold
```

### `generate_charts.py`
Creates SVG visualizations for benchmark data.

**Features:**
- Generates bar charts comparing account gas usage
- Creates tables of top improvements/regressions
- Produces SVG files that can be embedded in PR comments
- Groups by operation type (single transfer, batch, Uniswap, etc.)

**Usage:**
```bash
python3 generate_charts.py \
  --data comparison-data.json \
  --output-dir charts
```

## Workflow Integration

The benchmark CI runs on every PR via `.github/workflows/benchmark-pr.yaml`:

1. **Checkout & Build**: Builds contracts on both PR and main branches
2. **Run Benchmarks**: Executes `forge snapshot --match-contract Benchmark`
3. **Compare Results**: Runs comparison scripts to analyze changes
4. **Generate Report**: Creates markdown report with tables and charts
5. **Post Comment**: Updates PR with benchmark results
6. **Check Regressions**: Fails CI if regressions exceed threshold

## Report Format

The generated report includes:

### Summary Section
- Total number of Ithaca Account benchmarks
- Average percentage change
- Count of improvements and regressions

### Ithaca Account Gas Changes
Detailed table showing:
- Test name
- Main branch gas usage
- PR branch gas usage
- Absolute change
- Percentage change
- Visual indicators (🟢 improvement, 🔴 regression, 🟡 minor change)

### Ithaca vs Competition
Comparison tables grouped by operation:
- ERC20 transfers
- Native ETH transfers
- Batch operations (100 transactions)
- Uniswap swaps

Shows how much gas Ithaca saves compared to:
- Coinbase Smart Wallet
- Alchemy Modular Account
- Safe 4337
- Zerodev Kernel
- ERC4337 Minimal Account

### Notable Changes
Highlights:
- Top 5 improvements with percentage savings
- Regressions requiring review
- Visual gas efficiency comparison chart

## Customization

### Adjusting Regression Threshold
Edit the workflow file to change the threshold:
```yaml
- name: Check for gas regressions
  run: |
    python3 .github/scripts/check_regressions.py \
      --data comparison-data.json \
      --threshold 10  # Allow up to 10% regression
```

### Adding New Account Types
Update `ACCOUNT_TYPES` in `benchmark_comparison.py`:
```python
ACCOUNT_TYPES = [
    'IthacaAccount',
    'NewAccountType',  # Add new account here
    # ...
]
```

### Modifying Report Format
Edit the `generate_markdown_report()` method in `benchmark_comparison.py` to customize the report structure and content.

## Local Testing

Run benchmarks locally:
```bash
# Generate snapshots
forge snapshot --match-contract Benchmark --snap local-snapshot.json

# Compare with main
git checkout main
forge snapshot --match-contract Benchmark --snap main-snapshot.json
git checkout -

# Run comparison
python3 .github/scripts/benchmark_comparison.py \
  --main main-snapshot.json \
  --pr local-snapshot.json \
  --output report.md \
  --json data.json

# Check for regressions
python3 .github/scripts/check_regressions.py --data data.json
```

## Troubleshooting

### Missing Dependencies
The scripts use standard Python libraries (json, argparse, re). No external dependencies required.

### Snapshot Format Issues
Ensure snapshots are valid JSON with test names as keys and gas values as strings:
```json
{
  "testName": "123456",
  "anotherTest": "789012"
}
```

### CI Failures
Check the workflow logs for:
- Forge build errors
- Python script errors
- GitHub API rate limits (for PR comments)
