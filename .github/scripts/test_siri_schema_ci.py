import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
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
    def test_required_sampling_and_diagnostic_checks_remain_separate(self):
        workflow = json.loads(subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))",
            str(Path(__file__).resolve().parents[1] / "workflows/swift-ci.yml")]))
        jobs = workflow["jobs"]
        expected = "${{ github.event_name != 'workflow_dispatch' || (!inputs.siri_launch_diagnostic && !inputs.compatibility_canary) }}"
        for name in ["build", "release-build"]:
            self.assertEqual(jobs[name]["if"], expected)
        diagnostic = jobs["siri-launch-diagnostic"]
        self.assertEqual(diagnostic["if"], "${{ github.event_name == 'workflow_dispatch' && inputs.siri_launch_diagnostic }}")
        self.assertNotIn(diagnostic["name"], ["Build & Test", "Release SDK Build"])
        commands = [step.get("run", "") for step in diagnostic["steps"]]
        self.assertEqual(sum("--sample-launch" in command for command in commands), 1)
        self.assertFalse(any(step.get("continue-on-error") for step in diagnostic["steps"]))
        release_steps = jobs["release-build"]["steps"]
        sampled = [step for step in release_steps if "--sample-launch" in step.get("run", "")]
        self.assertEqual(len(sampled), 1)
        self.assertIn("siri-schema-ci.py test", sampled[0]["run"])
        self.assertFalse(sampled[0].get("continue-on-error"))
        self.assertFalse(jobs["release-build"].get("continue-on-error"))
        validation = next(i for i, step in enumerate(release_steps)
                          if "test_siri_schema_ci.py" in step.get("run", ""))
        archive = next(i for i, step in enumerate(release_steps)
                       if "xcodebuild archive" in step.get("run", ""))
        self.assertLess(validation, archive)

    def test_parent_exit_bounds_inherited_pipe_drain_and_cleans_group(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            ready = output / "descendant-ready"
            descendant = ("import os, signal, time\nfrom pathlib import Path\n"
                          "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                          f"Path({str(ready)!r}).write_text(str(os.getpid()))\n"
                          "print('descendant output', flush=True)\n"
                          "while True: time.sleep(1)\n")
            parent = output / "parent.py"
            parent.write_text("import os, subprocess, sys, time\nfrom pathlib import Path\n"
                              f"Path({str(output / 'group')!r}).write_text(str(os.getpid()))\n"
                              f"subprocess.Popen([sys.executable, '-c', {descendant!r}])\n"
                              f"while not Path({str(ready)!r}).exists(): time.sleep(0.01)\n"
                              "sys.exit(65)\n")
            wrapper = output / "wrapper.py"
            wrapper.write_text("import importlib.util, sys\nfrom pathlib import Path\n"
                               f"spec=importlib.util.spec_from_file_location('runner', {str(Path(siri.__file__))!r})\n"
                               "runner=importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)\n"
                               f"sys.exit(runner.execute_test([sys.executable, {str(parent)!r}], Path({str(output / 'test.log')!r})))\n")
            process = subprocess.Popen([sys.executable, str(wrapper)], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 65, stderr)
                self.assertIn("descendant output", stdout)
                self.assertIn("descendant output", (output / "test.log").read_text())
                pid = int(ready.read_text())
                deadline = time.monotonic() + 2
                while True:
                    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                           capture_output=True, text=True).stdout.strip()
                    if not state or state.startswith("Z"):
                        break
                    self.assertLess(time.monotonic(), deadline, "Inherited-pipe descendant remains alive")
                    time.sleep(0.01)
            finally:
                groups = [process.pid]
                if (output / "group").exists():
                    groups.append(int((output / "group").read_text()))
                for pid in groups:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.communicate(timeout=5)

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

    def test_sampling_command_failure_preserves_native_failure(self):
        class ImmediateObserver(siri.LaunchObserver):
            def __init__(self, capture):
                super().__init__(capture, delay=0)
        for failed_command in ["Processes", "xcodebuild"]:
            with self.subTest(failed_command=failed_command), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                (output / "SiriRegistration").mkdir()
                commands = []
                def run(instance, name, command, timeout=20):
                    commands.append(name)
                    return 124 if name == failed_command else 0
                command = [sys.executable, "-c", "import sys; print('t = 1.00s Launch com.mggarofalo.shopping', flush=True); sys.exit(65)"]
                with patch.object(siri, "LaunchObserver", ImmediateObserver), \
                        patch.object(siri.Commands, "run", run), \
                        patch.object(siri.Commands, "text", return_value="PID PPID COMM\n"):
                    code = siri.execute_test(command, output / "SiriSchema.log",
                                             sample=lambda pid: siri.sample_launch(output / "SiriRegistration", DEVICE, pid))
                self.assertEqual(code, 65)
                self.assertIn(failed_command, commands)
                self.assertTrue(json.loads((output / "SiriRegistration/LaunchObservation.json").read_text())["sample_started"])

    def test_cancel_after_stdout_eof_kills_stubborn_child_and_restores_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            ready = output / "child-ready"
            child = output / "child.py"
            child.write_text("import os, signal, time\nfrom pathlib import Path\n"
                             "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                             "os.close(1); os.close(2)\n"
                             f"Path({str(ready)!r}).write_text(str(os.getpid()))\n"
                             "while True: time.sleep(1)\n")
            wrapper = output / "wrapper.py"
            wrapper.write_text("import importlib.util, json, signal, sys\nfrom pathlib import Path\n"
                               f"spec=importlib.util.spec_from_file_location('runner', {str(Path(siri.__file__))!r})\n"
                               "runner=importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)\n"
                               "def previous(signum, frame): pass\n"
                               "signal.signal(signal.SIGTERM, previous)\n"
                               f"code=runner.execute_test([sys.executable, {str(child)!r}], Path({str(output / 'test.log')!r}))\n"
                               "print(json.dumps({'code': code, 'restored': signal.getsignal(signal.SIGTERM) is previous}), flush=True)\n"
                               "sys.exit(code)\n")
            process = subprocess.Popen([sys.executable, str(wrapper)], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "Child must close output and install its TERM handler before cancellation")
                os.kill(process.pid, signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=8)
                self.assertEqual(process.returncode, 143, stderr)
                self.assertEqual(json.loads(stdout), {"code": 143, "restored": True})
            finally:
                # Retain bounded cleanup even when this regression is run against
                # the old implementation that waits forever after pipe EOF.
                for pid in ([int(ready.read_text())] if ready.exists() else []) + [process.pid]:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.communicate(timeout=5)

    def test_cleanup_exit_race_does_not_replace_original_error(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(siri.subprocess, "Popen") as popen, \
                patch("selectors.DefaultSelector") as selector, \
                patch.object(siri.os, "killpg", side_effect=ProcessLookupError):
            process = popen.return_value
            process.poll.return_value = None
            process.wait.return_value = -signal.SIGKILL
            selector.return_value.get_map.return_value = {1: "open"}
            selector.return_value.select.side_effect = RuntimeError("original stream failure")
            previous = signal.getsignal(signal.SIGTERM)
            with self.assertRaisesRegex(RuntimeError, "original stream failure"):
                siri.execute_test(["fake-command"], Path(directory) / "test.log")
            self.assertIs(signal.getsignal(signal.SIGTERM), previous)

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
