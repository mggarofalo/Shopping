"""Protect the quick/full boundary and its independent Fast coverage gate."""

from copy import deepcopy
import fnmatch
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
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
        self.assertEqual(build["name"], "Build & Test (native)")
        self.assertEqual(build["timeout-minutes"], 30)
        steps = {step.get("name"): step for step in build["steps"]}
        commands = [step.get("run", "") for step in build["steps"]]
        driver_command = shlex.split(steps["Validate system text-size driver"]["run"])
        driver_pattern = driver_command[driver_command.index("-p") + 1]
        for filename in ("test_system_text_size.py", "test_system_text_size_protocol.py"):
            self.assertTrue(fnmatch.fnmatchcase(filename, driver_pattern),
                            f"CI must discover driver proof in {filename}")
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

    def test_only_routine_acceptance_disables_automatic_diagnostic_collection(self):
        workflow = self.workflow()
        configured = []
        for job_name, job in workflow["jobs"].items():
            for step in job.get("steps", []):
                command = step.get("run", "")
                if "-collect-test-diagnostics" not in command:
                    continue
                tokens = shlex.split(command)
                configured.append((job_name, step.get("name")))
                self.assertEqual(tokens.count("-collect-test-diagnostics"), 1)
                self.assertEqual(tokens[tokens.index("-collect-test-diagnostics") + 1], "never")
                self.assertIn("xcodebuild", tokens)
                self.assertIn("test-without-building", tokens)
                self.assertEqual(tokens[tokens.index("-resultBundlePath") + 1], "AcceptanceResults.xcresult")
                self.assertEqual(tokens[tokens.index("--log") + 1], "AcceptanceTest.log")
                self.assertNotIn("-disableDiagnosticWarnings", tokens)
                self.assertNotIn("-enableMainThreadChecker", tokens)
        self.assertEqual(configured, [("build", "Run acceptance UI workflows")])

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

    def test_interrupted_acceptance_retains_raw_evidence_before_readers(self):
        build = self.workflow()["jobs"]["build"]
        steps = build["steps"]
        named = {step.get("name"): step for step in steps}
        execution = named["Run acceptance UI workflows"]
        self.assertNotIn("-quiet", shlex.split(execution["run"]))
        self.assertIn("--log AcceptanceTest.log", execution["run"])
        self.assertEqual(len(acceptance.selected_tests()), 6)
        logs = named["Upload raw validation logs"]
        results = named["Upload raw validation results"]
        self.assertLess(steps.index(execution), steps.index(logs))
        self.assertLess(steps.index(logs), steps.index(results))
        for step, limit in [(logs, 1), (results, 2)]:
            # An explicit cancellation status check avoids GitHub's implicit success().
            self.assertEqual(step["if"], "failure() || cancelled()")
            self.assertEqual(step["timeout-minutes"], limit)
            self.assertEqual(step["with"]["retention-days"], 14)
            self.assertEqual(step["with"]["if-no-files-found"], "warn")
            self.assertNotIn("continue-on-error", step)
        self.assertIn("AcceptanceTest.log", logs["with"]["path"])
        self.assertNotIn("xcresult", logs["with"]["path"])
        self.assertIn("AcceptanceResults.xcresult", results["with"]["path"])
        self.assertEqual(results["with"]["compression-level"], 0)
        for name in ["Publish fast test summary", "Publish fast timing report",
                     "Publish acceptance test summary", "Publish acceptance timing report"]:
            self.assertLess(steps.index(results), steps.index(named[name]))
        fallback = named["Upload results after reporting failure"]
        self.assertEqual(fallback["if"], "(failure() || cancelled()) && steps.raw-results.outcome == 'skipped'")
        self.assertEqual(results["id"], "raw-results")
        self.assertEqual(fallback["with"]["name"], results["with"]["name"])
        self.assertEqual(fallback["timeout-minutes"], 2)
        self.assertEqual(fallback["with"]["compression-level"], 0)

    def test_cancelled_driver_command_keeps_progress_and_nonzero_verdict(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signum=signum):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    ready = root / "ready"
                    command = [sys.executable, "-c",
                               "import os,time; from pathlib import Path; "
                               "print('acceptance workflow started', flush=True); "
                               f"Path({str(ready)!r}).write_text(str(os.getpid())); time.sleep(60)"]
                    process = subprocess.Popen([
                        sys.executable, str(ROOT / ".github/scripts/test-timing.py"), "run",
                        "--phase", "test", "--phases", str(root / "phases.jsonl"),
                        "--log", str(root / "AcceptanceTest.log"), "--",
                        sys.executable, str(ROOT / ".github/scripts/with-system-text-size.py"), "--", *command
                    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                    try:
                        deadline = time.monotonic() + 5
                        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(ready.exists(), "Command must start before cancellation")
                        os.kill(process.pid, signum)
                        stdout, stderr = process.communicate(timeout=5)
                        self.assertEqual(process.returncode, 128 + signum, stderr)
                        self.assertIn(b"acceptance workflow started", stdout)
                        self.assertIn("acceptance workflow started", (root / "AcceptanceTest.log").read_text())
                        phase = json.loads((root / "phases.jsonl").read_text())
                        self.assertEqual(phase["exit_code"], 128 + signum)
                        self.assertEqual(phase["signal"], signum)
                    finally:
                        if ready.exists():
                            try:
                                os.killpg(int(ready.read_text()), signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        process.communicate(timeout=5)

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
