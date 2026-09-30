#!/usr/bin/env python3
"""Temporary SHOPPING-131 native List system-resize diagnostic controller.
No device commands run on import or with --help. Requires an already-built xctestrun.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
import uuid

CATEGORIES = {"extra-small", "small", "medium", "large", "extra-large",
              "extra-extra-large", "extra-extra-extra-large", "accessibility-medium",
              "accessibility-large", "accessibility-extra-large",
              "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"}
PHASES = {1: "large", 2: "accessibility-extra-extra-extra-large", 3: "large"}
PROBES = {"native-list"}


def atomic(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def sim(udid, *args):
    return subprocess.run(["xcrun", "simctl", *args[:1], udid, *args[1:]],
                          check=True, text=True, capture_output=True, timeout=10).stdout.strip()


def targets(node):
    if isinstance(node, dict):
        if node.get("BlueprintName") == "ShoppingTests" and "TestHostPath" in node:
            yield node
        for value in node.values():
            yield from targets(value)
    elif isinstance(node, list):
        for value in node:
            yield from targets(value)


def stop(child):
    if child is None or child.poll() is not None:
        return
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        child.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="Owned xcodebuild command; use literal {xctestrun} for the patched run file")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or "{xctestrun}" not in command:
        parser.error("command must contain {xctestrun}")
    args.output.mkdir(parents=True, exist_ok=False)
    nonce = uuid.uuid4().hex
    original = sim(args.simulator, "ui", "content_size")
    if original not in CATEGORIES:
        raise RuntimeError(f"Unsupported content size readback: {original!r}")
    atomic(args.output / "original-setting.json", {"simulator": args.simulator, "contentSize": original})
    source = args.xctestrun.resolve()
    document = plistlib.loads(source.read_bytes())
    matches = list(targets(document))
    if len(matches) != 1:
        raise RuntimeError(f"Expected one ShoppingTests target, got {len(matches)}")
    target = matches[0]
    host = Path(target["TestHostPath"].replace("__TESTROOT__", str(source.parent)))
    if "__" in str(host):
        raise RuntimeError(f"Unresolved runner path: {host}")
    runner_id = plistlib.loads((host / "Info.plist").read_bytes())["CFBundleIdentifier"]
    target.setdefault("EnvironmentVariables", {}).update({
        "SHOPPING_NATIVE_RESIZE_NONCE": nonce,
        "SHOPPING_NATIVE_RESIZE_ORIGINAL": original,
    })
    # Same parent is essential: all __TESTROOT__ paths keep their original meaning.
    patched = source.with_name("ShoppingNativeSystemResize-" + nonce + ".xctestrun")
    patched.write_bytes(plistlib.dumps(document))
    (args.output / "original.xctestrun").write_bytes(source.read_bytes())
    (args.output / "controlled.xctestrun").write_bytes(patched.read_bytes())
    child = None
    channel = None
    completed = {}
    handled = set()
    started = {}
    events = args.output / "events.jsonl"

    def log(**fields):
        fields["elapsed"] = round(time.monotonic() - begin, 3)
        with events.open("a") as stream:
            stream.write(json.dumps(fields) + "\n")
        print("NATIVE_SYSTEM_RESIZE " + json.dumps(fields), flush=True)

    def interrupted(signum, _frame):
        raise InterruptedError(f"Received signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    begin = time.monotonic()
    last_container_lookup = -10.0
    next_heartbeat = begin
    result = 1
    try:
        child_command = [str(patched) if item == "{xctestrun}" else item for item in command]
        atomic(args.output / "invocation.json", {"nonce": nonce, "runner": runner_id,
               "simulator": args.simulator, "command": child_command})
        child = subprocess.Popen(child_command, start_new_session=True)
        while True:
            now = time.monotonic()
            child_finished = child.poll() is not None
            if now - begin > 20 * 60:
                raise TimeoutError("Owned diagnostic process exceeded 20-minute bound")
            if now >= next_heartbeat:
                log(event="child-running", completed=sorted(completed))
                next_heartbeat = now + 30
            if channel is None and not child_finished:
                if now - begin >= 8 * 60:
                    raise TimeoutError("Runner container was not ready within the 8-minute startup bound")
                if now - last_container_lookup > 1:
                    last_container_lookup = now
                    try:
                        container = sim(args.simulator, "get_app_container", runner_id, "data")
                        channel = Path(container) / "tmp" / ("shopping-native-system-resize-" + nonce)
                        log(event="runner-container-ready")
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                        # Installation and CoreSimulator readiness precede the test runner.
                        # Retry only this read-only discovery, while the owned child lives.
                        log(event="runner-container-not-ready",
                            reason="timeout" if isinstance(error, subprocess.TimeoutExpired) else "unavailable",
                            error=str(error))
                    child_finished = child.poll() is not None
            if channel is not None and channel.exists():
                for path in sorted(channel.glob("*.request.json")):
                    if child_finished:
                        break  # Never start another setting change after the test process exits.
                    if path.name in handled:
                        continue
                    request = json.loads(path.read_text())
                    probe, sequence = request.get("probe"), request.get("sequence")
                    if request.get("version") != 1 or request.get("nonce") != nonce or probe not in PROBES or sequence not in (1, 2, 3, 4):
                        raise RuntimeError("Invalid/stale marker")
                    expected = PHASES.get(sequence, original)
                    if request.get("category") != expected:
                        raise RuntimeError("Unexpected text-size request")
                    previous = sum(name.startswith(probe + "-") for name in handled)
                    if sequence != 4 and sequence != previous + 1:
                        raise RuntimeError("Out-of-order phase")
                    started.setdefault(probe, now)
                    sim(args.simulator, "ui", "content_size", expected)
                    observed = sim(args.simulator, "ui", "content_size")
                    if observed != expected:
                        raise RuntimeError("System readback does not match request")
                    reply = dict(request, observed=observed, success=True)
                    atomic(path.with_name(path.name.replace(".request.", ".response.")), reply)
                    handled.add(path.name)
                    log(event="system-size", **reply)
                for path in channel.glob("*.done.json"):
                    evidence = json.loads(path.read_text())
                    probe = evidence.get("probe")
                    if evidence.get("version") != 1 or evidence.get("nonce") != nonce or probe not in PROBES:
                        raise RuntimeError("Invalid completion marker")
                    if probe not in completed:
                        completed[probe] = evidence
                        atomic(args.output / path.name, evidence)
                        log(event="probe-finished", probe=probe, success=evidence.get("success"))
                for probe, when in started.items():
                    if probe not in completed and now - when > 150:
                        raise TimeoutError(f"Probe stalled: {probe}")
            if child_finished:
                break  # Final iteration consumed any last completion marker before child exit.
            time.sleep(0.1)  # Bounded controller polling; no XCTest sleeps.
        result = child.returncode
        if set(completed) != PROBES or not all(item.get("success") is True for item in completed.values()):
            log(event="missing-or-failed-probe", completed=completed)
            result = result or 1
    except Exception as error:
        log(event="controller-error", error=str(error))
        result = 1
    finally:
        # Restore even if stopping the child itself reports an error.
        try:
            stop(child)
        except Exception as error:
            log(event="child-stop-failed", error=str(error))
            result = 1
        try:
            sim(args.simulator, "ui", "content_size", original)
            restored = sim(args.simulator, "ui", "content_size")
            atomic(args.output / "restoration.json", {"expected": original, "observed": restored})
            if restored != original:
                result = 1
        except Exception as error:
            log(event="restoration-failed", error=str(error))
            result = 1
        if channel is not None and channel.exists():
            for path in channel.glob("*.json"):
                (args.output / path.name).write_bytes(path.read_bytes())
        patched.unlink(missing_ok=True)
    return result


if __name__ == "__main__":
    sys.exit(main())
