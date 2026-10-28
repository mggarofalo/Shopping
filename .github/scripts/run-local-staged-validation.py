#!/usr/bin/env python3
"""Capture the maintained fixture selection, then the local compatibility canary."""
import argparse
from collections import Counter
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
from selected_test_inventory import verify_explicit_products
from staged_validation import ROOT, cheap_gate, clean_source, config, fixture_selection, make_receipt, local_receipt_root, artifact_names

spec = importlib.util.spec_from_file_location('canary_runner', Path(__file__).with_name('run-compatibility-canary.py'))
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)


def verify_fixture_products(products):
    expected_skips = json.loads((ROOT / 'ShoppingFast.xctestplan').read_text())['testTargets'][0].get('skippedTests', [])
    verify_explicit_products(products, 'ShoppingFast', 'ShoppingPersistenceTests', fixture_selection(), expected_skips)


def run_canary(simulator, output):
    # Stay in this process so parent-only cancellation reaches the existing
    # active phase supervisor and its native-driver restoration path.
    return canary.main(['--simulator', simulator, '--artifacts', str(output)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    os.chdir(ROOT)
    sha = clean_source()
    cheap_gate()
    output = args.artifacts.resolve()
    if output.is_relative_to(ROOT):
        raise ValueError('Artifacts must be outside source')
    output.mkdir(parents=True, exist_ok=False)
    fixtures = output / 'Fixtures'
    fixtures.mkdir()
    scripts = ROOT / '.github/scripts'
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    def call(command, timeout=60):
        canary.bounded_call(command, env=env, timeout=timeout)
    timing = [sys.executable, scripts / 'test-timing.py']
    def phase(name, command, timeout):
        call(timing + ['run', '--phases', fixtures / 'Phases.jsonl', '--phase', name,
                      '--record-command', '--log', fixtures / (name + '.log'), '--'] + command, timeout)
    call(timing + ['init', '--plan', 'ShoppingFast', '--json', fixtures / 'Metadata.json'])
    selected = fixture_selection()
    (fixtures / 'Selection.json').write_text(json.dumps(sorted(selected)) + '\n')
    base = ['xcodebuild', '-project', 'Shopping.xcodeproj', '-scheme', 'Shopping', '-testPlan', 'ShoppingFast',
            '-destination', 'platform=iOS Simulator,id=' + args.simulator,
            '-derivedDataPath', fixtures / 'DerivedData', '-parallel-testing-enabled', 'NO']
    base += ['-only-testing:ShoppingPersistenceTests/' + name for name in selected]
    phase('simulator', ['xcrun', 'simctl', 'bootstatus', args.simulator, '-b'], 300)
    phase('build', base + ['build-for-testing'], 900)
    verify_fixture_products(fixtures / 'DerivedData/Build/Products')
    for path in (fixtures / 'DerivedData/Build/Products').glob('*.xctestrun'):
        shutil.copyfile(path, fixtures / path.name)
        if plistlib.loads(path.read_bytes()).get('TestPlan', {}).get('Name') == 'ShoppingFast':
            shutil.copyfile(path, fixtures / 'BuiltSelection.xctestrun')
    canary.test_and_report(
        lambda: phase('test', base + ['test-without-building', '-resultBundlePath', fixtures / 'Results.xcresult'], 300),
        lambda: phase('report', timing + ['report', '--plan', 'ShoppingFast', '--metadata', fixtures / 'Metadata.json',
                      '--phases', fixtures / 'Phases.jsonl', '--result', fixtures / 'Results.xcresult',
                      '--json', fixtures / 'Timing.json', '--markdown', fixtures / 'Timing.md'], 60))
    if clean_source() != sha:
        raise ValueError('Source changed during fixture validation')
    (fixtures / 'SourceVerified.json').write_text(json.dumps({'commit_sha': sha, 'clean_unchanged': True}) + '\n')
    make_receipt(fixtures, sha, 'fixtures', 'local')
    # Existing canary owns its unchanged four-method plan and timing framework.
    run_canary(args.simulator, output / 'Canary')
    if clean_source() != sha:
        raise ValueError('Source changed during staged validation')
    for kind, directory in [('fixtures', fixtures), ('canary', output / 'Canary')]:
        durable = local_receipt_root(sha) / kind
        durable.mkdir(parents=True, exist_ok=True)
        for name in artifact_names(kind) + ['StageReceipt.json']:
            shutil.copyfile(directory / name, durable / name)
    print(f'Local staged receipts: {output}')


if __name__ == '__main__':
    main()
