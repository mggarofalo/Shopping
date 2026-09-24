"""Protect the quick/full boundary and its independent Fast coverage gate."""

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("acceptance", ROOT / ".github/scripts/check-acceptance-selection.py")
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


def plan(name):
    return json.loads((ROOT / f"{name}.xctestplan").read_text())


class AcceptanceContractTests(unittest.TestCase):
    def test_plan_preserves_fast_and_selects_only_existing_full_ui_methods(self):
        fast, quick, full = (plan(name) for name in ("ShoppingFast", "ShoppingAcceptance", "ShoppingFull"))
        self.assertEqual(quick["defaultOptions"], fast["defaultOptions"])
        self.assertEqual(quick["testTargets"][0], fast["testTargets"][0])
        self.assertEqual(len(quick["configurations"]), 1)
        self.assertEqual(quick["configurations"][0]["options"], {})
        self.assertEqual(len(quick["testTargets"]), 2)
        ui = quick["testTargets"][1]
        self.assertEqual(set(ui), {"target", "selectedTests"})
        self.assertEqual(ui["target"], full["testTargets"][1]["target"])
        selected = acceptance.selected_tests()
        self.assertTrue(5 <= len(selected) <= 7, "Keep the reviewed quick UI budget small")
        self.assertTrue(all(count == 1 for count in selected.values()))
        full_ui = full["testTargets"][1]
        self.assertNotIn("selectedTests", full_ui)
        for identifier in selected:
            suite, method = identifier.split("/")
            source = (ROOT / "ShoppingTests" / f"{suite}.swift").read_text()
            self.assertRegex(source, rf"\bfunc\s+{re.escape(method)}\s*\(")
            for excluded in full_ui.get("skippedTests", []):
                self.assertNotIn(acceptance.normalized(excluded), (suite, identifier))
        scheme = ET.parse(ROOT / "Shopping.xcodeproj/xcshareddata/xcschemes/Shopping.xcscheme")
        self.assertEqual(len(scheme.findall(".//TestPlanReference[@reference='container:ShoppingAcceptance.xctestplan']")), 1)

    def workflow(self):
        # Ruby YAML is already used by the repository's workflow contract tests.
        return json.loads(subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))",
            str(ROOT / ".github/workflows/swift-ci.yml")]))

    def test_workflow_runs_once_per_pr_and_keeps_fast_coverage_separate(self):
        workflow = self.workflow()
        triggers = workflow.get("on", workflow.get("true"))
        self.assertEqual(set(triggers), {"push", "pull_request", "workflow_dispatch"})
        self.assertEqual(triggers["push"]["branches"], ["main"])
        self.assertEqual(triggers["pull_request"]["branches"], ["main", "milestone/**"])
        build = workflow["jobs"]["build"]
        self.assertEqual(build["name"], "Build & Test")
        self.assertEqual(build["timeout-minutes"], 15)
        steps = {step.get("name"): step for step in build["steps"]}
        commands = [step.get("run", "") for step in build["steps"]]
        self.assertEqual(sum("xcodebuild build-for-testing" in command for command in commands), 1)
        self.assertIn("-testPlan ShoppingAcceptance", steps["Build acceptance test products"]["run"])
        fast = steps["Run fast deterministic tests"]["run"]
        ui = steps["Run acceptance UI workflows"]["run"]
        self.assertIn("-testPlan ShoppingFast", fast)
        self.assertNotIn("-only-testing", fast)
        self.assertIn("-testPlan ShoppingAcceptance", ui)
        self.assertIn("-only-testing:ShoppingTests", ui)
        self.assertIn("-parallel-testing-enabled NO", ui)
        for command in (fast, ui, steps["Build acceptance test products"]["run"]):
            self.assertIn("-derivedDataPath DerivedData", command)
            self.assertIn("steps.simulator.outputs.udid", command)
        coverage = steps["Enforce coverage baseline"]["run"]
        self.assertIn("FastResults.xcresult", coverage)
        self.assertNotIn("AcceptanceResults", coverage)
        self.assertIn(".github/coverage-baseline.json", coverage)
        self.assertIn("--products DerivedData/Build/Products", steps["Verify built acceptance selection"]["run"])
        self.assertIn("--report AcceptanceTiming.json", steps["Verify executed acceptance selection"]["run"])
        for step in build["steps"]:
            self.assertFalse(step.get("continue-on-error", False))
            self.assertNotRegex(step.get("run", ""), r"retry-tests-on-failure|test-iterations|\|\|\s*true")
        self.assertEqual(steps["Publish acceptance timing report"]["if"], "always()")
        self.assertEqual(steps["Publish fast timing report"]["if"], "always()")
        self.assertIn("release-build", workflow["jobs"])

    def test_built_selection_rejects_missing_broadened_or_excluded_ui(self):
        fast = plan("ShoppingFast")["testTargets"][0]
        ui = {"BlueprintName": "ShoppingTests", "OnlyTestIdentifiers": list(acceptance.selected_tests())}
        persistence = {"BlueprintName": "ShoppingPersistenceTests", "SkipTestIdentifiers": fast["skippedTests"]}
        data = {"TestPlan": {"Name": "ShoppingAcceptance"}, "TestConfigurations": [{"TestTargets": [persistence, ui]}]}
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            with self.assertRaises(ValueError):
                acceptance.verify_products(products)
            path = products / "Shopping.xctestrun"
            path.write_bytes(plistlib.dumps(data))
            acceptance.verify_products(products)
            for change in ({"OnlyTestIdentifiers": []}, {"OnlyTestIdentifiers": ["ChecklistUITests"]}, {"SkipTestIdentifiers": ["ChecklistUITests"]}):
                broken = deepcopy(data)
                broken["TestConfigurations"][0]["TestTargets"][1].update(change)
                path.write_bytes(plistlib.dumps(broken))
                with self.assertRaises(ValueError):
                    acceptance.verify_products(products)

    def test_actual_results_reject_skips_missing_extra_and_duplicate_tests(self):
        tests = [{"identifier": name + "()", "bundle": "ShoppingTests", "result": "Passed"} for name in acceptance.selected_tests()]
        report = {"tests": tests, "counts": {"totalTestCount": len(tests), "passedTests": len(tests), "failedTests": 0, "skippedTests": 0}}
        acceptance.verify_report(report)
        variants = [tests[:-1], tests + [tests[0]], tests + [{"identifier": "Other/testOther()", "bundle": "ShoppingTests", "result": "Passed"}]]
        skipped = deepcopy(tests)
        skipped[0]["result"] = "Skipped"
        variants.append(skipped)
        for variant in variants:
            with self.assertRaises(ValueError):
                acceptance.verify_report({**report, "tests": variant})


if __name__ == "__main__":
    unittest.main()
