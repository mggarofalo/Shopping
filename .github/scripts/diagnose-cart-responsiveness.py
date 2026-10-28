#!/usr/bin/env python3
"""One controlled SHOPPING-250 baseline/candidate comparison; never CI proof."""
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path.cwd()
EVIDENCE = ROOT / 'CartDiagnostic'
SELECTION = 'ShoppingPersistenceTests/PersonalCartPresentationTests'
CASES = (
    ('main', '95aa72a06d9f4433366b8668b87e3b419af8126f'),
    ('recovery', 'dff6d78c3d81cc5f65f1cd39b3f3fc681bcc5d33'),
)
MARKER = 'testBlockedWriterDoesNotBlockMainActorDuringCartCommand]'


def command(args, log, timeout=600):
    with log.open('w') as output:
        result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode


def run_case(label, revision):
    evidence = EVIDENCE / label
    evidence.mkdir(parents=True)
    checkout = ROOT / '.worktrees' / ('diagnostic-' + label)
    subprocess.run(['git', 'worktree', 'add', '--detach', str(checkout), revision], check=True)
    simulator = subprocess.check_output([
        'xcrun', 'simctl', 'create', 'Cart diagnosis ' + label,
        'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro',
        'com.apple.CoreSimulator.SimRuntime.iOS-18-5'], text=True).strip()
    metadata = {'source_sha': revision, 'selection': SELECTION, 'simulator': simulator,
                'diagnostic_only': True, 'phases': []}
    (evidence / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    products = evidence / 'DerivedData'
    base = ['xcodebuild', '-project', str(checkout / 'Shopping.xcodeproj'),
            '-scheme', 'Shopping', '-testPlan', 'ShoppingFast',
            '-destination', 'platform=iOS Simulator,id=' + simulator,
            '-derivedDataPath', str(products), '-parallel-testing-enabled', 'NO',
            '-only-testing:' + SELECTION]
    try:
        started = time.monotonic()
        subprocess.run(['xcrun', 'simctl', 'boot', simulator], check=True, timeout=60)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], check=True, timeout=180)
        metadata['phases'].append({'phase': 'boot', 'seconds': time.monotonic() - started})
        started = time.monotonic()
        status = command(base + ['build-for-testing'], evidence / 'build.log')
        metadata['phases'].append({'phase': 'build', 'seconds': time.monotonic() - started,
                                   'exit_status': status})
        if status:
            return status
        log = evidence / 'test.log'
        started = time.monotonic()
        sampled = False
        marker_time = None
        with log.open('w') as output:
            test = subprocess.Popen(base + ['test-without-building', '-resultBundlePath',
                                           str(evidence / 'Results.xcresult')],
                                    stdout=output, stderr=subprocess.STDOUT)
            while test.poll() is None:
                elapsed = time.monotonic() - started
                contents = log.read_text(errors='replace')
                if marker_time is None and MARKER + "' started." in contents:
                    marker_time = time.monotonic()
                if marker_time is not None and not sampled and time.monotonic() - marker_time >= 5:
                    sampled = True
                    # A fresh, isolated simulator has exactly one Shopping host.
                    pids = subprocess.run(['pgrep', '-x', 'Shopping'], capture_output=True, text=True)
                    (evidence / 'sample-pids.txt').write_text(pids.stdout)
                    for pid in pids.stdout.split():
                        command(['sample', pid, '5', '-file', str(evidence / ('sample-' + pid + '.txt'))],
                                evidence / ('sample-command-' + pid + '.log'), timeout=15)
                if elapsed > 900:
                    test.terminate()
                    try:
                        test.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        test.kill()
                        test.wait()
                    metadata['test_timeout'] = True
                    break
                time.sleep(0.2)
        status = test.returncode
        metadata['phases'].append({'phase': 'test', 'seconds': time.monotonic() - started,
                                   'exit_status': status, 'sampled': sampled})
        bundle = evidence / 'Results.xcresult'
        if (bundle / 'Info.plist').exists():
            command(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)],
                    evidence / 'summary.json', timeout=60)
            command(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(bundle)],
                    evidence / 'tests.json', timeout=60)
        command(['xcrun', 'simctl', 'spawn', simulator, 'log', 'show', '--last', '20m',
                 '--style', 'compact', '--predicate',
                 'process == "Shopping" OR subsystem == "com.apple.appintents"'],
                evidence / 'system.log', timeout=60)
        return status
    finally:
        (evidence / 'metadata.json').write_text(json.dumps(metadata, indent=2))
        command(['xcrun', 'simctl', 'shutdown', simulator], evidence / 'shutdown.log', timeout=60)
        command(['xcrun', 'simctl', 'delete', simulator], evidence / 'delete.log', timeout=60)
        # Retain test manifests, not hundreds of MB of simulator build products.
        for manifest in products.glob('Build/Products/*.xctestrun'):
            (evidence / manifest.name).write_bytes(manifest.read_bytes())
        import shutil
        shutil.rmtree(products, ignore_errors=True)


def main():
    EVIDENCE.mkdir()
    command(['xcodebuild', '-version'], EVIDENCE / 'xcode.txt')
    outcomes = {}
    for label, revision in CASES:
        try:
            outcomes[label] = run_case(label, revision)
        except Exception as error:
            outcomes[label] = {'error': str(error)}
        (EVIDENCE / 'outcomes.json').write_text(json.dumps(outcomes, indent=2))
    return 0 if all(value == 0 for value in outcomes.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
