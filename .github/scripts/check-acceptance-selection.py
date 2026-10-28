#!/usr/bin/env python3
"""Reject a broadened, incomplete, or skipped acceptance UI selection."""

import argparse
import json
from pathlib import Path
from selected_test_inventory import normalized, selected_tests, verify_products, verify_report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--products", type=Path)
    group.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        if args.products:
            verify_products(args.products)
        else:
            verify_report(json.loads(args.report.read_text()))
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"Acceptance selection validation failed: {error}\n")
    print("Acceptance selection verified.")


if __name__ == "__main__":
    main()
