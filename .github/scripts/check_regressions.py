#!/usr/bin/env python3
"""
Check for gas regressions in benchmark results.
"""

import json
import argparse
import sys


def check_regressions(data_file: str, threshold: float = 5.0) -> int:
    """
    Check for gas regressions above the threshold.

    Args:
        data_file: Path to comparison JSON data
        threshold: Percentage threshold for regressions

    Returns:
        Exit code (0 = success, 1 = regressions found)
    """
    with open(data_file, 'r') as f:
        data = json.load(f)

    comparisons = data.get('comparisons', {})
    regressions = []
    warnings = []

    # Check for regressions in Ithaca Account tests
    for test_name, test_data in comparisons.items():
        if 'IthacaAccount' not in test_name:
            continue

        pct_change = test_data['percentage']

        if pct_change > threshold:
            regressions.append({
                'test': test_name,
                'change': pct_change,
                'absolute': test_data['absolute'],
                'main': test_data['main'],
                'pr': test_data['pr']
            })
        elif pct_change > threshold / 2:  # Warn at half threshold
            warnings.append({
                'test': test_name,
                'change': pct_change,
                'absolute': test_data['absolute']
            })

    # Report findings
    if regressions:
        print("❌ Gas regressions detected!\n")
        print(f"The following Ithaca Account tests show regressions above {threshold}%:\n")

        for reg in regressions:
            short_name = reg['test'].replace('test', '').replace('_IthacaAccount', '')
            print(f"  🔴 {short_name}:")
            print(f"     Main: {reg['main']:,} gas")
            print(f"     PR:   {reg['pr']:,} gas")
            print(f"     Change: +{reg['change']:.1f}% (+{reg['absolute']:,} gas)\n")

        print("\nPlease review these changes and ensure they are justified.")
        print("If these regressions are expected, please document the reasons in the PR description.")

    if warnings:
        print("\n⚠️  Warning: Minor gas increases detected\n")
        for warn in warnings:
            short_name = warn['test'].replace('test', '').replace('_IthacaAccount', '')
            print(f"  🟡 {short_name}: +{warn['change']:.1f}% (+{warn['absolute']:,} gas)")

    if not regressions and not warnings:
        print("✅ No significant gas regressions detected!")
        print(f"All Ithaca Account benchmarks are within the {threshold}% threshold.")

    # Check for overall improvement
    ithaca_tests = [t for t, d in comparisons.items() if 'IthacaAccount' in t]
    if ithaca_tests:
        avg_change = sum(comparisons[t]['percentage'] for t in ithaca_tests) / len(ithaca_tests)

        if avg_change < -1:
            print(f"\n🎉 Overall improvement: {abs(avg_change):.1f}% average gas reduction!")
        elif avg_change > 1:
            print(f"\n📈 Overall increase: {avg_change:.1f}% average gas increase")

    # Return exit code based on regressions
    return 1 if regressions else 0


def main():
    parser = argparse.ArgumentParser(description='Check for gas regressions')
    parser.add_argument('--data', required=True, help='Path to comparison JSON data')
    parser.add_argument('--threshold', type=float, default=5.0,
                        help='Regression threshold percentage (default: 5%)')

    args = parser.parse_args()

    exit_code = check_regressions(args.data, args.threshold)
    sys.exit(exit_code)


if __name__ == '__main__':
    main()