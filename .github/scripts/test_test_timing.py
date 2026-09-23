"""Portable reporting and exit-status regression tests; no simulator required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("test-timing.py")
spec = importlib.util.spec_from_file_location("timing", SCRIPT)
timing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timing)


class TimingTests(unittest.TestCase):
    def test_xcode16_formatted_duration(self):
        self.assertEqual(timing.duration_seconds({"duration": "1h 2m 3.5s"}), 3723.5)
        self.assertEqual(timing.duration_seconds({"duration": "250ms"}), .25)
        self.assertIsNone(timing.duration_seconds({}))

    def test_exact_duration_preferred_in_newer_xcode(self):
        self.assertEqual(timing.duration_seconds({"duration": "1s", "durationInSeconds": 1.234}), 1.234)
        self.assertEqual(timing.duration_seconds({"durationInSeconds": 0}), 0)

    def test_test_case_children_are_not_double_counted(self):
        tree = {"testNodes": [{"nodeType": "UI test bundle", "name": "UI", "children": [
            {"nodeType": "Test Suite", "name": "Recovery", "children": [
                {"nodeType": "Test Case", "name": "testRelaunch()", "nodeIdentifier": "Recovery/testRelaunch()",
                 "duration": "12s", "result": "Failed", "children": [
                     {"nodeType": "Test Case Run", "name": "Run 1", "duration": "12s"}]}]}]}]}
        tests = timing.collect_tests(tree)
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0]["suite"], "Recovery")
        self.assertEqual(tests[0]["result"], "Failed")
        self.assertEqual(tests[0]["duration_seconds"], 12)

    def run_command(self, directory, command):
        phases = Path(directory) / "phases.jsonl"
        log = Path(directory) / "command.log"
        result = subprocess.run([sys.executable, str(SCRIPT), "run", "--phase", "test",
                                 "--phases", str(phases), "--log", str(log), "--", *command],
                                capture_output=True)
        return result, json.loads(phases.read_text()), log.read_text()

    def test_failure_status_and_logs_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result, phase, log = self.run_command(directory, [sys.executable, "-c", "print('failed'); raise SystemExit(65)"])
            self.assertEqual(result.returncode, 65)
            self.assertEqual(phase["exit_code"], 65)
            self.assertGreater(phase["wall_seconds"], 0)
            self.assertEqual(log, "failed\n")
            self.assertEqual(phase["log_path"], str((Path(directory) / "command.log").resolve()))
            self.assertEqual(result.stdout, b"failed\n")
            self.assertNotIn("command", phase)

    def test_child_signal_status_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            result, phase, _ = self.run_command(directory, [sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"])
            self.assertEqual(result.returncode, 128 + signal.SIGTERM)
            self.assertEqual(phase["exit_code"], 128 + signal.SIGTERM)

    def test_missing_command_records_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            result, phase, _ = self.run_command(directory, ["/nonexistent/shopping-command"])
            self.assertEqual(result.returncode, 127)
            self.assertEqual(phase["exit_code"], 127)

    def test_missing_result_still_reports_failed_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / "phases.jsonl").write_text('{"phase":"build","wall_seconds":3.1,"exit_code":65}\n{"partial":')
            args = argparse.Namespace(plan="ShoppingFull", result=str(base / "missing.xcresult"),
                                      phases=str(base / "phases.jsonl"), json=str(base / "report.json"),
                                      markdown=str(base / "report.md"), metadata=None)
            with patch.object(timing, "output_of", return_value=None):
                self.assertEqual(timing.make_report(args), 0)
            report = json.loads((base / "report.json").read_text())
            self.assertEqual(report["phases"][0]["exit_code"], 65)
            self.assertEqual(report["result"], "No test result bundle")
            self.assertEqual(report["result_bundle_path"], str((base / "missing.xcresult").resolve()))
            self.assertEqual(len(report["warnings"]), 3)
            self.assertIn("| build | 3.100 | 65 |", (base / "report.md").read_text())

    def test_missing_metadata_file_warns_about_reporting_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            args = argparse.Namespace(plan="ShoppingFull", result=str(base / "missing.xcresult"),
                                      phases=str(base / "missing.jsonl"), json=str(base / "report.json"),
                                      markdown=str(base / "report.md"), metadata=str(base / "missing-metadata.json"))
            with patch.object(timing, "output_of", return_value=None):
                self.assertEqual(timing.make_report(args), 0)
            report = json.loads((base / "report.json").read_text())
            self.assertTrue(any("metadata captured at report time" in warning for warning in report["warnings"]))

    def test_saved_metadata_survives_generated_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            metadata = {"commit_sha": "abc", "dirty": False, "plan": "ShoppingFull", "xcode": "Xcode 16.4", "host": "macOS"}
            (base / "metadata.json").write_text(json.dumps(metadata))
            args = argparse.Namespace(plan="ShoppingFull", result=str(base / "missing.xcresult"),
                                      phases=str(base / "missing.jsonl"), json=str(base / "report.json"),
                                      markdown=str(base / "report.md"), metadata=str(base / "metadata.json"))
            timing.make_report(args)
            report = json.loads((base / "report.json").read_text())
            self.assertFalse(report["metadata"]["dirty"])
            self.assertEqual(report["metadata"]["commit_sha"], "abc")


class LocalGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        scripts = self.root / ".github/scripts"
        scripts.mkdir(parents=True)
        for name in ("test-timing.py", "run-local-shopping-full.sh", "summarize-xcresult.sh"):
            shutil.copy2(SCRIPT.with_name(name), scripts / name)
        (self.root / "source.txt").write_text("original\n")
        for args in (("init", "-q"), ("add", "."), ("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "fixture")):
            subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)
        self.sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        self.fakebin = Path(self.temporary.name) / "bin"
        self.fakebin.mkdir()
        self.tool("xcodebuild", """#!/bin/bash
if [[ "$1" == -version ]]; then echo 'Xcode fixture'; exit 0; fi
if [[ "$1" == test-without-building ]]; then
    if [[ "${CHANGE_SOURCE:-0}" == 1 ]]; then echo changed >> "$ORIGINAL_ROOT/source.txt"; fi
    exit "${TEST_EXIT:-0}"
fi
exit 0
""")
        self.tool("xcrun", "#!/bin/bash\nexit 0\n")
        self.environment = dict(os.environ, PATH=str(self.fakebin) + os.pathsep + os.environ["PATH"],
                                TMPDIR=self.temporary.name, ORIGINAL_ROOT=str(self.root))

    def tool(self, name, text):
        path = self.fakebin / name
        path.write_text(text)
        path.chmod(0o755)

    def run_local(self, **environment):
        return subprocess.run([str(self.root / ".github/scripts/run-local-shopping-full.sh")],
                              cwd=self.root, env=dict(self.environment, **environment), capture_output=True, text=True)

    def attestation(self):
        return self.root / ".git/shopping-full-attestations" / self.sha

    def test_success_records_exact_sha_and_timing(self):
        result = self.run_local()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.attestation().read_text()
        self.assertIn("sha=" + self.sha, text)
        report_path = text.split("timing_report=", 1)[1].strip()
        self.assertTrue(Path(report_path).is_absolute())
        self.assertEqual(Path(report_path).parent.parent.resolve(), (self.root / ".git/shopping-test-timings" / self.sha).resolve())
        self.assertEqual({path.name for path in Path(report_path).parent.iterdir()},
                         {"Timing.json", "Timing.md", "Metadata.json", "Phases.jsonl", "Summary.json", "Summary.md"})
        self.assertEqual(subprocess.check_output(["git", "status", "--porcelain"], cwd=self.root, text=True), "")
        report = json.loads(Path(report_path).read_text())
        self.assertEqual(report["metadata"]["commit_sha"], self.sha)
        self.assertFalse(report["metadata"]["dirty"])
        self.assertEqual([phase["phase"] for phase in report["phases"]],
                         ["snapshot", "simulator", "build", "test", "summary"])
        self.assertEqual(report["phases"][3]["command"][:2], ["xcodebuild", "test-without-building"])

    def test_failed_test_never_attests_and_retains_report(self):
        result = self.run_local(TEST_EXIT="65")
        self.assertEqual(result.returncode, 65)
        self.assertFalse(self.attestation().exists())
        history_path = result.stdout.split("ShoppingFull timing history: ", 1)[1].splitlines()[0]
        artifact_path = result.stdout.split("ShoppingFull temporary artifacts: ", 1)[1].splitlines()[0]
        self.assertTrue((Path(artifact_path) / "Test.log").exists())
        self.assertFalse((Path(history_path) / "Test.log").exists())
        report = json.loads((Path(history_path) / "Timing.json").read_text())
        self.assertEqual(report["phases"][-2]["exit_code"], 65)
        self.assertEqual(report["phases"][-2]["log_path"], str((Path(artifact_path) / "Test.log").resolve()))
        self.assertEqual(report["result_bundle_path"], str((Path(artifact_path) / "Results.xcresult").resolve()))

    def test_repeated_runs_keep_distinct_pass_and_failure_history(self):
        first = self.run_local()
        second = self.run_local(TEST_EXIT="65")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 65, second.stderr)
        histories = list((self.root / ".git/shopping-test-timings" / self.sha).iterdir())
        self.assertEqual(len(histories), 2)
        reports = [json.loads((path / "Timing.json").read_text()) for path in histories]
        self.assertEqual(sorted(report["phases"][-2]["exit_code"] for report in reports), [0, 65])

    def test_source_change_during_test_never_attests(self):
        result = self.run_local(CHANGE_SOURCE="1")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.attestation().exists())
        self.assertIn("HEAD or the worktree changed", result.stderr)

    def test_dirty_source_refused_before_execution(self):
        (self.root / "source.txt").write_text("dirty\n")
        result = self.run_local()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.attestation().exists())
        self.assertIn("clean worktree", result.stderr)


if __name__ == "__main__":
    unittest.main()
