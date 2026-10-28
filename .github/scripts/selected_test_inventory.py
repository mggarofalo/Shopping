"""Exact planned, built and executed UI selection contracts."""
from collections import Counter
import json
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[2]

def normalized(identifier):
    return identifier.removesuffix("()")


def selected_tests(root=ROOT, plan_name="ShoppingAcceptance"):
    plan = json.loads((root / f"{plan_name}.xctestplan").read_text())
    target = next(t for t in plan["testTargets"] if t["target"]["name"] == "ShoppingTests")
    return Counter(normalized(test) for test in target["selectedTests"])


def verify_products(products, root=ROOT, plan_name="ShoppingAcceptance"):
    plans = []
    for path in products.glob("*.xctestrun"):
        data = plistlib.loads(path.read_bytes())
        if data.get("TestPlan", {}).get("Name") == plan_name:
            plans.append(data)
    if len(plans) != 1:
        raise ValueError(f"Expected one built {plan_name} plan, found {len(plans)}")
    configurations = plans[0]["TestConfigurations"]
    if len(configurations) != 1 or not configurations[0].get("IsEnabled", True):
        raise ValueError("Selection must have one enabled test configuration")
    targets = configurations[0]["TestTargets"]
    expected_targets = ["ShoppingTests", "ShoppingPersistenceTests"] if plan_name == "ShoppingAcceptance" else ["ShoppingTests"]
    if Counter(t["BlueprintName"] for t in targets) != Counter(expected_targets):
        raise ValueError("Built targets differ from the selected plan")
    ui = next(t for t in targets if t["BlueprintName"] == "ShoppingTests")
    if ui.get("SkipTestIdentifiers") or ui.get("IsEnabled") is False:
        raise ValueError("UI selection must be enabled without exclusions")
    if Counter(normalized(t) for t in ui.get("OnlyTestIdentifiers", [])) != selected_tests(root, plan_name):
        raise ValueError("Built UI identifiers differ from the explicit plan selection")
    if plan_name != "ShoppingAcceptance":
        return
    fast = json.loads((root / "ShoppingFast.xctestplan").read_text())["testTargets"][0]
    persistence = next(t for t in targets if t["BlueprintName"] == "ShoppingPersistenceTests")
    if persistence.get("OnlyTestIdentifiers") or persistence.get("IsEnabled") is False:
        raise ValueError("Acceptance must build all Fast tests")
    if set(persistence.get("SkipTestIdentifiers", [])) != set(fast.get("skippedTests", [])):
        raise ValueError("Built persistence exclusions differ from ShoppingFast")


def verify_report(report, root=ROOT, plan_name="ShoppingAcceptance"):
    expected = selected_tests(root, plan_name)
    tests = report["tests"]
    actual = Counter(normalized(t["identifier"]) for t in tests)
    if actual != expected or any(t["bundle"] != "ShoppingTests" for t in tests):
        raise ValueError(f"Executed UI identifiers differ from {plan_name}: expected {dict(expected)}, got {dict(actual)}")
    if any(t["result"] != "Passed" for t in tests):
        raise ValueError("Every selected UI test must pass without skips")
    counts = report["counts"]
    if counts != {"totalTestCount": len(tests), "passedTests": len(tests), "failedTests": 0, "skippedTests": 0}:
        raise ValueError("Selection summary counts disagree with the complete passing selection")


