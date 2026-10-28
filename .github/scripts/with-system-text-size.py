#!/usr/bin/env python3
"""Drive real Simulator text size for one xcodebuild invocation, then restore it."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

# Cold hosted Simulator commands exceeded 15 seconds before any app mutation.
# This host-infrastructure allowance is separate from the unchanged eight-second
# app observation bound. Two workers can queue two set/readback pairs plus IPC.
COMMAND_TIMEOUT_SECONDS = 60
REQUEST_TIMEOUT_SECONDS = 4 * COMMAND_TIMEOUT_SECONDS + 15
CANCEL_GRACE_SECONDS = 10

CATEGORIES = {
    "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large",
    "extra-extra-extra-large", "accessibility-medium", "accessibility-large",
    "accessibility-extra-large", "accessibility-extra-extra-large",
    "accessibility-extra-extra-extra-large",
}


def simulator_size(device, category=None, *, device_set, run=subprocess.run, clock=time):
    command = ["xcrun", "simctl", "--set", device_set, "ui", device, "content_size"]
    if category is not None:
        command.append(category)
    started = clock.monotonic()
    try:
        result = run(command, capture_output=True, text=True,
                                timeout=COMMAND_TIMEOUT_SECONDS, check=True)
    finally:
        print("Simulator text-size command: " + json.dumps({
            "device": device, "category": category,
            "seconds": round(clock.monotonic() - started, 3),
        }), flush=True)
    if category is None:
        value = result.stdout.strip()
        if value not in CATEGORIES:
            raise ValueError(f"Unsupported system category: {value!r}")
        return value


class Driver:
    def __init__(self, token, command=simulator_size, *, clock=time):
        self.token = token
        self.command = command
        self.clock = clock
        self.leases = {}
        self.device_sets = {}
        self.seen = set()
        self.poisoned = set()
        self.unrecovered = {}
        self.failed = False

    def size(self, device, category=None):
        return self.command(device, category, device_set=self.device_sets[device])

    def handle(self, request):
        response = {key: request.get(key) for key in ("id", "token", "lease", "device", "deviceSet", "operation", "category")}
        try:
            for key in ("id", "lease", "device"):
                if not isinstance(request[key], str):
                    raise ValueError(f"Invalid {key} identity")
                uuid.UUID(request[key])
            if request["token"] != self.token:
                raise ValueError("Wrong run token")
            if request["id"] in self.seen:
                raise ValueError("Duplicate request")
            self.seen.add(request["id"])
            now = self.clock.time()
            if not now < request["expires"] <= now + REQUEST_TIMEOUT_SECONDS:
                raise ValueError("Expired or invalid request deadline")
            device, lease, operation = request["device"], request["lease"], request["operation"]
            device_set = request["deviceSet"]
            if not isinstance(device_set, str) or not Path(device_set).is_absolute():
                raise ValueError("Invalid simulator device set")
            if device in self.unrecovered:
                raise ValueError("Simulator restoration failed; this run cannot reuse it")
            if operation == "acquire":
                if device in self.leases:
                    raise ValueError("Simulator already has an active text-size lease")
                self.device_sets[device] = device_set
                original = self.size(device)
                self.leases[device] = (lease, original)
                response.update(original=original, observed=original)
            else:
                active, original = self.leases[device]
                if self.device_sets[device] != device_set:
                    raise ValueError("Wrong simulator device set")
                if active != lease:
                    raise ValueError("Wrong test lease")
                if operation == "set" and device in self.poisoned:
                    raise ValueError("Lease failed; only restoration is allowed")
                if operation not in ("set", "restore"):
                    raise ValueError("Unknown operation")
                category = original if operation == "restore" else request["category"]
                if category not in CATEGORIES:
                    raise ValueError("Unknown category")
                # Single serial event loop: an expired setter finishes before a
                # subsequent restore. No setter can race cleanup or another test.
                self.size(device, category)
                observed = self.size(device)
                if observed != category:
                    raise ValueError(f"System readback {observed!r} differs from {category!r}")
                response.update(original=original, observed=observed)
                if operation == "restore":
                    del self.leases[device]
                    self.poisoned.discard(device)
            if self.clock.time() >= request["expires"]:
                raise ValueError("System operation exceeded request deadline")
        except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
            self.failed = True
            device = request.get("device")
            if isinstance(device, str) and device in self.leases:
                self.poisoned.add(device)
            response["error"] = str(error)
        print("System text size: " + json.dumps(response), flush=True)
        return response

    def cleanup(self):
        # Any abandoned lease is a failed run even when emergency restoration
        # succeeds. The XCTest teardown must prove normal in-app restoration.
        if self.leases:
            self.failed = True
        for device, (_, original) in list(self.leases.items()):
            try:
                self.size(device, original)
                if self.size(device) != original:
                    raise ValueError("Emergency restoration readback differs")
                print(f"Restored abandoned text-size lease for {device} to {original}", flush=True)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                self.unrecovered[device] = self.leases[device]
                print(f"Text-size cleanup failed for {device}: {error}", file=sys.stderr, flush=True)
            del self.leases[device]



def process_requests(root, driver, should_stop=lambda: False):
    """Drain one serial inbox snapshot; responses become visible atomically."""
    for path in sorted(root.glob("*.request.json")):
        if should_stop():
            break
        try:
            request = json.loads(path.read_text())
            if not isinstance(request, dict) or not isinstance(request.get("id"), str) or path.name != request["id"] + ".request.json":
                raise ValueError("Request filename does not match identity")
            response = driver.handle(request)
            destination = root / (path.name.removesuffix(".request.json") + ".response.json")
            temporary = destination.with_suffix(".tmp")
            temporary.write_text(json.dumps(response))
            temporary.replace(destination)
            path.unlink()
        except (ValueError, OSError) as error:
            driver.failed = True
            print(f"Invalid text-size request: {error}", file=sys.stderr, flush=True)
            path.unlink(missing_ok=True)


def signal_child(process, signum, killpg=os.killpg):
    # A child can exit between poll and forwarding its cancellation signal.
    try:
        killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def supervise(process, root, driver, cancellation, *, clock=time, killpg=os.killpg):
    """Own event ordering separately from native launch and signal registration."""
    killed = False
    while process.poll() is None:
        signum, started = cancellation()
        if signum is not None:
            if not killed and clock.monotonic() - started > CANCEL_GRACE_SECONDS:
                signal_child(process, signal.SIGKILL, killpg)
                killed = True
        else:
            process_requests(root, driver, lambda: cancellation()[0] is not None)
        clock.sleep(0.05)
    code = process.wait()
    # The command may exit while grandchildren still own its private group.
    # They must not outlive the run or race emergency simulator restoration.
    signal_child(process, signal.SIGKILL, killpg)
    driver.cleanup()
    signum, _ = cancellation()
    if signum is not None:
        return 128 + signum
    if code:
        return code if code > 0 else 128 - code
    return 1 if driver.failed else 0


def main(command):
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit("Usage: with-system-text-size.py -- xcodebuild ...")
    token = str(uuid.uuid4())
    driver = Driver(token)
    process = None
    group_finished = False
    cancelled = None
    cancel_started = None

    def cancel(signum, _frame):
        nonlocal cancelled, cancel_started
        if cancelled is None:
            cancelled, cancel_started = signum, time.monotonic()
            if process is not None:
                signal_child(process, signum)

    old = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with tempfile.TemporaryDirectory(prefix="shopping-system-text-size-") as directory:
            root = Path(directory)
            env = dict(os.environ, TEST_RUNNER_SHOPPING_SYSTEM_TEXT_SIZE_ROOT=directory,
                       TEST_RUNNER_SHOPPING_SYSTEM_TEXT_SIZE_TOKEN=token,
                       TEST_RUNNER_SHOPPING_SYSTEM_TEXT_SIZE_TIMEOUT=str(REQUEST_TIMEOUT_SECONDS))
            process = subprocess.Popen(command, env=env, start_new_session=True)
            result = supervise(process, root, driver, lambda: (cancelled, cancel_started))
            group_finished = True
            return result
    finally:
        if process is not None and process.poll() is None:
            signal_child(process, signal.SIGTERM)
            try:
                process.wait(timeout=CANCEL_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                signal_child(process, signal.SIGKILL)
                process.wait()
        if process is not None and not group_finished:
            signal_child(process, signal.SIGKILL)
        driver.cleanup()
        for sig, handler in old.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
