#!/usr/bin/env python3
"""Create one pinned simulator, then overlap its readiness with the shared build."""
import os
from pathlib import Path
import signal
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parent


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def prepare(udid, boot_timeout=300):
    # Separate phase files avoid concurrent appends; merge even after failure.
    phases = [Path("SimulatorPhases.jsonl"), Path("BuildPhases.jsonl")]
    commands = [
        ["bash", "-euo", "pipefail", "-c", '''
        xcrun simctl boot "$1"
        xcrun simctl bootstatus "$1" -b
        # QuickPath's first-use tutorial can interrupt the first typed value.
        xcrun simctl spawn "$1" defaults write \\
          com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
        ''', "boot-simulator", udid],
        ["xcodebuild", "build-for-testing", "-project", "Shopping.xcodeproj",
         "-scheme", "Shopping", "-testPlan", "ShoppingAcceptance",
         "-destination", f"platform=iOS Simulator,id={udid}",
         "-derivedDataPath", "DerivedData", "-quiet"],
    ]
    processes = []
    try:
        for phase_file, name, command in zip(phases, ("simulator", "build"), commands):
            phase_file.unlink(missing_ok=True)
            options = ["--log", "FastSimulator.log"] if name == "simulator" else [
                "--log", "FastBuild.log", "--seconds", "FastBuildSeconds.txt"]
            processes.append(subprocess.Popen([
                sys.executable, str(SCRIPTS / "test-timing.py"), "run",
                "--phases", str(phase_file), "--phase", name, "--record-command",
                *options, "--", *command], start_new_session=True))
        try:
            boot_code = processes[0].wait(timeout=boot_timeout)
        except subprocess.TimeoutExpired:
            print("Simulator readiness exceeded its five-minute budget.", file=sys.stderr)
            return 124
        if boot_code:
            return boot_code
        return processes[1].wait()
    finally:
        for process in processes:
            stop(process)
        with open("FastPhases.jsonl", "a") as output:
            for phase_file in phases:
                if phase_file.exists():
                    output.write(phase_file.read_text())


def main():
    # Cancellation must clean up both process groups before the job's reports run.
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    subprocess.run(["xcrun", "simctl", "list", "runtimes"], check=True, timeout=60)
    udid = subprocess.check_output([
        "xcrun", "simctl", "create", "Shopping CI iPhone 16 Pro",
        "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro",
        "com.apple.CoreSimulator.SimRuntime.iOS-18-5"], text=True, timeout=60).strip()
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"udid={udid}\n")
    return prepare(udid)


if __name__ == "__main__":
    sys.exit(main())
