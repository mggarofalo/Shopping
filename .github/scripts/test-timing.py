#!/usr/bin/env python3
"""Record command wall time and export xcresult test timings (Xcode 16+).

JSON schema version 1 keeps summed test durations distinct from elapsed phases.
No retries, timing thresholds, or changes to the commands' exit status are made.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run_phase(args):
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise ValueError("run requires a command after --")
    started_at, started = utc_now(), time.monotonic()
    code, received_signal, process = 1, None, None
    log = None
    old_handlers = {}

    def forward(signum, _frame):
        nonlocal received_signal
        received_signal = signum
        if process is not None:
            process.send_signal(signum)

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            old_handlers[signum] = signal.signal(signum, forward)
        if args.log:
            log = open(args.log, "wb")
        process = subprocess.Popen(command, stdout=subprocess.PIPE if log else None,
                                   stderr=subprocess.STDOUT if log else None)
        if log:
            while chunk := process.stdout.read1(65536):
                log.write(chunk)
                log.flush()
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        code = process.wait()
        if code < 0:
            code = 128 - code
    except OSError as error:
        print(f"Cannot run {command[0]}: {error}", file=sys.stderr)
        code = 127
    finally:
        if log:
            log.close()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        phase = {"phase": args.phase, "started_at": started_at, "finished_at": utc_now(),
                 "wall_seconds": round(time.monotonic() - started, 6), "exit_code": code}
        if args.log:
            phase["log_path"] = str(Path(args.log).resolve())
        if args.record_command:
            phase["command"] = command
        if received_signal:
            phase["signal"] = received_signal
        if args.seconds:
            Path(args.seconds).write_text(str(math.ceil(phase["wall_seconds"])) + "\n")
        with open(args.phases, "a", encoding="utf-8") as output:
            output.write(json.dumps(phase) + "\n")
    return code


def duration_seconds(node):
    exact = node.get("durationInSeconds")
    if isinstance(exact, (int, float)):
        return exact
    value = str(node.get("duration", ""))
    # Xcode 16 reports formatted durations; Xcode 26 also supplies exact seconds.
    units = {"d": 86400, "h": 3600, "m": 60, "s": 1, "ms": .001, "μs": .000001, "µs": .000001}
    parts = re.findall(r"([\d.]+)\s*(ms|μs|µs|d|h|m|s)", value)
    return sum(float(number) * units[unit] for number, unit in parts) if parts else None


def collect_tests(tree):
    tests = []

    def visit(node, bundle=None, suites=()):
        kind = node.get("nodeType")
        if kind in ("Unit test bundle", "UI test bundle"):
            bundle = node["name"]
        if kind == "Test Suite":
            suites = suites + (node["name"],)
        if kind == "Test Case":
            # Child runs/configurations are detail, not extra tests. Retain aggregate duration.
            tests.append({"identifier": node.get("nodeIdentifier", node["name"]),
                          "name": node["name"], "bundle": bundle,
                          "suite": "/".join(suites), "result": node.get("result", "Unknown"),
                          "duration_seconds": duration_seconds(node),
                          "duration_precision": ("exact" if "durationInSeconds" in node else
                                                 "formatted" if "duration" in node else "unavailable")})
            return
        for child in node.get("children", []):
            visit(child, bundle, suites)

    for node in tree.get("testNodes", []):
        visit(node)
    return tests


def output_of(command):
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.PIPE).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def xcresult_json(bundle, kind, warnings):
    try:
        return json.loads(subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", bundle],
            text=True, stderr=subprocess.PIPE))
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        warnings.append(f"Unable to read xcresult {kind}: {error}")
        return {}


def read_phases(path, warnings):
    if not Path(path).exists():
        warnings.append("No phase timings recorded.")
        return []
    phases = []
    for line in Path(path).read_text().splitlines():
        try:
            phases.append(json.loads(line))
        except ValueError:
            warnings.append("Ignored incomplete phase timing record.")
    return phases


def source_metadata(args):
    return {"commit_sha": os.environ.get("SHOPPING_TIMING_SHA") or output_of(["git", "rev-parse", "HEAD"]),
                "dirty": bool(output_of(["git", "status", "--porcelain"])),
                "captured_at": utc_now(),
                "xcode": output_of(["xcodebuild", "-version"]), "host": platform.platform(),
                "architecture": platform.machine(), "plan": args.plan,
                "run_url": (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
                            f"{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
                            if os.environ.get("GITHUB_RUN_ID") else None),
                "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT")}


def make_report(args):
    warnings = []
    phases = read_phases(args.phases, warnings)
    summary, tree = {}, {}
    if Path(args.result).is_dir():
        summary = xcresult_json(args.result, "summary", warnings)
        tree = xcresult_json(args.result, "tests", warnings)
    else:
        warnings.append("No result bundle; setup/build may have failed or the run was interrupted.")
    tests = collect_tests(tree)
    if summary.get("totalTestCount", 0) and not tests:
        warnings.append("Result has tests but no per-test timing records could be read.")
    suites = {}
    for test in tests:
        key = (test["bundle"], test["suite"])
        suite = suites.setdefault(key, {"bundle": key[0], "suite": key[1], "test_count": 0,
                                      "summed_test_seconds": 0, "untimed_test_count": 0})
        suite["test_count"] += 1
        if test["duration_seconds"] is None:
            suite["untimed_test_count"] += 1
        else:
            suite["summed_test_seconds"] += test["duration_seconds"]
    has_metadata = bool(args.metadata and Path(args.metadata).exists())
    metadata = json.loads(Path(args.metadata).read_text()) if has_metadata else source_metadata(args)
    if not has_metadata:
        warnings.append("Source/toolchain metadata captured at report time; use init/--metadata for the original run provenance.")
    metadata.update(environment=summary.get("environmentDescription"), devices=tree.get("devices", []))
    report = {"schema_version": 1, "generated_at": utc_now(), "metadata": metadata,
              "result": summary.get("result", "No test result bundle"),
              "result_bundle_path": str(Path(args.result).resolve()),
              "counts": {key: summary.get(key) for key in
                         ("totalTestCount", "passedTests", "failedTests", "skippedTests")},
              "result_bundle_wall_seconds": (summary["finishTime"] - summary["startTime"]
                                             if "startTime" in summary and "finishTime" in summary else None),
              "summed_test_seconds": sum(test["duration_seconds"] or 0 for test in tests),
              "phases": phases, "tests": tests,
              "suites": sorted(suites.values(), key=lambda suite: suite["summed_test_seconds"], reverse=True),
              "failures": summary.get("testFailures", []), "warnings": warnings}
    Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
    Path(args.markdown).write_text(markdown(report))
    return 0


def markdown(report):
    def cell(value):
        return str(value or "Unknown").replace("|", "\\|").replace("\n", " ")

    def seconds(value):
        return "Unknown" if value is None else f"{value:.3f}"

    meta = report["metadata"]
    lines = [f"# {meta['plan']} timing", "", f"- Result: {report['result']}",
             f"- Commit: `{meta['commit_sha']}`; dirty source: {meta['dirty']}",
             f"- Toolchain: {cell(meta['xcode'])}; host: {meta['host']}",
             f"- Result bundle wall time: {seconds(report['result_bundle_wall_seconds'])} seconds",
             f"- Sum of test durations: {seconds(report['summed_test_seconds'])} seconds",
             "", "Summed test time can overlap when tests run concurrently. Formatted xcresult durations are rounded; "
             "numeric durationInSeconds values retain exact precision. Phase wall time includes command startup and teardown.",
             "", "## Phases", "", "| Phase | Wall seconds | Exit code |", "| --- | ---: | ---: |"]
    lines += [f"| {cell(p['phase'])} | {seconds(p['wall_seconds'])} | {p['exit_code']} |" for p in report["phases"]]
    lines += ["", "## Slowest suites", "", "| Bundle / suite | Tests | Summed seconds |", "| --- | ---: | ---: |"]
    lines += [f"| {cell(s['bundle'])} / {cell(s['suite'])} | {s['test_count']} | {seconds(s['summed_test_seconds'])} |"
              for s in report["suites"][:15]]
    lines += ["", "## Slowest tests", "", "| Test | Result | Seconds |", "| --- | --- | ---: |"]
    ordered = sorted(report["tests"], key=lambda test: test["duration_seconds"] or 0, reverse=True)
    lines += [f"| {cell(t['bundle'])} / {cell(t['identifier'])} | {cell(t['result'])} | {seconds(t['duration_seconds'])} |"
              for t in ordered[:20]]
    if report["warnings"]:
        lines += ["", "## Reporting warnings", ""] + [f"- {warning}" for warning in report["warnings"]]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    run = commands.add_parser("run", help="Time a command without changing its exit status")
    run.add_argument("--phases", required=True)
    run.add_argument("--phase", required=True)
    run.add_argument("--log")
    run.add_argument("--record-command", action="store_true",
                     help="Include arguments in the report; only use for commands without secrets")
    run.add_argument("--seconds", help="Optional compatibility file with whole wall seconds")
    run.add_argument("command", nargs=argparse.REMAINDER)
    init = commands.add_parser("init", help="Capture source/toolchain metadata before creating artifacts")
    init.add_argument("--plan", required=True)
    init.add_argument("--json", required=True)
    report = commands.add_parser("report", help="Export per-test and phase timings, even after a failed run")
    for option in ("plan", "phases", "result", "json", "markdown"):
        report.add_argument(f"--{option}", required=True)
    report.add_argument("--metadata")
    args = parser.parse_args()
    if args.action == "init":
        Path(args.json).write_text(json.dumps(source_metadata(args), indent=2) + "\n")
        return 0
    return run_phase(args) if args.action == "run" else make_report(args)


if __name__ == "__main__":
    sys.exit(main())
