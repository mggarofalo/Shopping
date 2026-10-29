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
    names = ([f"CatalogActionTests/case{n}()" for n in range(17)]
             + [f"SpokenGrocerySchemaTests/case{n}()" for n in range(6)] + siri.UI_TESTS)
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

    def test_phases_share_build_and_device_without_retries_or_selection_overlap(self):
        commands = [siri.phase_command(DEVICE, Path("/evidence"), phase)
                    for phase in ("Build", "Hosted", "Native")]
        self.assertEqual([command[1] for command in commands],
                         ["build-for-testing", "test-without-building", "test-without-building"])
        selections = [{value for value in command if value.startswith("-only-testing:")}
                      for command in commands]
        self.assertEqual([len(values) for values in selections], [3, 2, 1])
        self.assertEqual(selections[0], selections[1] | selections[2])
        self.assertFalse(selections[1] & selections[2])
        for command in commands:
            self.assertEqual(command[command.index("-parallel-testing-enabled") + 1], "NO")
            self.assertEqual(command[command.index("-destination") + 1], f"platform=iOS Simulator,id={DEVICE}")
            self.assertEqual(command[command.index("-derivedDataPath") + 1], "/evidence/SiriDerivedData")
            self.assertFalse(any("retry" in value or "repetition" in value for value in command))

    def test_stage_inventories_reject_cross_stage_cases_and_skips(self):
        all_cases = inventory()["testNodes"]
        for phase, nodes in [("Hosted", all_cases[:-2]), ("Native", all_cases[-2:])]:
            siri.validate_phase({"testNodes": nodes}, phase)
            for altered in [nodes[:-1], nodes + [nodes[0]], all_cases,
                            [dict(node, result="Skipped") for node in nodes]]:
                with self.subTest(phase=phase), self.assertRaises(ValueError):
                    siri.validate_phase({"testNodes": altered}, phase)

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
            def run(self, name, command, timeout=20, *, supervised=False):
                calls.append((name, command))
                return 0
            def text(self, name):
                if name == "Create": return DEVICE
                if name in ("TestInventory", "HostedInventory", "NativeInventory"):
                    tree = inventory()
                    if name == "HostedInventory": tree["testNodes"] = tree["testNodes"][:-2]
                    if name == "NativeInventory": tree["testNodes"] = tree["testNodes"][-2:]
                    return json.dumps(tree)
                if name == "FinalDeviceState": return json.dumps({"devices": {"runtime": [{"udid": DEVICE, "state": state}]}})
                if name == "Container": return str(output / "absent-app")
                raise AssertionError(name)
        return FakeCommands, calls

    def test_failed_phase_stops_later_execution_and_preserves_original_status(self):
        for index in range(3):
            for code in [65, 130, 143]:
                with self.subTest(index=index, code=code), tempfile.TemporaryDirectory() as directory:
                    output = Path(directory)
                    fake, calls = self.fake_commands(output)
                    with patch.object(siri, "Commands", fake), \
                            patch.object(siri, "execute_test", side_effect=[0] * index + [code]) as execute, \
                            patch.object(siri, "prepare_runtime", return_value=0):
                        self.assertEqual(siri.run_tests(output), code)
                    self.assertEqual(execute.call_count, index + 1)
                    self.assertNotIn("MergeResults", [name for name, _ in calls])
                    verdict = json.loads((output / "SiriRegistration/Verdict.json").read_text())
                    self.assertEqual(verdict["test_exit_code"], code)
                    self.assertEqual(len(verdict["phases"]), index + 1)
                    # Cancellation starts no export after the cancelled phase.
                    if code in (130, 143):
                        self.assertNotIn(["unused", "HostedInventory", "NativeInventory"][index],
                                         [name for name, _ in calls])

    def test_failure_survives_export_failure_and_merge_failure_is_fatal(self):
        for execute_codes, failed_command, expected in [
                ([0, 65], "HostedInventory", 65), ([0, 0], "HostedInventory", 1),
                ([0, 0, 0], "MergeResults", 1), ([0, 0, 0], "TestInventory", 1)]:
            with self.subTest(failed_command=failed_command, expected=expected), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                fake, calls = self.fake_commands(output)
                original = fake.run
                def run(instance, name, command, timeout=20, *, supervised=False):
                    original(instance, name, command, timeout, supervised=supervised)
                    return 1 if name == failed_command else 0
                with patch.object(siri, "Commands", fake), patch.object(fake, "run", run), \
                        patch.object(siri, "execute_test", side_effect=execute_codes), \
                        patch.object(siri, "prepare_runtime", return_value=0):
                    self.assertEqual(siri.run_tests(output), expected)

    def test_cancelled_inventory_or_merge_stops_with_first_failure(self):
        for name in ("HostedInventory", "NativeInventory", "MergeResults", "TestInventory"):
            for cancelled in (130, 143):
                for prior in (0, 65) if name == "HostedInventory" else (0,):
                    with self.subTest(name=name, cancelled=cancelled, prior=prior), tempfile.TemporaryDirectory() as directory:
                        output = Path(directory)
                        fake, calls = self.fake_commands(output)
                        original = fake.run
                        def run(instance, current, command, timeout=20, *, supervised=False):
                            original(instance, current, command, timeout, supervised=supervised)
                            if current != "Create":
                                self.assertTrue(supervised, current)
                            return cancelled if current == name else 0
                        with patch.object(siri, "Commands", fake), patch.object(fake, "run", run), \
                                patch.object(siri, "execute_test", side_effect=[0, prior, 0]), \
                                patch.object(siri, "prepare_runtime", return_value=0):
                            self.assertEqual(siri.run_tests(output), prior or cancelled)
                        self.assertEqual(calls[-1][0], name)

    def test_supervised_export_and_merge_cancel_owned_process_group(self):
        for name in ("HostedInventory", "MergeResults"):
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(name=name, signum=signum), tempfile.TemporaryDirectory() as directory:
                    output = Path(directory)
                    ready, descendant = output / "ready", output / "descendant"
                    child = output / "child.py"
                    child.write_text("import os,signal,subprocess,sys,time\nfrom pathlib import Path\n"
                        "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                        "if len(sys.argv)>1:\n"
                        f" Path({str(descendant)!r}).write_text(str(os.getpid()))\n"
                        "else:\n subprocess.Popen([sys.executable,__file__,'child'])\n"
                        f" while not Path({str(descendant)!r}).exists(): time.sleep(0.01)\n"
                        f" Path({str(ready)!r}).write_text(str(os.getpid()))\n"
                        "while True: time.sleep(1)\n")
                    wrapper = output / "wrapper.py"
                    wrapper.write_text("import importlib.util,sys\nfrom pathlib import Path\n"
                        f"spec=importlib.util.spec_from_file_location('runner',{str(Path(siri.__file__))!r})\n"
                        "runner=importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)\n"
                        f"sys.exit(runner.Commands(Path({str(output)!r})).run({name!r},"
                        f"[sys.executable,{str(child)!r}],timeout=20,supervised=True))\n")
                    process = subprocess.Popen([sys.executable, str(wrapper)], start_new_session=True)
                    try:
                        deadline = time.monotonic() + 5
                        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(ready.exists())
                        os.kill(process.pid, signum)
                        self.assertEqual(process.wait(timeout=8), 128 + signum)
                        record = json.loads((output / f"{name}.json").read_text())
                        self.assertEqual(record["exit_code"], 128 + signum)
                        self.assertEqual(record["signal"], signum)
                        self.assertEqual(record["timeout_seconds"], 20)
                        for path in (ready, descendant):
                            deadline = time.monotonic() + 2
                            while True:
                                state = subprocess.run(["ps", "-o", "stat=", "-p", path.read_text()],
                                                       capture_output=True, text=True).stdout.strip()
                                if not state or state.startswith("Z"):
                                    break
                                self.assertLess(time.monotonic(), deadline, "Owned export/merge process survived")
                                time.sleep(0.01)
                    finally:
                        for pid in ([int(ready.read_text())] if ready.exists() else []) + [process.pid]:
                            try:
                                os.killpg(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        process.wait(timeout=5)

    def test_success_runs_three_sessions_and_observes_only_native_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            fake, calls = self.fake_commands(output)
            with patch.object(siri, "Commands", fake), \
                    patch.object(siri, "execute_test", return_value=0) as execute, \
                    patch.object(siri, "prepare_runtime", return_value=0):
                self.assertEqual(siri.run_tests(output, sampled=True), 0)
            self.assertEqual(execute.call_count, 3)
            self.assertEqual([call.args[2] is not None for call in execute.call_args_list], [False, False, True])
            self.assertEqual([name for name, _ in calls],
                             ["Create", "HostedInventory", "NativeInventory", "MergeResults", "TestInventory"])
            self.assertEqual(execute.call_args.args[1], output / "SiriSchema.log")
            verdict = json.loads((output / "SiriRegistration/Verdict.json").read_text())
            self.assertEqual([phase["exit_code"] for phase in verdict["phases"]], [0, 0, 0])

    def test_merged_inventory_must_match_executed_identifiers_not_only_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            fake, _ = self.fake_commands(output)
            original = fake.text
            def text(instance, name):
                tree = json.loads(original(instance, name)) if name == "TestInventory" else None
                if tree is None:
                    return original(instance, name)
                tree["testNodes"][0]["nodeIdentifier"] = "CatalogActionTests/differentCase()"
                return json.dumps(tree)
            with patch.object(siri, "Commands", fake), patch.object(fake, "text", text), \
                    patch.object(siri, "execute_test", return_value=0), \
                    patch.object(siri, "prepare_runtime", return_value=0):
                self.assertEqual(siri.run_tests(output), 1)
            self.assertIn("differs", (output / "SiriRegistration/TestInventoryFailure.txt").read_text())

    def test_runtime_readiness_is_scoped_and_precedes_simulator_ownership(self):
        for code in [0, 1, 124, 130, 143]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                fake, calls = self.fake_commands(output)
                def ready(command, path, *, timeout):
                    self.assertEqual(calls, [], "Readiness must precede simulator creation")
                    self.assertEqual(command, ["xcrun", "simctl", "runtime", "dyld_shared_cache",
                                               "update", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"])
                    self.assertEqual(timeout, 300)
                    self.assertEqual(path, output / "SiriRegistration/RuntimeReadiness.log")
                    return code
                with patch.object(siri, "Commands", fake), \
                        patch.object(siri, "execute_command", side_effect=ready), \
                        patch.object(siri, "execute_test", return_value=0) as test:
                    self.assertEqual(siri.run_tests(output), code)
                record = json.loads((output / "SiriRegistration/RuntimeReadiness.json").read_text())
                self.assertEqual(record["exit_code"], code)
                self.assertEqual(record["timeout_seconds"], 300)
                if code:
                    test.assert_not_called()
                    self.assertEqual(calls, [])
                    self.assertFalse((output / "SiriSimulatorID").exists())
                else:
                    self.assertEqual(test.call_count, 3)
                    self.assertEqual([name for name, _ in calls], ["Create", "HostedInventory", "NativeInventory", "MergeResults", "TestInventory"])

    def test_runtime_timeout_and_cancellation_clean_stubborn_process_group(self):
        for signum in [None, signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signum=signum), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                ready, descendant_ready = output / "ready", output / "descendant"
                descendant = ("import os,signal,time\nfrom pathlib import Path\n"
                    "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                    f"Path({str(descendant_ready)!r}).write_text(str(os.getpid()))\n"
                    "os.close(1); os.close(2)\nwhile True: time.sleep(1)\n")
                child = output / "child.py"
                child.write_text("import os,signal,subprocess,sys,time\nfrom pathlib import Path\n"
                    "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                    f"subprocess.Popen([sys.executable, '-c', {descendant!r}])\n"
                    f"while not Path({str(descendant_ready)!r}).exists(): time.sleep(0.01)\n"
                    "print('runtime preparation started', flush=True)\n"
                    f"Path({str(ready)!r}).write_text(str(os.getpid()))\n"
                    "os.close(1); os.close(2)\nwhile True: time.sleep(1)\n")
                wrapper = output / "wrapper.py"
                wrapper.write_text("import importlib.util,signal,sys\nfrom pathlib import Path\n"
                    f"spec=importlib.util.spec_from_file_location('runner', {str(Path(siri.__file__))!r})\n"
                    "runner=importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)\n"
                    "previous={sig:signal.getsignal(sig) for sig in (signal.SIGINT,signal.SIGTERM)}\n"
                    "execute=runner.execute_command\n"
                    f"runner.RUNTIME_READINESS_TIMEOUT_SECONDS={1.5 if signum is None else 300}\n"
                    f"runner.execute_command=lambda command,path,timeout: execute([sys.executable,{str(child)!r}],path,timeout=timeout)\n"
                    f"code=runner.prepare_runtime(Path({str(output)!r}))\n"
                    "assert all(signal.getsignal(sig)==handler for sig,handler in previous.items())\n"
                    "sys.exit(code)\n")
                process = subprocess.Popen([sys.executable, str(wrapper)], stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 5
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), "Both children must be ready before cancellation")
                    if signum is not None:
                        os.kill(process.pid, signum)
                    stdout, stderr = process.communicate(timeout=8)
                    expected = 124 if signum is None else 128 + signum
                    self.assertEqual(process.returncode, expected, stderr)
                    self.assertIn(b"runtime preparation started", stdout)
                    record = json.loads((output / "RuntimeReadiness.json").read_text())
                    self.assertEqual(record["exit_code"], expected)
                    self.assertGreater(record["wall_seconds"], 0)
                    if signum is None:
                        self.assertTrue(record["timed_out"])
                    else:
                        self.assertEqual(record["signal"], signum)
                    for path in [ready, descendant_ready]:
                        deadline = time.monotonic() + 2
                        while True:
                            state = subprocess.run(["ps", "-o", "stat=", "-p", path.read_text()],
                                                   capture_output=True, text=True).stdout.strip()
                            if not state or state.startswith("Z"):
                                break
                            self.assertLess(time.monotonic(), deadline, "Owned child remains alive")
                            time.sleep(0.01)
                finally:
                    for pid in ([int(ready.read_text())] if ready.exists() else []) + [process.pid]:
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.communicate(timeout=5)

    def test_unreapable_process_cannot_outlive_supervisor_deadline(self):
        for signum in [None, signal.SIGINT, signal.SIGTERM]:
            with self.subTest(signum=signum), tempfile.TemporaryDirectory() as directory, \
                    patch.object(siri.subprocess, "Popen") as popen, \
                    patch("selectors.DefaultSelector") as selector, \
                    patch.object(siri.os, "killpg", side_effect=PermissionError("signal denied")), \
                    patch.object(siri.time, "monotonic") as clock:
                now = [0]
                def tick():
                    now[0] += 1
                    self.assertLess(now[0], 40, "Supervisor failed to enforce its post-kill bound")
                    return now[0]
                clock.side_effect = tick
                process = popen.return_value
                process.poll.return_value = None
                process.wait.side_effect = subprocess.TimeoutExpired("unreapable", 0)
                selector.return_value.get_map.return_value = {}
                delivered = False
                def select(timeout):
                    nonlocal delivered
                    if signum is not None and not delivered:
                        delivered = True
                        signal.getsignal(signum)(signum, None)
                    return []
                selector.return_value.select.side_effect = select
                previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
                code = siri.execute_command(["fake"], Path(directory) / "command.log",
                                             timeout=1 if signum is None else 300)
                self.assertEqual(code, 124 if signum is None else 128 + signum)
                self.assertTrue(all(0 <= call.kwargs["timeout"] <= 5 for call in process.wait.call_args_list))
                self.assertEqual({sig: signal.getsignal(sig) for sig in previous}, previous)

    def test_streaming_observation_retains_output_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "SiriRegistration").mkdir()
            captured = []
            class ImmediateObserver(siri.LaunchObserver):
                def __init__(self, capture, **kwargs):
                    super().__init__(capture, delay=0, **kwargs)
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
            with patch.object(siri, "Commands", fake), patch.object(fake, "text", text), patch.object(siri, "execute_test", return_value=0), patch.object(siri, "prepare_runtime", return_value=0):
                self.assertEqual(siri.run_tests(output), 1)
            self.assertTrue((output / "SiriRegistration/TestInventoryFailure.txt").exists())

    def test_sampling_command_failure_preserves_native_failure(self):
        class ImmediateObserver(siri.LaunchObserver):
            def __init__(self, capture, **kwargs):
                super().__init__(capture, delay=0, **kwargs)
        for failed_command in ["Processes", "xcodebuild"]:
            with self.subTest(failed_command=failed_command), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                (output / "SiriRegistration").mkdir()
                commands = []
                def run(instance, name, command, timeout=20, *, supervised=False):
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
