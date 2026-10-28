import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("siri_ci", Path(__file__).with_name("siri-schema-ci.py"))
siri = importlib.util.module_from_spec(spec)
spec.loader.exec_module(siri)
DEVICE = "C173A9C4-C7AD-42FE-9B90-932ACB424D13"


def inventory():
    names = ([f"CatalogActionTests/case{n}()" for n in range(15)]
             + [f"SpokenGrocerySchemaTests/case{n}()" for n in range(6)] + [siri.UI_TEST])
    return {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"} for name in names]}


class SiriSchemaCITests(unittest.TestCase):
    def test_diagnostic_mode_cannot_supply_required_checks(self):
        workflow = json.loads(subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))",
            str(Path(__file__).resolve().parents[1] / "workflows/swift-ci.yml")]))
        jobs = workflow["jobs"]
        expected = "${{ github.event_name != 'workflow_dispatch' || !inputs.siri_launch_diagnostic }}"
        for name in ["build", "release-build"]:
            self.assertEqual(jobs[name]["if"], expected)
        diagnostic = jobs["siri-launch-diagnostic"]
        self.assertEqual(diagnostic["if"], "${{ github.event_name == 'workflow_dispatch' && inputs.siri_launch_diagnostic }}")
        self.assertNotIn(diagnostic["name"], ["Build & Test", "Release SDK Build"])
        commands = [step.get("run", "") for step in diagnostic["steps"]]
        self.assertEqual(sum("--sample-launch" in command for command in commands), 1)
        self.assertFalse(any(step.get("continue-on-error") for step in diagnostic["steps"]))

    def test_exact_passing_inventory_is_required(self):
        siri.validate_selection(inventory())
        for kind in ("missing", "extra", "duplicate", "skipped", "failed", "wrong_ui"):
            tree = inventory()
            cases = tree["testNodes"]
            if kind == "missing": cases.pop()
            if kind == "extra": cases.append(dict(cases[0]))
            if kind == "duplicate": cases[0] = dict(cases[1])
            if kind == "skipped": cases[0]["result"] = "Skipped"
            if kind == "failed": cases[0]["result"] = "Failed"
            if kind == "wrong_ui": cases[-1]["nodeIdentifier"] = "ModernSiriActionTests/other()"
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                siri.validate_selection(tree)

    def test_test_command_preserves_selection_and_no_retries(self):
        command = siri.test_command(DEVICE, Path("/evidence"))
        self.assertEqual(command[:2], ["xcodebuild", "test"])
        self.assertEqual(sum(value.startswith("-only-testing:") for value in command), 3)
        self.assertIn("-only-testing:ShoppingSiriTests/" + siri.UI_TEST.removesuffix("()"), command)
        self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")
        self.assertFalse(any("retry" in value or "repetition" in value for value in command))

    def test_slow_launch_samples_once_before_native_timeout(self):
        now = [100.0]
        called = threading.Event()
        observer = siri.LaunchObserver(called.set, clock=lambda: now[0])
        observer.line("    t =     0.90s     Launch com.mggarofalo.shopping")
        now[0] = 119.9
        observer.tick()
        self.assertFalse(called.is_set())
        now[0] = 120.0
        observer.tick()
        self.assertTrue(called.wait(timeout=1))
        first = observer.thread
        observer.tick()
        self.assertIs(observer.thread, first)
        observer.thread.join()

    def test_quick_launch_and_unrelated_log_do_not_trigger_samples(self):
        for completion in ["Setting up automation session", "Wait for com.mggarofalo.shopping to idle", "Tear Down"]:
            now = [0.0]
            observer = siri.LaunchObserver(lambda: self.fail("unexpected sample"), clock=lambda: now[0])
            observer.line("launch some unrelated app")
            now[0] = 100
            observer.tick()
            self.assertIsNone(observer.thread)
            observer.line("t = 1.00s Launch com.mggarofalo.shopping")
            observer.line("t = 2.00s " + completion)
            now[0] = 200
            observer.tick()
            self.assertIsNone(observer.thread)

    def test_process_selection_excludes_other_apps_and_ambiguous_services(self):
        text = f"""PID PPID COMM
1 0 /usr/bin/launchservicesd
2 0 /host/com.apple.CoreSimulator.CoreSimulatorService
3 0 /runtime/CoreSimulatorBridge
4 0 /other-runtime/CoreSimulatorBridge
5 0 /Devices/{DEVICE}/data/Shopping.app/Shopping
6 0 /Devices/OTHER/data/Shopping.app/Shopping
7 0 /host/unrelated
"""
        self.assertEqual(siri.selected_processes(text, DEVICE, 99), {
            "xcodebuild": 99, "com.apple.CoreSimulator.CoreSimulatorService": 2,
            "launchservicesd": 1, "Shopping": 5})

    def fake_commands(self, output, state="Shutdown"):
        calls = []
        class FakeCommands:
            def __init__(self, directory):
                self.output = Path(directory)
                self.output.mkdir(parents=True, exist_ok=True)
            def run(self, name, command, timeout=20):
                calls.append((name, command))
                return 0
            def text(self, name):
                if name == "Create": return DEVICE
                if name == "TestInventory": return json.dumps(inventory())
                if name == "FinalDeviceState": return json.dumps({"devices": {"runtime": [{"udid": DEVICE, "state": state}]}})
                if name == "Container": return str(output / "absent-app")
                raise AssertionError(name)
        return FakeCommands, calls

    def test_failed_test_exit_survives_a_passing_exported_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            fake, calls = self.fake_commands(output)
            with patch.object(siri, "Commands", fake), patch.object(siri, "execute_test", return_value=65):
                self.assertEqual(siri.run_tests(output), 65)
            self.assertEqual([name for name, _ in calls], ["Create", "TestInventory"])
            self.assertEqual(json.loads((output / "SiriRegistration/Verdict.json").read_text())["test_exit_code"], 65)

    def test_streaming_observation_retains_output_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "SiriRegistration").mkdir()
            captured = []
            class ImmediateObserver(siri.LaunchObserver):
                def __init__(self, capture):
                    super().__init__(capture, delay=0)
            command = [sys.executable, "-c", "import sys; print('t = 1.00s Launch com.mggarofalo.shopping', flush=True); sys.exit(65)"]
            with patch.object(siri, "LaunchObserver", ImmediateObserver):
                self.assertEqual(siri.execute_test(command, output / "SiriSchema.log", sample=captured.append), 65)
            self.assertEqual(len(captured), 1)
            self.assertIn("Launch com.mggarofalo.shopping", (output / "SiriSchema.log").read_text())
            self.assertTrue(json.loads((output / "SiriRegistration/LaunchObservation.json").read_text())["sample_started"])

    def test_zero_test_exit_with_incomplete_inventory_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            fake, _ = self.fake_commands(output)
            original = fake.text
            def text(instance, name):
                return "{}" if name == "TestInventory" else original(instance, name)
            with patch.object(siri, "Commands", fake), patch.object(fake, "text", text), patch.object(siri, "execute_test", return_value=0):
                self.assertEqual(siri.run_tests(output), 1)
            self.assertTrue((output / "SiriRegistration/ManifestFailure.txt").exists())

    def test_postrun_capture_observes_without_booting_shutdown_device(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "SiriSimulatorID").write_text(DEVICE)
            fake, calls = self.fake_commands(output)
            with patch.object(siri, "Commands", fake):
                siri.capture(output)
            self.assertEqual([name for name, _ in calls], ["FinalDeviceState", "Shutdown", "Delete"])
            self.assertTrue((output / "SiriRegistration/LiveCaptureSkipped.txt").exists())
            self.assertFalse(any("bootstatus" in command or "boot" in command for _, command in calls))

    def test_booted_device_capture_precedes_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "SiriSimulatorID").write_text(DEVICE)
            fake, calls = self.fake_commands(output, state="Booted")
            with patch.object(siri, "Commands", fake):
                siri.capture(output)
            self.assertEqual([name for name, _ in calls], ["FinalDeviceState", "System", "Container", "Shutdown", "Delete"])
            self.assertEqual(calls[-1][1], ["xcrun", "simctl", "delete", DEVICE])


if __name__ == "__main__":
    unittest.main()
