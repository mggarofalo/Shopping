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

    def run(self, name, command, timeout=20):
        started = time.monotonic()
        record = {"command": command, "timeout_seconds": timeout,
                  "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
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
    def __init__(self, capture, clock=time.monotonic, delay=20):
        self.capture, self.clock, self.delay = capture, clock, delay
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


def test_command(device, output):
    return ["xcodebuild", "test", "-project", "Shopping.xcodeproj", "-scheme", "ShoppingSiri",
            "-testPlan", "ShoppingSiri", "-collect-test-diagnostics", "never",
            "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
            "-only-testing:ShoppingPersistenceTests/SpokenGrocerySchemaTests",
            "-only-testing:ShoppingPersistenceTests/CatalogActionTests",
            "-only-testing:ShoppingSiriTests/" + UI_TEST.removesuffix("()"),
            "-resultBundlePath", str(output / "SiriSchema.xcresult")]


def execute_test(command, log_path, sample=None):
    import selectors
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    observer = LaunchObserver(lambda: sample(process.pid)) if sample else None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = b""
    interrupted = None
    cancel_deadline = None

    def cancel(signum, _frame):
        nonlocal interrupted, cancel_deadline
        interrupted = signum
        cancel_deadline = time.monotonic() + 5
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass

    handlers = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with log_path.open("wb") as log:
            # Pipe EOF does not mean the command exited. Keep the cancellation
            # deadline active when a stubborn child closes stdout before exit.
            while selector.get_map() or process.poll() is None:
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
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    cancel_deadline = None
            code = process.wait()
    finally:
        selector.close()
        process.stdout.close()
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        if observer and observer.thread:
            observer.thread.join()
        if observer:
            (log_path.parent / "SiriRegistration" / "LaunchObservation.json").write_text(json.dumps({
                "launch_observed_at": observer.observed_at, "sample_delay_seconds": observer.delay,
                "launch_finished_observed": observer.finished, "sample_started": observer.thread is not None,
            }, indent=2) + "\n")
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    return 128 + interrupted if interrupted else code if code >= 0 else 128 - code


def run_tests(output, sampled=False):
    output = Path(output)
    commands = Commands(output / "SiriRegistration")
    code = commands.run("Create", ["xcrun", "simctl", "create", "Shopping Siri schema",
                                  "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                                  "com.apple.CoreSimulator.SimRuntime.iOS-27-0"])
    if code:
        return code
    device = str(uuid.UUID(commands.text("Create").strip())).upper()
    (output / "SiriSimulatorID").write_text(device + "\n")
    # No boot/readiness change in this probe: preserve Xcode-owned launch ordering.
    command = test_command(device, output)
    (commands.output / "TestCommand.json").write_text(json.dumps(command, indent=2) + "\n")
    test_code = execute_test(command, output / "SiriSchema.log",
                             (lambda pid: sample_launch(commands.output, device, pid)) if sampled else None)
    export_code = commands.run("TestInventory", ["xcrun", "xcresulttool", "get", "test-results", "tests",
                                                "--path", str(output / "SiriSchema.xcresult"), "--format", "json"])
    manifest_code = export_code
    if export_code == 0:
        (output / "SiriSchemaTests.json").write_text(commands.text("TestInventory"))
        try:
            validate_selection(json.loads(commands.text("TestInventory")))
        except (KeyError, ValueError) as error:
            manifest_code = 1
            (commands.output / "ManifestFailure.txt").write_text(str(error) + "\n")
    (commands.output / "Verdict.json").write_text(json.dumps({"test_exit_code": test_code,
        "manifest_exit_code": manifest_code}, indent=2) + "\n")
    return test_code or manifest_code


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
