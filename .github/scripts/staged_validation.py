#!/usr/bin/env python3
"""Exact-source staged evidence. Local integrity is not hosted authenticity."""
import argparse
from collections import Counter
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile
import uuid

sys.dont_write_bytecode = True
from compatibility_evidence import verify as verify_restoration
from local_validation_attempt import require_latest
from selected_test_inventory import selected_tests, verify_selected_report, verify_products, verify_explicit_products

ROOT = Path(__file__).resolve().parents[2]
CONFIG = '.github/staged-validation.json'
CANARY_JOB = 'Compatibility Canary (diagnostic)'
NATIVE_JOBS = ('Build & Test (native)', 'Release SDK Build (native)')
GATE_FILES = (CONFIG, '.github/scripts/local_validation_attempt.py', '.github/scripts/staged_validation.py',
              '.github/scripts/run-local-staged-validation.py',
              '.github/scripts/require-full-preflight.py',
              '.github/scripts/run-compatibility-canary.py',
              '.github/scripts/check-driver-contracts.py',
              '.github/scripts/with-system-text-size.py',
              '.github/scripts/selected_test_inventory.py',
              '.github/scripts/compatibility_evidence.py',
              'ShoppingCompatibility.xctestplan',
              '.github/workflows/swift-ci.yml', '.github/workflows/swift-exhaustive.yml',
              '.github/scripts/run-local-shopping-full.sh',
              '.github/scripts/dispatch-remote-shopping-full.sh')


def config(root=ROOT):
    return json.loads((root / CONFIG).read_text())


def digest(data):
    return hashlib.sha256(data).hexdigest()


def gate_version(root=ROOT):
    return digest(json.dumps({p: digest((root / p).read_bytes()) for p in GATE_FILES}, sort_keys=True).encode())


def fixture_selection(root=ROOT):
    classes = config(root)['fixtures']['classes']
    result = []
    for name in classes:
        source = (root / 'ShoppingTests' / (name + '.swift')).read_text()
        result.extend(name + '/' + method for method in re.findall(r'\bfunc\s+(test\w+)\s*\(', source))
    if not result or len(result) != len(set(result)):
        raise ValueError('Empty or duplicate fixture selection')
    return Counter(result)


def validate_native(files, sha, kind, environment, root=ROOT):
    if kind not in ('fixtures', 'canary') or environment not in config(root)['environments']:
        raise ValueError('Unknown evidence stage or environment')
    metadata = json.loads(files['Metadata.json'])
    report = json.loads(files['Timing.json'])
    verified = json.loads(files['SourceVerified.json'])
    if not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('Invalid source SHA')
    for source in (metadata, report['metadata']):
        if source.get('commit_sha') != sha or source.get('dirty') is not False:
            raise ValueError('Native evidence is dirty or belongs to another SHA')
    if verified != {'commit_sha': sha, 'clean_unchanged': True}:
        raise ValueError('Missing clean unchanged source verification')
    platform = config(root)['environments'][environment]
    if metadata.get('xcode', '').splitlines()[0:1] != ['Xcode ' + platform['xcode']]:
        raise ValueError('Wrong Xcode version')
    if report['metadata'].get('xcode') != metadata['xcode']:
        raise ValueError('Conflicting toolchain provenance')
    devices = report['metadata'].get('devices', [])
    if len(devices) != 1 or devices[0].get('osVersion') != platform['runtime'] or devices[0].get('platform') != 'iOS Simulator':
        raise ValueError('Wrong or incomplete runtime evidence')
    expected_plan = 'ShoppingFast' if kind == 'fixtures' else 'ShoppingCompatibility'
    if metadata.get('plan') != expected_plan or report['metadata'].get('plan') != expected_plan:
        raise ValueError('Wrong test plan provenance')
    expected = fixture_selection(root) if kind == 'fixtures' else selected_tests(root, 'ShoppingCompatibility')
    bundle = config(root)['fixtures']['bundle'] if kind == 'fixtures' else 'ShoppingTests'
    verify_selected_report(report, expected, bundle)
    if report.get('failures') or report.get('result') != 'Passed':
        raise ValueError('Native summary did not pass')
    phases = [json.loads(line) for line in files['Phases.jsonl'].splitlines() if line.strip()]
    required_phases = ['driver-contracts', 'simulator', 'build-cold', 'build-warm', 'test', 'report'] if kind == 'canary' else ['simulator', 'build', 'test', 'report']
    if [p.get('phase') for p in phases] != required_phases or any(p.get('exit_code') != 0 for p in phases):
        raise ValueError('Missing, failed or incomplete native phases')
    with tempfile.TemporaryDirectory(prefix='shopping-built-selection-') as directory:
        products = Path(directory)
        (products / 'BuiltSelection.xctestrun').write_bytes(files['BuiltSelection.xctestrun'])
        if kind == 'canary':
            verify_products(products, root, 'ShoppingCompatibility')
        else:
            skipped = json.loads((root / 'ShoppingFast.xctestplan').read_text())['testTargets'][0].get('skippedTests', [])
            verify_explicit_products(products, 'ShoppingFast', bundle, expected, skipped)
    if kind == 'canary':
        if json.loads(files['PlannedSelection.json']) != json.loads((root / 'ShoppingCompatibility.xctestplan').read_text()):
            raise ValueError('Stale canary selection')
        evidence = verify_restoration(files['test.log'].decode(), files['OriginalCategory.txt'].decode().strip(), devices[0]['deviceId'])
        if json.loads(json.dumps(evidence)) != json.loads(files['Restoration.json']):
            raise ValueError('Restoration receipt differs from driver evidence')
    else:
        if json.loads(files['Selection.json']) != sorted(expected):
            raise ValueError('Stale fixture selection')
    return metadata, report


def artifact_names(kind):
    common = ['Metadata.json', 'Timing.json', 'SourceVerified.json', 'Phases.jsonl', 'BuiltSelection.xctestrun']
    return common + (['PlannedSelection.json', 'Restoration.json', 'OriginalCategory.txt', 'test.log']
                     if kind == 'canary' else ['Selection.json'])


def make_receipt(directory, sha, kind, environment, root=ROOT, local_attempt=None):
    files = {name: (directory / name).read_bytes() for name in artifact_names(kind)}
    metadata, report = validate_native(files, sha, kind, environment, root)
    receipt = {'schema_version': 1, 'sha': sha, 'gate_version': gate_version(root),
               'kind': kind, 'environment': environment, 'local_attempt': local_attempt, 'xcode': metadata['xcode'],
               'devices': report['metadata']['devices'], 'tests': report['tests'],
               'run_url': metadata.get('run_url'), 'run_attempt': metadata.get('run_attempt'),
               'artifacts': {name: digest(data) for name, data in files.items()}}
    (directory / 'StageReceipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


def validate_receipt(files, sha, kind, environment, root=ROOT):
    receipt = json.loads(files['StageReceipt.json'])
    for key, value in {'schema_version': 1, 'sha': sha, 'gate_version': gate_version(root),
                       'kind': kind, 'environment': environment}.items():
        if receipt.get(key) != value:
            raise ValueError('Stale or incorrect receipt ' + key)
    if 'local_attempt' not in receipt or (environment == 'pinned' and receipt['local_attempt'] is not None):
        raise ValueError('Wrong local attempt identity for receipt environment')
    if receipt['local_attempt'] is not None:
        uuid.UUID(receipt['local_attempt'])
    expected = set(artifact_names(kind))
    if set(receipt.get('artifacts', {})) != expected:
        raise ValueError('Incomplete artifact receipt')
    for name in expected:
        if digest(files[name]) != receipt['artifacts'][name]:
            raise ValueError('Artifact integrity mismatch: ' + name)
    metadata, report = validate_native(files, sha, kind, environment, root)
    for key, value in {'xcode': metadata['xcode'], 'devices': report['metadata']['devices'],
                       'tests': report['tests'], 'run_url': metadata.get('run_url'),
                       'run_attempt': metadata.get('run_attempt')}.items():
        if receipt.get(key) != value:
            raise ValueError('Receipt disagrees with artifact ' + key)
    return receipt


def local_receipt(directory, sha, kind, root=ROOT):
    names = artifact_names(kind) + ['StageReceipt.json']
    return validate_receipt({name: (directory / name).read_bytes() for name in names}, sha, kind, 'local', root)


def local_receipt_root(sha):
    common = Path(subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], cwd=ROOT, text=True, timeout=60).strip())
    if not common.is_absolute():
        common = ROOT / common
    return common.resolve() / 'shopping-staged-receipts' / sha


def require_local_receipts(sha):
    base = local_receipt_root(sha)
    require_latest(base, sha, gate_version(), {kind: base / kind / 'StageReceipt.json' for kind in ('fixtures', 'canary')})
    for kind in ('fixtures', 'canary'):
        local_receipt(base / kind, sha, kind)


def gh_api(path, *, binary=False):
    data = subprocess.check_output(['gh', 'api', path], cwd=ROOT, timeout=60)
    return data if binary else json.loads(data)


def pages(api, path, key):
    result = []
    page = 1
    while True:
        batch = api(path + ('&' if '?' in path else '?') + f'per_page=100&page={page}')[key]
        result.extend(batch)
        if len(batch) < 100:
            return result
        page += 1


def execution_key(run):
    """GitHub run_started_at resets on re-run; creation IDs do not."""
    value = datetime.fromisoformat(run['run_started_at'].replace('Z', '+00:00'))
    if value.tzinfo is None:
        raise ValueError('Execution timestamp must identify its timezone')
    return value, run['id'], run.get('run_attempt', 1)


def latest_canary(repository, sha, api=gh_api):
    runs = pages(api, f'repos/{repository}/actions/workflows/swift-ci.yml/runs?head_sha={sha}', 'workflow_runs')
    executions = []
    for run in runs:
        if run.get('head_sha') != sha or run.get('event') != 'workflow_dispatch':
            continue
        canaries = []
        for attempt in range(run['run_attempt'], 0, -1):
            jobs = pages(api, f"repos/{repository}/actions/runs/{run['id']}/attempts/{attempt}/jobs", 'jobs')
            matches = [job for job in jobs if job.get('name') == CANARY_JOB]
            if matches:
                canaries = matches
                break
            # A queued/incomplete rerun with no published canary job cannot
            # borrow an earlier pass while its new selection is unresolved.
            if attempt == run['run_attempt'] and run.get('status') != 'completed' and run.get('display_title') == 'Shopping compatibility canary':
                break
        relevant = run.get('display_title') == 'Shopping compatibility canary' or any(
            job.get('conclusion') != 'skipped' for job in canaries)
        if not relevant:
            continue
        execution = run
        if attempt != run['run_attempt']:
            execution = api(f"repos/{repository}/actions/runs/{run['id']}/attempts/{attempt}")
            if (execution.get('head_sha'), execution.get('id'), execution.get('run_attempt')) != (sha, run['id'], attempt):
                raise ValueError('Wrong retained canary execution')
        executions.append((execution_key(execution), run, canaries, attempt))
    if not executions:
        raise ValueError('No exact-source pinned canary success')
    latest = max(executions, key=lambda item: item[0])
    # GitHub timestamps have second resolution. If two executions tie, an
    # unresolved/failed one must not be hidden by a success with a larger ID.
    for key, candidate, jobs, _ in executions:
        if key[0] != latest[0][0]:
            continue
        if len(jobs) != 1 or jobs[0].get('status') != 'completed' or jobs[0].get('conclusion') != 'success':
            raise ValueError('Latest relevant pinned canary has not passed')
        if candidate.get('status') != 'completed' or candidate.get('conclusion') != 'success':
            raise ValueError('Pinned canary workflow did not complete successfully')
    _, run, canaries, attempt = latest
    return run, dict(canaries[0], evidence_attempt=attempt)


def require_pinned_canary(repository, sha, api=gh_api, download=None, root=ROOT):
    run, job = latest_canary(repository, sha, api)
    artifacts = pages(api, f"repos/{repository}/actions/runs/{run['id']}/artifacts", 'artifacts')
    matches = [a for a in artifacts if a.get('name') == 'compatibility-' + sha and a.get('expired') is False]
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous pinned artifact')
    artifact = matches[0]
    if artifact.get('workflow_run', {}).get('head_sha') != sha:
        raise ValueError('Artifact does not belong to exact source')
    payload = (download or (lambda path: gh_api(path, binary=True)))(f"repos/{repository}/actions/artifacts/{artifact['id']}/zip")
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        wanted = artifact_names('canary') + ['StageReceipt.json']
        files = {}
        for name in wanted:
            info = archive.getinfo(name)
            if info.file_size > 20_000_000 or archive.namelist().count(name) != 1:
                raise ValueError('Oversized or duplicate evidence artifact')
            files[name] = archive.read(info)
    receipt = validate_receipt(files, sha, 'canary', 'pinned', root)
    if receipt['run_url'] != run['html_url'] or str(receipt['run_attempt']) != str(job['evidence_attempt']):
        raise ValueError('Receipt belongs to a different hosted execution')
    return {'run_id': run['id'], 'job_id': job['id'], 'artifact_id': artifact['id'], 'receipt': receipt}


def cheap_gate(run=subprocess.run):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    commands = [[sys.executable, '.github/scripts/check-driver-contracts.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_staged_validation.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_acceptance_contract.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_exhaustive_contract.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_full_preflight.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_compatibility_canary.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_staged_runner.py'],
                [sys.executable, '-m', 'unittest', 'discover', '-s', '.github/scripts', '-p', 'test_local_validation_attempt.py'],
                ['bash', '.github/scripts/test-shopping-full-gate.sh'],
                ['ruby', '.github/scripts/check-action-pins.rb']]
    for command in commands:
        run(command, cwd=ROOT, env=env, check=True, timeout=120)


def clean_source():
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True, timeout=60).strip()
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True, timeout=60):
        raise ValueError('Staged dispatch requires clean source')
    return sha


def dispatch(stage, fixtures, canary, *, run=subprocess.run, check=clean_source, gate=cheap_gate,
             local=local_receipt, latest=None):
    if stage not in ('canary', 'ci'):
        raise ValueError('Unknown dispatch stage')
    sha = check()
    gate()
    local(fixtures, sha, 'fixtures')
    local(canary, sha, 'canary')
    (latest or require_latest)(local_receipt_root(sha), sha, gate_version(),
                               {'fixtures': fixtures / 'StageReceipt.json', 'canary': canary / 'StageReceipt.json'})
    branch = subprocess.check_output(['git', 'symbolic-ref', '--short', 'HEAD'], cwd=ROOT, text=True, timeout=60).strip()
    remote = subprocess.check_output(['git', 'ls-remote', '--heads', 'origin', 'refs/heads/' + branch], cwd=ROOT, text=True, timeout=60).split()
    if not remote or remote[0] != sha:
        raise ValueError('Push this exact candidate before dispatch')
    if check() != sha:
        raise ValueError('Source changed during staged preflight')
    command = ['gh', 'workflow', 'run', 'swift-ci.yml', '--ref', branch, '-f', 'expected_sha=' + sha]
    if stage == 'canary':
        command += ['-f', 'compatibility_canary=true']
    run(command, cwd=ROOT, check=True, timeout=60)


def validate_expected_sha(actual, expected, required=False):
    if not expected and not required:
        return
    if not re.fullmatch('[0-9a-f]{40}', expected) or actual != expected:
        raise ValueError('Dispatched ref moved away from the validated candidate')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('gate')
    p = sub.add_parser('expected-sha')
    p.add_argument('actual')
    p.add_argument('expected')
    p.add_argument('--required', action='store_true')
    p = sub.add_parser('pinned')
    p.add_argument('sha')
    p = sub.add_parser('local')
    p.add_argument('sha')
    p = sub.add_parser('receipt')
    p.add_argument('--directory', type=Path, required=True)
    p.add_argument('--kind', choices=['fixtures', 'canary'], required=True)
    p.add_argument('--environment', choices=['local', 'pinned'], required=True)
    p = sub.add_parser('dispatch')
    p.add_argument('--stage', choices=['canary', 'ci'], required=True)
    p.add_argument('--fixtures', type=Path, required=True)
    p.add_argument('--canary', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'gate':
        cheap_gate()
    elif args.command == 'expected-sha':
        validate_expected_sha(args.actual, args.expected, args.required)
    elif args.command == 'pinned':
        repository = os.environ.get('GITHUB_REPOSITORY') or subprocess.check_output(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], cwd=ROOT, text=True, timeout=60).strip()
        require_pinned_canary(repository, args.sha)
    elif args.command == 'local':
        require_local_receipts(args.sha)
    elif args.command == 'receipt':
        make_receipt(args.directory, clean_source(), args.kind, args.environment)
    else:
        dispatch(args.stage, args.fixtures, args.canary)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('Staged validation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
