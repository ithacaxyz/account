#!/usr/bin/env python3
"""
Generate detailed benchmark comparison reports for Ithaca Account benchmarks.
"""

import json
import argparse
import sys
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from collections import defaultdict
import re


class BenchmarkComparison:
    """Analyze and compare benchmark results between main and PR branches."""

    # Account types to track
    ACCOUNT_TYPES = [
        'IthacaAccount',
        'IthacaAccountWithSpendLimits',
        'ERC4337MinimalAccount',
        'CoinbaseSmartWallet',
        'AlchemyModularAccount',
        'Safe4337',
        'ZerodevKernel'
    ]

    # Test categories
    CATEGORIES = {
        'single_transfer': {
            'patterns': [
                r'^testERC20Transfer_(\w+)$',
                r'^testNativeTransfer_(\w+)$'
            ],
            'label': 'Single Transfer Operations'
        },
        'batch_transfer': {
            'patterns': [
                r'^testERC20Transfer_[Bb]atch100_(\w+)',
                r'^testERC20Transfer_batch100_(\w+)'
            ],
            'label': 'Batch Transfer Operations (100 txs)'
        },
        'uniswap': {
            'patterns': [
                r'^testUniswapV2Swap_(\w+)'
            ],
            'label': 'Uniswap V2 Swap Operations'
        },
        'app_sponsor': {
            'patterns': [
                r'_AppSponsor'
            ],
            'label': 'App Sponsored Transactions'
        },
        'erc20_pay': {
            'patterns': [
                r'_ERC20SelfPay'
            ],
            'label': 'ERC20 Self-Pay Transactions'
        }
    }

    def __init__(self, main_data: Dict, pr_data: Dict):
        self.main_data = main_data
        self.pr_data = pr_data
        self.comparisons = {}
        self.ithaca_comparisons = {}

    def calculate_change(self, main_val: int, pr_val: int) -> Tuple[int, float]:
        """Calculate absolute and percentage change."""
        absolute_change = pr_val - main_val
        if main_val == 0:
            percentage_change = 100.0 if pr_val > 0 else 0.0
        else:
            percentage_change = (absolute_change / main_val) * 100
        return absolute_change, percentage_change

    def get_account_type(self, test_name: str) -> Optional[str]:
        """Extract account type from test name."""
        for account_type in self.ACCOUNT_TYPES:
            if account_type in test_name:
                return account_type
        return None

    def analyze(self):
        """Perform full analysis of benchmark data."""
        # Compare all tests
        all_tests = set(self.main_data.keys()) | set(self.pr_data.keys())

        for test_name in all_tests:
            main_gas = int(self.main_data.get(test_name, 0))
            pr_gas = int(self.pr_data.get(test_name, 0))

            if main_gas == 0 and pr_gas == 0:
                continue

            abs_change, pct_change = self.calculate_change(main_gas, pr_gas)

            self.comparisons[test_name] = {
                'main': main_gas,
                'pr': pr_gas,
                'absolute': abs_change,
                'percentage': pct_change,
                'account_type': self.get_account_type(test_name)
            }

        # Analyze Ithaca-specific comparisons
        self._analyze_ithaca_comparisons()

    def _analyze_ithaca_comparisons(self):
        """Compare Ithaca Account performance against other accounts."""
        categories = defaultdict(dict)

        for test_name, data in self.comparisons.items():
            account_type = data['account_type']
            if not account_type:
                continue

            # Categorize tests
            for category_key, category_info in self.CATEGORIES.items():
                for pattern in category_info['patterns']:
                    if re.search(pattern, test_name):
                        base_test = re.sub(r'_' + account_type + r'.*', '', test_name)
                        if base_test not in categories[category_key]:
                            categories[category_key][base_test] = {}
                        categories[category_key][base_test][account_type] = data
                        break

        # Calculate Ithaca vs others comparison
        for category_key, tests in categories.items():
            self.ithaca_comparisons[category_key] = {}
            for base_test, accounts in tests.items():
                if 'IthacaAccount' in accounts:
                    ithaca_data = accounts['IthacaAccount']
                    comparisons = {}

                    for account_type, account_data in accounts.items():
                        if account_type != 'IthacaAccount':
                            # Compare PR values
                            pr_diff_abs = account_data['pr'] - ithaca_data['pr']
                            pr_diff_pct = ((pr_diff_abs / account_data['pr']) * 100) if account_data['pr'] > 0 else 0

                            # Compare main values
                            main_diff_abs = account_data['main'] - ithaca_data['main']
                            main_diff_pct = ((main_diff_abs / account_data['main']) * 100) if account_data['main'] > 0 else 0

                            comparisons[account_type] = {
                                'pr_savings_abs': pr_diff_abs,
                                'pr_savings_pct': pr_diff_pct,
                                'main_savings_abs': main_diff_abs,
                                'main_savings_pct': main_diff_pct,
                                'improvement': pr_diff_pct - main_diff_pct
                            }

                    self.ithaca_comparisons[category_key][base_test] = {
                        'ithaca': ithaca_data,
                        'comparisons': comparisons
                    }

    def generate_markdown_report(self, repo_url: str = None, run_id: str = None) -> str:
        """Generate a detailed markdown report."""
        report = []
        report.append("## 📊 Benchmark Comparison Report\n")
        report.append("*Comparing gas usage between `main` and this PR*\n")

        # Summary section
        report.append("### 🎯 Summary\n")
        ithaca_tests = [t for t, d in self.comparisons.items() if 'IthacaAccount' in t]

        if ithaca_tests:
            avg_change = sum(self.comparisons[t]['percentage'] for t in ithaca_tests) / len(ithaca_tests)
            improvements = [t for t in ithaca_tests if self.comparisons[t]['percentage'] < 0]
            regressions = [t for t in ithaca_tests if self.comparisons[t]['percentage'] > 5]

            report.append(f"- **Ithaca Account Tests**: {len(ithaca_tests)} benchmarks\n")
            report.append(f"- **Average Change**: {avg_change:+.2f}%\n")
            report.append(f"- **Improvements**: {len(improvements)} tests\n")
            report.append(f"- **Regressions** (>5%): {len(regressions)} tests\n")

        # Ithaca Account Performance Table
        report.append("\n### 🏆 Ithaca Account Gas Changes\n")
        report.append("| Test | Main Gas | PR Gas | Change | % Change |\n")
        report.append("|------|----------|--------|--------|----------|\n")

        ithaca_sorted = sorted(
            [(t, d) for t, d in self.comparisons.items() if 'IthacaAccount' in t],
            key=lambda x: x[1]['percentage']
        )

        for test_name, data in ithaca_sorted:
            short_name = test_name.replace('test', '').replace('_IthacaAccount', '')
            emoji = "🟢" if data['percentage'] <= -5 else "🔴" if data['percentage'] >= 5 else "🟡"

            report.append(
                f"| {emoji} {short_name} | "
                f"{data['main']:,} | "
                f"{data['pr']:,} | "
                f"{data['absolute']:+,} | "
                f"{data['percentage']:+.2f}% |\n"
            )

        # Comparison with other accounts
        report.append("\n### 📈 Ithaca vs Competition\n")
        report.append("*How much gas Ithaca saves compared to other account implementations*\n\n")

        # Group by operation type
        operation_groups = {
            'ERC20 Transfer': ['testERC20Transfer'],
            'Native Transfer': ['testNativeTransfer'],
            'Batch Operations (100 txs)': ['batch100', 'Batch100'],
            'Uniswap Swap': ['UniswapV2Swap']
        }

        for operation, patterns in operation_groups.items():
            relevant_tests = {}
            for test_name, data in self.comparisons.items():
                if any(p in test_name for p in patterns) and data['account_type']:
                    # Group by base operation
                    base_op = test_name
                    for account in self.ACCOUNT_TYPES:
                        base_op = base_op.replace(f'_{account}', '')
                    base_op = re.sub(r'_AppSponsor.*$|_ERC20SelfPay.*$', '', base_op)

                    if base_op not in relevant_tests:
                        relevant_tests[base_op] = {}
                    relevant_tests[base_op][data['account_type']] = data

            if not relevant_tests:
                continue

            report.append(f"\n#### {operation}\n")
            report.append("| Account Type | PR Gas | vs Ithaca | Savings % |\n")
            report.append("|--------------|--------|-----------|----------|\n")

            for base_op, accounts in relevant_tests.items():
                if 'IthacaAccount' in accounts:
                    ithaca_gas = accounts['IthacaAccount']['pr']

                    # Sort by gas usage
                    sorted_accounts = sorted(
                        [(a, d) for a, d in accounts.items()],
                        key=lambda x: x[1]['pr']
                    )

                    for account_type, data in sorted_accounts:
                        if account_type == 'IthacaAccount':
                            report.append(f"| **{account_type}** ✨ | **{data['pr']:,}** | **—** | **—** |\n")
                        else:
                            diff = data['pr'] - ithaca_gas
                            savings = (diff / data['pr'] * 100) if data['pr'] > 0 else 0
                            report.append(
                                f"| {account_type} | {data['pr']:,} | "
                                f"+{diff:,} | {savings:.1f}% |\n"
                            )

                    report.append("\n")

        # Top improvements and regressions
        if ithaca_tests:
            report.append("\n### 🔍 Notable Changes\n")

            # Top improvements
            improvements = sorted(
                [(t, d) for t, d in self.comparisons.items() if 'IthacaAccount' in t and d['percentage'] < -1],
                key=lambda x: x[1]['percentage']
            )[:5]

            if improvements:
                report.append("\n**Top Improvements:**\n")
                for test_name, data in improvements:
                    short_name = test_name.replace('test', '').replace('_IthacaAccount', '')
                    report.append(f"- 🟢 {short_name}: **{data['percentage']:.1f}%** ({data['absolute']:+,} gas)\n")

            # Top regressions
            regressions = sorted(
                [(t, d) for t, d in self.comparisons.items() if 'IthacaAccount' in t and d['percentage'] > 1],
                key=lambda x: x[1]['percentage'],
                reverse=True
            )[:5]

            if regressions:
                report.append("\n**Regressions to Review:**\n")
                for test_name, data in regressions:
                    short_name = test_name.replace('test', '').replace('_IthacaAccount', '')
                    report.append(f"- 🔴 {short_name}: **+{data['percentage']:.1f}%** ({data['absolute']:+,} gas)\n")

        # Gas efficiency chart
        report.append("\n### 📊 Gas Efficiency Comparison\n")
        report.append("```mermaid\n")
        report.append("graph LR\n")
        report.append("    subgraph \"Single Operations\"\n")

        # Find a representative single operation test
        single_op_accounts = {}
        for test_name, data in self.comparisons.items():
            if 'testERC20Transfer_' in test_name and 'batch' not in test_name.lower() and 'Sponsor' not in test_name and 'ERC20SelfPay' not in test_name:
                if data['account_type']:
                    single_op_accounts[data['account_type']] = data['pr']

        if single_op_accounts:
            sorted_single = sorted(single_op_accounts.items(), key=lambda x: x[1])
            for i, (account, gas) in enumerate(sorted_single):
                style = "A" if account == 'IthacaAccount' else chr(66 + i)
                report.append(f"        {style}[{account}<br/>{gas:,} gas]\n")

        report.append("    end\n")
        report.append("```\n")

        # Footer
        report.append("\n---\n")
        report.append("*Generated by Ithaca Benchmark CI")
        if repo_url and run_id:
            report.append(f" • [View Full Report]({repo_url}/actions/runs/{run_id})")
        report.append("*\n")

        return ''.join(report)

    def generate_json_data(self) -> Dict:
        """Generate JSON data for further processing."""
        return {
            'comparisons': self.comparisons,
            'ithaca_comparisons': self.ithaca_comparisons,
            'summary': {
                'total_tests': len(self.comparisons),
                'ithaca_tests': len([t for t in self.comparisons if 'IthacaAccount' in t]),
                'improvements': len([t for t, d in self.comparisons.items() if d['percentage'] < -1]),
                'regressions': len([t for t, d in self.comparisons.items() if d['percentage'] > 5])
            }
        }


def main():
    parser = argparse.ArgumentParser(description='Compare benchmark snapshots')
    parser.add_argument('--main', required=True, help='Path to main branch snapshot')
    parser.add_argument('--pr', required=True, help='Path to PR branch snapshot')
    parser.add_argument('--output', required=True, help='Output markdown report path')
    parser.add_argument('--json', required=True, help='Output JSON data path')
    parser.add_argument('--repo-url', help='GitHub repository URL')
    parser.add_argument('--run-id', help='GitHub Actions run ID')

    args = parser.parse_args()

    # Load snapshots
    with open(args.main, 'r') as f:
        main_data = json.load(f)

    with open(args.pr, 'r') as f:
        pr_data = json.load(f)

    # Perform comparison
    comparison = BenchmarkComparison(main_data, pr_data)
    comparison.analyze()

    # Generate reports
    markdown_report = comparison.generate_markdown_report(args.repo_url, args.run_id)
    json_data = comparison.generate_json_data()

    # Save outputs
    with open(args.output, 'w') as f:
        f.write(markdown_report)

    with open(args.json, 'w') as f:
        json.dump(json_data, f, indent=2)

    print(f"✅ Generated benchmark comparison report: {args.output}")
    print(f"✅ Generated JSON data: {args.json}")


if __name__ == '__main__':
    main()