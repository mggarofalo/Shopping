#!/usr/bin/env python3
"""Reject a broadened, incomplete, or skipped acceptance UI selection."""

import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[2]


def normalized(identifier):
    return identifier.removesuffix("()")


def selected_tests(root=ROOT):
    plan = json.loads((root / "ShoppingAcceptance.xctestplan").read_text())
    target = next(t for t in plan["testTargets"] if t["target"]["name"] == "ShoppingTests")
    return Counter(normalized(test) for test in target["selectedTests"])


def verify_products(products, root=ROOT):
    plans = []
    for path in products.glob("*.xctestrun"):
        data = plistlib.loads(path.read_bytes())
        if data.get("TestPlan", {}).get("Name") == "ShoppingAcceptance":
            plans.append(data)
    if len(plans) != 1:
        raise ValueError(f"Expected one built ShoppingAcceptance plan, found {len(plans)}")
    configurations = plans[0]["TestConfigurations"]
    if len(configurations) != 1 or not configurations[0].get("IsEnabled", True):
        raise ValueError("Acceptance must have one enabled test configuration")
    targets = configurations[0]["TestTargets"]
    if Counter(t["BlueprintName"] for t in targets) != Counter(["ShoppingTests", "ShoppingPersistenceTests"]):
        raise ValueError("Acceptance products must contain exactly the Fast and UI targets")
    ui = next(t for t in targets if t["BlueprintName"] == "ShoppingTests")
    if ui.get("SkipTestIdentifiers") or ui.get("IsEnabled") is False:
        raise ValueError("Acceptance UI selection must be enabled without exclusions")
    if Counter(normalized(t) for t in ui.get("OnlyTestIdentifiers", [])) != selected_tests(root):
        raise ValueError("Built UI identifiers differ from the explicit acceptance selection")
    fast = json.loads((root / "ShoppingFast.xctestplan").read_text())["testTargets"][0]
    persistence = next(t for t in targets if t["BlueprintName"] == "ShoppingPersistenceTests")
    if persistence.get("OnlyTestIdentifiers") or persistence.get("IsEnabled") is False:
        raise ValueError("Acceptance must build all Fast tests")
    if set(persistence.get("SkipTestIdentifiers", [])) != set(fast.get("skippedTests", [])):
        raise ValueError("Built persistence exclusions differ from ShoppingFast")


def verify_report(report, root=ROOT):
    expected = selected_tests(root)
    tests = report["tests"]
    actual = Counter(normalized(t["identifier"]) for t in tests)
    if actual != expected or any(t["bundle"] != "ShoppingTests" for t in tests):
        raise ValueError(f"Executed UI identifiers differ from acceptance: expected {dict(expected)}, got {dict(actual)}")
    if any(t["result"] != "Passed" for t in tests):
        raise ValueError("Every selected acceptance UI test must pass without skips")
    counts = report["counts"]
    if counts != {"totalTestCount": len(tests), "passedTests": len(tests), "failedTests": 0, "skippedTests": 0}:
        raise ValueError("Acceptance summary counts disagree with the complete passing selection")


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
