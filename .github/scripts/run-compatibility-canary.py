#!/usr/bin/env python3
"""Build once and run the four compatibility workflows serially; never retries."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from compatibility_evidence import verify
from selected_test_inventory import verify_products, verify_report

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / '.github/scripts'
PLAN = 'ShoppingCompatibility'


def gate_then_run(gate, run):
    """A failed deterministic transport contract must prevent native allocation."""
    gate()
    return run()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    os.chdir(ROOT)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    def call(command):
        subprocess.run([str(v) for v in command], check=True, env=env)
    timing = [sys.executable, SCRIPTS / 'test-timing.py']
    def phase(name, command):
        call(timing + ['run', '--phases', artifacts / 'Phases.jsonl', '--phase', name,
             '--record-command', '--log', artifacts / (name + '.log'), '--'] + command)
    def run():
        call(timing + ['init', '--plan', PLAN, '--json', artifacts / 'Metadata.json'])
        base = ['xcodebuild', '-project', 'Shopping.xcodeproj', '-scheme', 'Shopping',
                '-testPlan', PLAN, '-destination', 'platform=iOS Simulator,id=' + args.simulator,
                '-derivedDataPath', artifacts / 'DerivedData', '-parallel-testing-enabled', 'NO']
        phase('simulator', ['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'])
        initial = subprocess.check_output(['xcrun', 'simctl', 'ui', args.simulator, 'content_size'], text=True).strip()
        (artifacts / 'OriginalCategory.txt').write_text(initial + '\n')
        phase('build-cold', base + ['build-for-testing'])
        verify_products(artifacts / 'DerivedData/Build/Products', plan_name=PLAN)
        phase('build-warm', base + ['build-for-testing'])
        verify_products(artifacts / 'DerivedData/Build/Products', plan_name=PLAN)
        try:
            phase('test', [sys.executable, SCRIPTS / 'with-system-text-size.py', '--'] + base +
                  ['test-without-building', '-resultBundlePath', artifacts / 'Results.xcresult'])
        finally:
            phase('report', timing + ['report', '--plan', PLAN, '--metadata', artifacts / 'Metadata.json',
                  '--phases', artifacts / 'Phases.jsonl', '--result', artifacts / 'Results.xcresult',
                  '--json', artifacts / 'Timing.json', '--markdown', artifacts / 'Timing.md'])
        verify_report(json.loads((artifacts / 'Timing.json').read_text()), plan_name=PLAN)
        evidence = verify((artifacts / 'test.log').read_text(), initial, args.simulator)
        final = subprocess.check_output(['xcrun', 'simctl', 'ui', args.simulator, 'content_size'], text=True).strip()
        if final != initial:
            raise ValueError('Final simulator category differs from original')
        (artifacts / 'Restoration.json').write_text(json.dumps(evidence, indent=2) + '\n')
    gate_then_run(lambda: phase('driver-contracts', [sys.executable, SCRIPTS / 'check-driver-contracts.py']), run)
    return 0


if __name__ == '__main__':
    sys.exit(main())
