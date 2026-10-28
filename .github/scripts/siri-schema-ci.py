#!/usr/bin/env python3
"""Run the existing Siri schema selection and retain bounded lifecycle evidence."""
import argparse
from collections import Counter
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid

RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
RUNTIME_READINESS_TIMEOUT_SECONDS = 300

UI_TEST = "ModernSiriActionTests/testModernSiriActionReturnsSavedEntityThroughSystemExecution()"
LAUNCH_MARKER = re.compile(r"t =\s+[0-9.]+s\s+Launch com\.mggarofalo\.shopping\s*$")
LAUNCH_COMPLETE = re.compile(r"t =\s+[0-9.]+s\s+(Setting up automation session|Wait for com\.mggarofalo\.shopping to idle|Tear Down)")


def cases(tree):
    if isinstance(tree, dict):
        if tree.get("nodeType") == "Test Case":
            yield tree
        else:
            for value in tree.values():
                yield from cases(value)
    elif isinstance(tree, list):
        for value in tree:
            yield from cases(value)


def validate_selection(tree):
    selected = list(cases(tree))
    identifiers = [test["nodeIdentifier"] for test in selected]
    counts = Counter(identifier.split("/")[0] for identifier in identifiers)
    if (len(selected) != 22 or len(set(identifiers)) != 22
            or counts != {"CatalogActionTests": 15, "SpokenGrocerySchemaTests": 6, "ModernSiriActionTests": 1}
            or UI_TEST not in identifiers or any(test.get("result") != "Passed" for test in selected)):
        raise ValueError("Siri schema selection must contain exactly 22 unique passing cases (15 catalog, 6 schema, 1 native UI)")


class Commands:
    def __init__(self, output):
        self.output = Path(output)
        self.output.mkdir(parents=True, exist_ok=True)

    def run(self, name, command, timeout=20, *, supervised=False):
        started = time.monotonic()
        record = {"command": command, "timeout_seconds": timeout,
                  "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        if supervised:
            # Validation commands run on the main thread and share the test
            # process-group supervisor. Sampling calls run on a worker thread,
            # where signal handlers cannot be installed, and retain their bound.
            try:
                record["exit_code"] = execute_command(command, self.output / f"{name}.log", timeout=timeout)
                if record["exit_code"] == 124:
                    record["timed_out"] = True
                elif record["exit_code"] in (130, 143):
                    record["signal"] = record["exit_code"] - 128
            except (OSError, subprocess.SubprocessError) as error:
                record.update(exit_code=1, error=str(error))
        else:
            with (self.output / f"{name}.log").open("wb") as log:
                try:
                    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                    try:
                        code = process.wait(timeout=timeout)
                        record["exit_code"] = code if code >= 0 else 128 - code
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                        record.update(exit_code=124, timed_out=True)
                except (OSError, subprocess.SubprocessError) as error:
                    record.update(exit_code=1, error=str(error))
        record["wall_seconds"] = round(time.monotonic() - started, 6)
        (self.output / f"{name}.json").write_text(json.dumps(record, indent=2) + "\n")
        return record["exit_code"]

    def text(self, name):
        return (self.output / f"{name}.log").read_text(errors="replace")


def selected_processes(text, device, xcode_pid):
    targets = {"xcodebuild": xcode_pid}
    rows = []
    for line in text.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0].isdigit():
            rows.append((int(fields[0]), fields[2]))
    for name in ("com.apple.CoreSimulator.CoreSimulatorService", "CoreSimulatorBridge", "launchservicesd", "Shopping"):
        matches = [pid for pid, path in rows if Path(path).name == name
                   and (name != "Shopping" or f"/{device}/" in path)]
        if len(matches) == 1:
            targets[name] = matches[0]
    return targets


def sample_launch(output, device, xcode_pid):
    commands = Commands(Path(output) / "LaunchSample")
    commands.run("DeviceState", ["xcrun", "simctl", "list", "devices", "--json"], timeout=5)
    if commands.run("Processes", ["ps", "-axo", "pid,ppid,comm"], timeout=5) != 0:
        return
    targets = selected_processes(commands.text("Processes"), device, xcode_pid)
    (commands.output / "Targets.json").write_text(json.dumps(targets, indent=2) + "\n")
    for name, pid in targets.items():
        commands.run(name, ["sample", str(pid), "1", "-file", str(commands.output / f"{name}.sample.txt")], timeout=5)


class LaunchObserver:
    def __init__(self, capture, clock=time.monotonic, delay=20, output=None):
        self.capture, self.clock, self.delay = capture, clock, delay
        self.output = output
        self.started = None
        self.observed_at = None
        self.finished = False
        self.thread = None

    def line(self, line):
        if self.started is None and LAUNCH_MARKER.search(line):
            self.started = self.clock()
            self.observed_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
        elif self.started is not None and LAUNCH_COMPLETE.search(line):
            self.finished = True

    def tick(self):
        if (self.started is not None and not self.finished and self.thread is None
                and self.clock() - self.started >= self.delay):
            self.thread = threading.Thread(target=self.capture, name="SiriLaunchEvidence")
            self.thread.start()

    def close(self):
        if self.thread:
            self.thread.join()
        if self.output:
            self.output.write_text(json.dumps({
                "launch_observed_at": self.observed_at, "sample_delay_seconds": self.delay,
                "launch_finished_observed": self.finished, "sample_started": self.thread is not None,
            }, indent=2) + "\n")


HOSTED_FILTERS = ["ShoppingPersistenceTests/SpokenGrocerySchemaTests",
                  "ShoppingPersistenceTests/CatalogActionTests"]
NATIVE_FILTERS = ["ShoppingSiriTests/" + UI_TEST.removesuffix("()")]


def phase_command(device, output, phase):
    """Build once; execute disjoint selections with a new IDE session each time."""
    action = "build-for-testing" if phase == "Build" else "test-without-building"
    filters = HOSTED_FILTERS + NATIVE_FILTERS if phase == "Build" else (
        HOSTED_FILTERS if phase == "Hosted" else NATIVE_FILTERS)
    return ["xcodebuild", action, "-project", "Shopping.xcodeproj", "-scheme", "ShoppingSiri",
            "-testPlan", "ShoppingSiri", "-collect-test-diagnostics", "never",
            "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
            "-derivedDataPath", str(output / "SiriDerivedData"),
            *["-only-testing:" + value for value in filters],
            "-resultBundlePath", str(output / "SiriRegistration" / f"{phase}.xcresult")]


def validate_phase(tree, phase):
    selected = list(cases(tree))
    identifiers = [test["nodeIdentifier"] for test in selected]
    expected = ({"CatalogActionTests": 15, "SpokenGrocerySchemaTests": 6}
                if phase == "Hosted" else {"ModernSiriActionTests": 1})
    if (Counter(value.split("/")[0] for value in identifiers) != expected
            or len(set(identifiers)) != len(identifiers)
            or (phase == "Native" and identifiers != [UI_TEST])
            or any(test.get("result") != "Passed" for test in selected)):
        raise ValueError(f"{phase} Siri selection must contain exactly its unique passing cases: {expected}")


def export_inventory(commands, bundle, name, validate):
    try:
        code = commands.run(name, ["xcrun", "xcresulttool", "get", "test-results", "tests",
                                   "--path", str(bundle), "--format", "json"], supervised=True)
        if code:
            return code
        validate(json.loads(commands.text(name)))
    except (KeyError, ValueError, TypeError, OSError, subprocess.SubprocessError) as error:
        (commands.output / f"{name}Failure.txt").write_text(str(error) + "\n")
        return 1
    return 0


def run_phases(device, output, commands, sampled):
    """Preserve the first failure and raw results even if export or merging fails."""
    verdict = {"phases": [], "test_exit_code": 0, "manifest_exit_code": 0}
    try:
        for phase in ("Build", "Hosted", "Native"):
            command = phase_command(device, output, phase)
            log = output / "SiriSchema.log" if phase == "Native" else commands.output / f"{phase}.log"
            sample = (lambda pid: sample_launch(commands.output, device, pid)) if sampled and phase == "Native" else None
            started = time.monotonic()
            record = {"phase": phase, "command": command,
                      "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
            verdict["phases"].append(record)
            code = execute_test(command, log, sample)
            record.update(exit_code=code, wall_seconds=round(time.monotonic() - started, 6))
            verdict["test_exit_code"] = code
            # Do not start another command after supervised cancellation.
            if code in (130, 143):
                return code
            if phase != "Build":
                verdict["manifest_exit_code"] = export_inventory(
                    commands, commands.output / f"{phase}.xcresult", f"{phase}Inventory",
                    lambda tree: validate_phase(tree, phase))
            if code or verdict["manifest_exit_code"]:
                return code or verdict["manifest_exit_code"]
        merge_code = commands.run("MergeResults", ["xcrun", "xcresulttool", "merge", "--output-path",
            str(output / "SiriSchema.xcresult"), str(commands.output / "Hosted.xcresult"),
            str(commands.output / "Native.xcresult")], supervised=True)
        verdict["merge_exit_code"] = merge_code
        if merge_code:
            return merge_code
        def validate_merged(tree):
            validate_selection(tree)
            actual = Counter(test["nodeIdentifier"] for test in cases(tree))
            expected = Counter(test["nodeIdentifier"] for phase in ("Hosted", "Native")
                               for test in cases(json.loads(commands.text(f"{phase}Inventory"))))
            if actual != expected:
                raise ValueError("Merged Siri inventory differs from the two executed selections")
        verdict["manifest_exit_code"] = export_inventory(
            commands, output / "SiriSchema.xcresult", "TestInventory", validate_merged)
        if (commands.output / "TestInventory.log").exists():
            (output / "SiriSchemaTests.json").write_text(commands.text("TestInventory"))
        return verdict["manifest_exit_code"]
    finally:
        (commands.output / "Verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")


def execute_command(command, log_path, *, timeout=None, observe=None):
    """Stream one owned process group, preserving cancellation and bounded cleanup."""
    import selectors
    process, selector, observer = None, None, None
    pending = b""
    interrupted = None
    cancel_deadline = None
    drain_deadline = None
    kill_deadline = None
    timed_out = False
    deadline = time.monotonic() + timeout if timeout is not None else None

    def signal_group(signum):
        if process is not None:
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass
            except OSError as error:
                if interrupted is None and not timed_out:
                    raise
                print(f"Command cleanup signal failed: {error}", file=sys.stderr, flush=True)

    def kill_remaining():
        nonlocal kill_deadline
        if kill_deadline is None:
            kill_deadline = time.monotonic() + 5
        signal_group(signal.SIGKILL)

    def reap():
        remaining = max(0, kill_deadline - time.monotonic()) if kill_deadline is not None else 5
        return process.wait(timeout=remaining)

    def cancel(signum, _frame):
        nonlocal interrupted, cancel_deadline
        if interrupted is None:
            interrupted = signum
            cancel_deadline = time.monotonic() + 5
            signal_group(signum)

    # Install before spawning so a cancellation cannot abandon a new child.
    handlers = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        if interrupted is not None:
            signal_group(interrupted)
        observer = observe(process.pid) if observe else None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        with log_path.open("wb") as log:
            # Pipe EOF does not establish process exit; descendants can also
            # retain the pipe after the leader exits. Both paths stay bounded.
            while selector.get_map() or process.poll() is None:
                now = time.monotonic()
                if deadline is not None and now >= deadline:
                    timed_out = True
                    deadline = None
                    kill_remaining()
                if kill_deadline is not None and now >= kill_deadline:
                    break
                if process.poll() is not None and drain_deadline is None:
                    drain_deadline = now + 5
                if drain_deadline is not None and now >= drain_deadline:
                    break
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    if observer:
                        pending += chunk
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            observer.line(line.decode(errors="replace"))
                if observer:
                    observer.tick()
                if cancel_deadline is not None and time.monotonic() >= cancel_deadline:
                    kill_remaining()
                    cancel_deadline = None
            code = reap()
    except (OSError, subprocess.SubprocessError) as error:
        if interrupted is None and not timed_out:
            raise
        print(f"Command did not finish cleanly: {error}", file=sys.stderr, flush=True)
        code = 1  # The established timeout/cancellation below remains authoritative.
    finally:
        try:
            if process:
                signal_group(signal.SIGKILL)
                if process.poll() is None:
                    reap()
        except (OSError, subprocess.SubprocessError) as error:
            if interrupted is None and not timed_out:
                raise
            print(f"Command cleanup incomplete: {error}", file=sys.stderr, flush=True)
        finally:
            try:
                if selector:
                    selector.close()
                if process:
                    process.stdout.close()
                if observer:
                    observer.close()
            except (OSError, subprocess.SubprocessError) as error:
                if interrupted is None and not timed_out:
                    raise
                print(f"Command evidence cleanup incomplete: {error}", file=sys.stderr, flush=True)
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)
    if interrupted is not None:
        return 128 + interrupted
    return 124 if timed_out else code if code >= 0 else 128 - code


def execute_test(command, log_path, sample=None):
    observe = (lambda pid: LaunchObserver(lambda: sample(pid),
        output=log_path.parent / "SiriRegistration" / "LaunchObservation.json")) if sample else None
    return execute_command(command, log_path, observe=observe)


def prepare_runtime(output):
    """Complete the scoped cache-readiness experiment before simulator ownership."""
    command = ["xcrun", "simctl", "runtime", "dyld_shared_cache", "update", RUNTIME]
    started = time.monotonic()
    record = {"command": command, "timeout_seconds": RUNTIME_READINESS_TIMEOUT_SECONDS,
              "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        record["exit_code"] = execute_command(command, output / "RuntimeReadiness.log",
                                              timeout=RUNTIME_READINESS_TIMEOUT_SECONDS)
        if record["exit_code"] == 124:
            record["timed_out"] = True
        elif record["exit_code"] in (128 + signal.SIGINT, 128 + signal.SIGTERM):
            record["signal"] = record["exit_code"] - 128
    except (OSError, subprocess.SubprocessError) as error:
        record.update(exit_code=1, error=str(error))
    finally:
        record["wall_seconds"] = round(time.monotonic() - started, 6)
        (output / "RuntimeReadiness.json").write_text(json.dumps(record, indent=2) + "\n")
    return record["exit_code"]


def run_tests(output, sampled=False):
    output = Path(output)
    commands = Commands(output / "SiriRegistration")
    code = prepare_runtime(commands.output)
    if code:
        return code
    code = commands.run("Create", ["xcrun", "simctl", "create", "Shopping Siri schema",
                                  "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                                  RUNTIME])
    if code:
        return code
    device = str(uuid.UUID(commands.text("Create").strip())).upper()
    (output / "SiriSimulatorID").write_text(device + "\n")
    # Cache preparation is complete; Xcode still owns simulator boot and app launch.
    return run_phases(device, output, commands, sampled)


def capture(output):
    output = Path(output)
    if not (output / "SiriSimulatorID").exists():
        return
    device = str(uuid.UUID((output / "SiriSimulatorID").read_text().strip())).upper()
    commands = Commands(output / "SiriRegistration")
    # Observe before any cleanup. In particular, bootstatus -b would cold-boot a
    # simulator Xcode has already shut down and destroy the failure-state evidence.
    state = None
    if commands.run("FinalDeviceState", ["xcrun", "simctl", "list", "devices", "--json"]) == 0:
        try:
            rows = json.loads(commands.text("FinalDeviceState"))["devices"].values()
            state = next(device_row["state"] for group in rows for device_row in group if device_row["udid"] == device)
        except (KeyError, ValueError, StopIteration) as error:
            (commands.output / "StateError.txt").write_text(str(error))
    try:
        if state == "Booted":
            commands.run("System", ["xcrun", "simctl", "spawn", device, "log", "show", "--last", "25m",
                                    "--style", "compact", "--predicate",
                                    'subsystem BEGINSWITH[c] "com.apple.appintents" OR process == "linkd"'])
            if commands.run("Container", ["xcrun", "simctl", "get_app_container", device,
                                          "com.mggarofalo.shopping", "app"]) == 0:
                app = Path(commands.text("Container").strip())
                if (app / "Metadata.appintents").is_dir():
                    shutil.copytree(app / "Metadata.appintents", commands.output / "Metadata.appintents", dirs_exist_ok=True)
                    commands.run("AppInfo", ["plutil", "-convert", "json", "-o",
                                             str(commands.output / "AppInfo.json"), str(app / "Info.plist")])
        else:
            (commands.output / "LiveCaptureSkipped.txt").write_text(f"Observed device state: {state!r}; no diagnostic boot attempted.\n")
    finally:
        commands.run("Shutdown", ["xcrun", "simctl", "shutdown", device])
        commands.run("Delete", ["xcrun", "simctl", "delete", device])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("test", "capture"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sample-launch", action="store_true")
    args = parser.parse_args()
    if args.action == "capture":
        capture(args.output)
        return 0
    return run_tests(args.output, args.sample_launch)


if __name__ == "__main__":
    sys.exit(main())
