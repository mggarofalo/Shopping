#!/usr/bin/env python3
"""Build once and run the four compatibility workflows serially; never retries."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import signal
import shutil

sys.dont_write_bytecode = True

from compatibility_evidence import verify
from selected_test_inventory import verify_products, verify_report

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / '.github/scripts'
PLAN = 'ShoppingCompatibility'
# Let the existing driver finish an in-flight 60s command and two 60s restore
# commands after cancellation; do not change its operation deadlines.
CLEANUP_SECONDS = 210
PHASE_LIMITS = {'driver-contracts': 60, 'simulator': 300, 'build-cold': 900,
                'build-warm': 900, 'test': 900, 'report': 60}


def gate_then_run(gate, run):
    """A failed deterministic transport contract must prevent native allocation."""
    gate()
    return run()


def bounded_call(command, *, env, timeout, popen=subprocess.Popen):
    """Forward cancellation through the existing timing/driver supervisors."""
    process = popen([str(v) for v in command], env=env, start_new_session=True)
    def interrupted(signum, _frame):
        raise InterruptedError(f'Canary cancelled by signal {signum}')
    old = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, InterruptedError, KeyboardInterrupt):
            # Timing forwards TERM to the text-size supervisor, which owns its
            # xcodebuild group and restores the actual simulator before exit.
            for sig in old:
                signal.signal(sig, signal.SIG_IGN)
            process.terminate()
            try:
                process.wait(timeout=CLEANUP_SECONDS)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        if code:
            raise subprocess.CalledProcessError(code, command)
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


def test_and_report(test, report):
    """Preserve a test failure even if its best-effort report also fails."""
    try:
        test()
    except BaseException:
        try:
            report()
        except BaseException as error:
            print(f'Reporting also failed: {error}', file=sys.stderr)
        raise
    report()


def source_identity():
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, timeout=60).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain'], text=True, timeout=60)
    if dirty:
        raise ValueError('Compatibility measurement requires a clean worktree: ' + dirty)
    return sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    os.chdir(ROOT)
    source = source_identity()
    artifacts = args.artifacts.resolve()
    if artifacts.is_relative_to(ROOT):
        raise ValueError('Artifact directory must be outside the source worktree')
    artifacts.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    def call(command, timeout=60):
        bounded_call(command, env=env, timeout=timeout)
    timing = [sys.executable, SCRIPTS / 'test-timing.py']
    def phase(name, command):
        call(timing + ['run', '--phases', artifacts / 'Phases.jsonl', '--phase', name,
             '--record-command', '--log', artifacts / (name + '.log'), '--'] + command, timeout=PHASE_LIMITS[name])
    def run():
        call(timing + ['init', '--plan', PLAN, '--json', artifacts / 'Metadata.json'])
        shutil.copyfile(ROOT / (PLAN + '.xctestplan'), artifacts / 'PlannedSelection.json')
        base = ['xcodebuild', '-project', 'Shopping.xcodeproj', '-scheme', 'Shopping',
                '-testPlan', PLAN, '-destination', 'platform=iOS Simulator,id=' + args.simulator,
                '-derivedDataPath', artifacts / 'DerivedData', '-parallel-testing-enabled', 'NO']
        phase('simulator', ['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'])
        initial = subprocess.check_output(['xcrun', 'simctl', 'ui', args.simulator, 'content_size'], text=True, timeout=60).strip()
        (artifacts / 'OriginalCategory.txt').write_text(initial + '\n')
        phase('build-cold', base + ['build-for-testing'])
        verify_products(artifacts / 'DerivedData/Build/Products', plan_name=PLAN)
        phase('build-warm', base + ['build-for-testing'])
        verify_products(artifacts / 'DerivedData/Build/Products', plan_name=PLAN)
        for path in (artifacts / 'DerivedData/Build/Products').glob('*.xctestrun'):
            shutil.copyfile(path, artifacts / path.name)
        def test():
            phase('test', [sys.executable, SCRIPTS / 'with-system-text-size.py', '--'] + base +
                  ['test-without-building', '-resultBundlePath', artifacts / 'Results.xcresult'])
        def report():
            phase('report', timing + ['report', '--plan', PLAN, '--metadata', artifacts / 'Metadata.json',
                  '--phases', artifacts / 'Phases.jsonl', '--result', artifacts / 'Results.xcresult',
                  '--json', artifacts / 'Timing.json', '--markdown', artifacts / 'Timing.md'])
        test_and_report(test, report)
        verify_report(json.loads((artifacts / 'Timing.json').read_text()), plan_name=PLAN)
        evidence = verify((artifacts / 'test.log').read_text(), initial, args.simulator)
        final = subprocess.check_output(['xcrun', 'simctl', 'ui', args.simulator, 'content_size'], text=True, timeout=60).strip()
        if final != initial:
            raise ValueError('Final simulator category differs from original')
        (artifacts / 'Restoration.json').write_text(json.dumps(evidence, indent=2) + '\n')
    try:
        gate_then_run(lambda: phase('driver-contracts', [sys.executable, SCRIPTS / 'check-driver-contracts.py']), run)
        if source_identity() != source:
            raise ValueError('Source changed during canary')
        (artifacts / 'SourceVerified.json').write_text(json.dumps({'commit_sha': source, 'clean_unchanged': True}) + '\n')
    except BaseException as error:
        (artifacts / 'Failure.json').write_text(json.dumps({'type': type(error).__name__, 'error': str(error)}) + '\n')
        raise
    finally:
        common = Path(subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], text=True, timeout=60).strip()).resolve()
        durable = common / 'shopping-test-timings' / source / artifacts.name
        durable.mkdir(parents=True, exist_ok=True)
        for pattern in ('*.json', '*.jsonl', '*.md', '*.txt', '*.xctestrun'):
            for path in artifacts.glob(pattern):
                shutil.copyfile(path, durable / path.name)
        print(f'Raw compatibility artifacts: {artifacts}\nDurable reports: {durable}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
