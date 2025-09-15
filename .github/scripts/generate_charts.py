#!/usr/bin/env python3
"""
Generate visual charts for benchmark comparisons.
Creates SVG charts that can be embedded in PR comments.
"""

import json
import argparse
from pathlib import Path


def generate_svg_bar_chart(data: dict, title: str, width: int = 800, height: int = 400) -> str:
    """Generate an SVG bar chart comparing gas usage."""

    # Filter and prepare data
    accounts = []
    values = []
    max_value = 0

    for account, gas in sorted(data.items(), key=lambda x: x[1]):
        accounts.append(account)
        values.append(gas)
        max_value = max(max_value, gas)

    if not accounts:
        return ""

    # Chart dimensions
    margin = {'top': 40, 'right': 40, 'bottom': 100, 'left': 80}
    chart_width = width - margin['left'] - margin['right']
    chart_height = height - margin['top'] - margin['bottom']

    # Calculate bar dimensions
    bar_width = chart_width / len(accounts) * 0.8
    bar_spacing = chart_width / len(accounts) * 0.2

    # Start SVG
    svg = [f'<svg width="{width}" height="{height}" xmlns="http://www.w3.org/2000/svg">']

    # Add styles
    svg.append('''
    <style>
        .bar { fill: #6b7280; transition: fill 0.3s; cursor: pointer; }
        .bar:hover { fill: #4b5563; }
        .bar.ithaca { fill: #10b981; }
        .bar.ithaca:hover { fill: #059669; }
        .axis { stroke: #6b7280; stroke-width: 2; }
        .grid { stroke: #e5e7eb; stroke-width: 1; stroke-dasharray: 2,2; }
        .label { font-family: system-ui, -apple-system, sans-serif; font-size: 12px; fill: #374151; }
        .title { font-family: system-ui, -apple-system, sans-serif; font-size: 16px; font-weight: bold; fill: #111827; }
        .value { font-family: monospace; font-size: 11px; fill: #6b7280; text-anchor: middle; }
    </style>
    ''')

    # Add title
    svg.append(f'<text x="{width/2}" y="25" class="title" text-anchor="middle">{title}</text>')

    # Add grid lines
    num_grid_lines = 5
    for i in range(num_grid_lines + 1):
        y = margin['top'] + chart_height - (i * chart_height / num_grid_lines)
        svg.append(f'<line x1="{margin["left"]}" y1="{y}" x2="{width - margin["right"]}" y2="{y}" class="grid"/>')

        # Add y-axis labels
        value = int(max_value * i / num_grid_lines)
        svg.append(f'<text x="{margin["left"] - 10}" y="{y + 5}" class="label" text-anchor="end">{value:,}</text>')

    # Draw axes
    svg.append(f'<line x1="{margin["left"]}" y1="{margin["top"]}" x2="{margin["left"]}" y2="{height - margin["bottom"]}" class="axis"/>')
    svg.append(f'<line x1="{margin["left"]}" y1="{height - margin["bottom"]}" x2="{width - margin["right"]}" y2="{height - margin["bottom"]}" class="axis"/>')

    # Draw bars
    for i, (account, value) in enumerate(zip(accounts, values)):
        x = margin['left'] + i * (bar_width + bar_spacing) + bar_spacing / 2
        bar_height = (value / max_value) * chart_height if max_value > 0 else 0
        y = margin['top'] + chart_height - bar_height

        # Determine if this is Ithaca
        is_ithaca = 'IthacaAccount' in account
        bar_class = 'bar ithaca' if is_ithaca else 'bar'

        # Draw bar
        svg.append(f'<rect x="{x}" y="{y}" width="{bar_width}" height="{bar_height}" class="{bar_class}" rx="2"/>')

        # Add value label on top of bar
        svg.append(f'<text x="{x + bar_width/2}" y="{y - 5}" class="value">{value:,}</text>')

        # Add account label (rotated)
        label_x = x + bar_width / 2
        label_y = height - margin['bottom'] + 15

        # Truncate long account names
        display_name = account.replace('Account', '').replace('Smart', '')
        if len(display_name) > 12:
            display_name = display_name[:10] + '..'

        svg.append(f'''
        <text x="{label_x}" y="{label_y}" class="label"
              transform="rotate(45 {label_x} {label_y})"
              text-anchor="start">
            {display_name}
        </text>
        ''')

    svg.append('</svg>')
    return '\n'.join(svg)


def generate_comparison_table_svg(improvements: list, regressions: list, width: int = 600) -> str:
    """Generate an SVG table showing top improvements and regressions."""

    height = 50 + max(len(improvements), len(regressions)) * 30 + 50

    svg = [f'<svg width="{width}" height="{height}" xmlns="http://www.w3.org/2000/svg">']

    # Add styles
    svg.append('''
    <style>
        .header { font-family: system-ui, -apple-system, sans-serif; font-size: 14px; font-weight: bold; fill: #111827; }
        .text { font-family: system-ui, -apple-system, sans-serif; font-size: 12px; fill: #374151; }
        .improvement { fill: #10b981; }
        .regression { fill: #ef4444; }
        .mono { font-family: monospace; font-size: 11px; }
    </style>
    ''')

    # Headers
    svg.append('<text x="150" y="30" class="header" text-anchor="middle">🟢 Top Improvements</text>')
    svg.append('<text x="450" y="30" class="header" text-anchor="middle">🔴 Regressions</text>')

    # Draw improvements
    y_offset = 60
    for item in improvements[:5]:
        test_name = item['test'].replace('test', '').replace('_IthacaAccount', '')[:30]
        svg.append(f'<text x="10" y="{y_offset}" class="text">{test_name}</text>')
        svg.append(f'<text x="250" y="{y_offset}" class="mono improvement" text-anchor="end">{item["change"]:.1f}%</text>')
        y_offset += 25

    # Draw regressions
    y_offset = 60
    for item in regressions[:5]:
        test_name = item['test'].replace('test', '').replace('_IthacaAccount', '')[:30]
        svg.append(f'<text x="310" y="{y_offset}" class="text">{test_name}</text>')
        svg.append(f'<text x="550" y="{y_offset}" class="mono regression" text-anchor="end">+{item["change"]:.1f}%</text>')
        y_offset += 25

    svg.append('</svg>')
    return '\n'.join(svg)


def main():
    parser = argparse.ArgumentParser(description='Generate benchmark visualization charts')
    parser.add_argument('--data', required=True, help='Path to comparison JSON data')
    parser.add_argument('--output-dir', required=True, help='Output directory for charts')

    args = parser.parse_args()

    # Load data
    with open(args.data, 'r') as f:
        data = json.load(f)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Extract data for charts
    comparisons = data.get('comparisons', {})

    # Generate charts for different operation types
    operation_types = {
        'single_erc20': lambda t: 'testERC20Transfer_' in t and 'batch' not in t.lower() and 'Sponsor' not in t and 'ERC20SelfPay' not in t,
        'batch_erc20': lambda t: ('batch100' in t.lower() or 'Batch100' in t) and 'ERC20Transfer' in t,
        'uniswap': lambda t: 'UniswapV2Swap' in t,
        'native': lambda t: 'testNativeTransfer' in t
    }

    for op_name, filter_func in operation_types.items():
        chart_data = {}
        for test_name, test_data in comparisons.items():
            if filter_func(test_name) and test_data.get('account_type'):
                account = test_data['account_type']
                if account not in chart_data or test_data['pr'] < chart_data[account]:
                    chart_data[account] = test_data['pr']

        if chart_data:
            # Generate bar chart
            title = {
                'single_erc20': 'Single ERC20 Transfer - Gas Comparison',
                'batch_erc20': 'Batch ERC20 Transfer (100 txs) - Gas Comparison',
                'uniswap': 'Uniswap V2 Swap - Gas Comparison',
                'native': 'Native ETH Transfer - Gas Comparison'
            }.get(op_name, op_name)

            svg_content = generate_svg_bar_chart(chart_data, title)

            with open(output_dir / f'{op_name}_chart.svg', 'w') as f:
                f.write(svg_content)

    # Generate improvements/regressions table
    ithaca_tests = [(t, d) for t, d in comparisons.items() if 'IthacaAccount' in t]
    improvements = sorted(
        [{'test': t, 'change': d['percentage']} for t, d in ithaca_tests if d['percentage'] < -1],
        key=lambda x: x['change']
    )
    regressions = sorted(
        [{'test': t, 'change': d['percentage']} for t, d in ithaca_tests if d['percentage'] > 1],
        key=lambda x: x['change'],
        reverse=True
    )

    if improvements or regressions:
        svg_content = generate_comparison_table_svg(improvements, regressions)
        with open(output_dir / 'changes_table.svg', 'w') as f:
            f.write(svg_content)

    print(f"✅ Generated visualization charts in {output_dir}")


if __name__ == '__main__':
    main()