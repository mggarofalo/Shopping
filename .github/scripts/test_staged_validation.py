"""Adversarial staged receipts and allocation gates; no native tools or API writes."""
from copy import deepcopy
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import zipfile

import staged_validation as stage
import test_compatibility_canary as canary_contracts

SHA = 'a' * 40


class StagedValidationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.receipt_root = Path(temporary.name)
        self.root_patch = patch.object(stage, 'local_receipt_root', return_value=self.receipt_root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    def files(self, kind='canary', environment='pinned'):
        platform = stage.config()['environments'][environment]
        metadata = dict(commit_sha=SHA, dirty=False, plan='ShoppingCompatibility' if kind == 'canary' else stage.config()['fixtures']['plan'], xcode='Xcode ' + platform['xcode'] + '\nBuild version test',
                        run_url='https://github.com/owner/repo/actions/runs/10' if environment == 'pinned' else None,
                        run_attempt='1' if environment == 'pinned' else None)
        selected = stage.selected_tests(stage.ROOT, 'ShoppingCompatibility') if kind == 'canary' else stage.fixture_selection()
        bundle = 'ShoppingTests' if kind == 'canary' else 'ShoppingPersistenceTests'
        device = {'deviceId': 'same-device', 'platform': 'iOS Simulator', 'osVersion': platform['runtime']}
        tests = [{'identifier': x, 'bundle': bundle, 'result': 'Passed'} for x in selected]
        report = {'metadata': dict(metadata, devices=[device]), 'result': 'Passed', 'failures': [], 'tests': tests,
                  'counts': {'totalTestCount': len(tests), 'passedTests': len(tests), 'failedTests': 0, 'skippedTests': 0}}
        plan = 'ShoppingCompatibility' if kind == 'canary' else stage.config()['fixtures']['plan']
        target = {'BlueprintName': bundle, 'OnlyTestIdentifiers': list(selected)}
        if kind == 'fixtures':
            target['SkipTestIdentifiers'] = json.loads((stage.ROOT / 'ShoppingFast.xctestplan').read_text())['testTargets'][0]['skippedTests']
        built = {'TestPlan': {'Name': plan}, 'TestConfigurations': [{'TestTargets': [target]}]}
        phases = ['driver-contracts', 'simulator', 'build-cold', 'build-warm', 'test', 'report'] if kind == 'canary' else ['simulator', 'build', 'test', 'report']
        result = {'Metadata.json': json.dumps(metadata).encode(), 'Timing.json': json.dumps(report).encode(),
                  'SourceVerified.json': json.dumps({'commit_sha': SHA, 'clean_unchanged': True}).encode(),
                  'BuiltSelection.xctestrun': plistlib.dumps(built),
                  'Phases.jsonl': '\n'.join(json.dumps({'phase': p, 'exit_code': 0}) for p in phases).encode()}
        if kind == 'canary':
            helper = canary_contracts.CanaryContracts()
            events, fixtures = helper.receipt()
            log = helper.log(events, fixtures)
            result.update({'test.log': log.encode(), 'OriginalCategory.txt': b'medium',
                           'Restoration.json': json.dumps(stage.verify_restoration(log, 'medium')).encode(),
                           'PlannedSelection.json': (stage.ROOT / 'ShoppingCompatibility.xctestplan').read_bytes()})
        else:
            result['Selection.json'] = json.dumps(sorted(selected)).encode()
        return self.sign(result, kind, environment)

    def sign(self, files, kind='canary', environment='pinned'):
        # Test-only generator: deliberately build invalid but internally hashed
        # receipts too, so semantic validation is not confused with authenticity.
        metadata = json.loads(files['Metadata.json'])
        report = json.loads(files['Timing.json'])
        receipt = dict(schema_version=1, sha=SHA, gate_version=stage.gate_version(), kind=kind,
                       environment=environment, local_attempt=None, xcode=metadata['xcode'], devices=report['metadata']['devices'],
                       tests=report['tests'], run_url=metadata.get('run_url'), run_attempt=metadata.get('run_attempt'),
                       artifacts={name: stage.digest(files[name]) for name in stage.artifact_names(kind)})
        files['StageReceipt.json'] = json.dumps(receipt).encode()
        return files

    def test_fixture_plan_matches_source_and_preserves_fast_configuration(self):
        stage.fixture_plan()
        root = self.receipt_root / 'source'
        paths = [stage.CONFIG, 'ShoppingFast.xctestplan', 'ShoppingFixtures.xctestplan',
                 'Shopping.xcodeproj/xcshareddata/xcschemes/Shopping.xcscheme']
        paths += ['ShoppingTests/' + name + '.swift' for name in stage.config()['fixtures']['classes']]
        for name in paths:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(stage.ROOT / name, target)
        fixture = root / 'ShoppingFixtures.xctestplan'
        original = fixture.read_text()
        for change in ('missing', 'extra', 'duplicate', 'coverage', 'exclusion'):
            plan = json.loads(original)
            target = plan['testTargets'][0]
            if change == 'missing': target['selectedTests'].pop()
            elif change == 'extra': target['selectedTests'].append('Other/testExtra()')
            elif change == 'duplicate': target['selectedTests'].append(target['selectedTests'][0])
            elif change == 'coverage': plan['defaultOptions']['codeCoverage'] = False
            else: target['skippedTests'] = []
            fixture.write_text(json.dumps(plan))
            with self.subTest(change=change), self.assertRaises(ValueError): stage.fixture_plan(root)
        fixture.write_text(original)
        scheme = root / paths[3]
        scheme.write_text(scheme.read_text().replace('container:ShoppingFixtures.xctestplan', 'container:Missing.xctestplan'))
        with self.assertRaises(ValueError): stage.fixture_plan(root)

    def test_cli_only_fixture_manifest_is_rejected(self):
        files = self.files('fixtures', 'local')
        built = plistlib.loads(files['BuiltSelection.xctestrun'])
        del built['TestConfigurations'][0]['TestTargets'][0]['OnlyTestIdentifiers']
        files['BuiltSelection.xctestrun'] = plistlib.dumps(built)
        with self.assertRaisesRegex(ValueError, 'Built identifiers'):
            stage.validate_native(files, SHA, 'fixtures', 'local')

    def test_built_fixture_manifest_may_omit_only_disjoint_exclusions(self):
        files = self.files('fixtures', 'local')
        built = plistlib.loads(files['BuiltSelection.xctestrun'])
        target = built['TestConfigurations'][0]['TestTargets'][0]
        del target['SkipTestIdentifiers']
        files['BuiltSelection.xctestrun'] = plistlib.dumps(built)
        stage.validate_native(files, SHA, 'fixtures', 'local')
        target['SkipTestIdentifiers'] = ['UnexpectedClass']
        files['BuiltSelection.xctestrun'] = plistlib.dumps(built)
        with self.assertRaisesRegex(ValueError, 'Built exclusions'):
            stage.validate_native(files, SHA, 'fixtures', 'local')
        target.pop('SkipTestIdentifiers')
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            (products / 'manifest.xctestrun').write_bytes(plistlib.dumps(built))
            for exclusion in ('FixtureReadinessTests', next(iter(stage.fixture_selection()))):
                with self.subTest(exclusion=exclusion), self.assertRaisesRegex(ValueError, 'Built exclusions'):
                    stage.verify_explicit_products(products, stage.config()['fixtures']['plan'],
                        'ShoppingPersistenceTests', stage.fixture_selection(), [exclusion])

    def test_valid_fixture_and_canary_receipts(self):
        self.assertEqual(len(stage.fixture_selection()), 25)
        for kind in ('fixtures', 'canary'):
            for environment in ('local', 'pinned'):
                stage.validate_receipt(self.files(kind, environment), SHA, kind, environment)

    def test_rejects_wrong_receipt_identity_version_and_missing_artifacts(self):
        for key, value in [('sha', 'b' * 40), ('gate_version', 'old'), ('kind', 'fixtures'),
                           ('environment', 'local'), ('schema_version', 0)]:
            files = self.files()
            receipt = json.loads(files['StageReceipt.json']); receipt[key] = value
            files['StageReceipt.json'] = json.dumps(receipt).encode()
            with self.assertRaises(ValueError, msg=key):
                stage.validate_receipt(files, SHA, 'canary', 'pinned')
        files = self.files(); del files['SourceVerified.json']
        with self.assertRaises(KeyError): stage.validate_receipt(files, SHA, 'canary', 'pinned')
        files = self.files(); files['Timing.json'] += b' '
        with self.assertRaises(ValueError): stage.validate_receipt(files, SHA, 'canary', 'pinned')

    def test_rejects_semantic_defects_even_with_rehashed_artifacts(self):
        for mutation in ('dirty', 'wrong_sha', 'wrong_xcode', 'wrong_runtime', 'missing_device',
                         'failed', 'cancelled', 'skipped', 'missing_test', 'duplicate_test', 'extra_test',
                         'missing_phase', 'duplicate_phase', 'failed_phase', 'missing_built_test', 'wrong_plan'):
            files = self.files(); metadata = json.loads(files['Metadata.json']); report = json.loads(files['Timing.json'])
            if mutation == 'dirty': metadata['dirty'] = True
            if mutation == 'wrong_sha': metadata['commit_sha'] = 'b' * 40
            if mutation == 'wrong_xcode': metadata['xcode'] = 'Xcode 27.1'
            if mutation == 'wrong_runtime': report['metadata']['devices'][0]['osVersion'] = '26.5'
            if mutation == 'missing_device': report['metadata']['devices'] = []
            if mutation in ('failed', 'cancelled', 'skipped'): report['tests'][0]['result'] = mutation
            if mutation == 'missing_test': report['tests'].pop()
            if mutation == 'duplicate_test': report['tests'].append(report['tests'][0])
            if mutation == 'extra_test': report['tests'].append(dict(report['tests'][0], identifier='Other/test'))
            if 'phase' in mutation:
                phases = [json.loads(x) for x in files['Phases.jsonl'].splitlines()]
                if mutation == 'missing_phase': phases.pop(0)
                if mutation == 'duplicate_phase': phases.append(phases[-1])
                if mutation == 'failed_phase': phases[0]['exit_code'] = 1
                files['Phases.jsonl'] = '\n'.join(map(json.dumps, phases)).encode()
            if mutation == 'missing_built_test':
                built = plistlib.loads(files['BuiltSelection.xctestrun'])
                built['TestConfigurations'][0]['TestTargets'][0]['OnlyTestIdentifiers'].pop()
                files['BuiltSelection.xctestrun'] = plistlib.dumps(built)
            if mutation == 'wrong_plan': files['PlannedSelection.json'] = b'{}'
            files['Metadata.json'] = json.dumps(metadata).encode(); files['Timing.json'] = json.dumps(report).encode()
            self.sign(files)
            with self.assertRaises(ValueError, msg=mutation): stage.validate_receipt(files, SHA, 'canary', 'pinned')

    def run_record(self, run_id=10, **changes):
        return dict(id=run_id, head_sha=SHA, event='workflow_dispatch', run_attempt=1,
                    status='completed', conclusion='success', display_title='Shopping compatibility canary',
                    html_url=f'https://github.com/owner/repo/actions/runs/{run_id}', run_started_at=f'2026-10-28T00:00:{run_id:02d}Z', **changes)

    def api(self, runs, jobs=None, artifact_changes=None):
        jobs = jobs or {10: [{'id': 100, 'name': stage.CANARY_JOB, 'status': 'completed', 'conclusion': 'success'}]}
        def fetch(path):
            if '/workflows/' in path: return {'workflow_runs': runs}
            if '/jobs?' in path:
                run_id = int(path.split('/runs/')[1].split('/')[0]); return {'jobs': jobs[run_id]}
            if '/attempts/1' in path and '?' not in path:
                return self.run_record()
            if '/artifacts?' in path:
                return {'artifacts': [dict({'id': 1000, 'name': 'compatibility-' + SHA, 'expired': False,
                                           'workflow_run': {'head_sha': SHA}}, **(artifact_changes or {}))]}
            self.fail('Unexpected API read: ' + path)
        return fetch

    def archive(self, files):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            for name, data in files.items(): archive.writestr(name, data)
        return stream.getvalue()

    def test_hosted_receipt_requires_actual_successful_run_job_and_artifact(self):
        download = Mock(return_value=self.archive(self.files()))
        evidence = stage.require_pinned_canary('owner/repo', SHA, self.api([self.run_record()]), download)
        self.assertEqual(evidence['job_id'], 100)
        for conclusion in ('failure', 'cancelled', 'skipped', None):
            jobs = {10: [dict(id=100, name=stage.CANARY_JOB, status='completed', conclusion=conclusion)]}
            download.reset_mock()
            with self.assertRaises(ValueError):
                stage.require_pinned_canary('owner/repo', SHA, self.api([self.run_record()], jobs), download)
            download.assert_not_called()
        for change in ({'expired': True}, {'workflow_run': {'head_sha': 'b' * 40}}):
            with self.assertRaises(ValueError):
                stage.require_pinned_canary('owner/repo', SHA, self.api([self.run_record()], artifact_changes=change), download)

    def test_newer_failure_blocks_old_success_but_normal_skipped_canary_does_not(self):
        jobs = {10: [dict(id=100, name=stage.CANARY_JOB, status='completed', conclusion='success')],
                11: [dict(id=101, name=stage.CANARY_JOB, status='completed', conclusion='skipped')]}
        normal = self.run_record(11); normal['display_title'] = 'Shopping routine CI'
        run, _ = stage.latest_canary('owner/repo', SHA, self.api([self.run_record(), normal], jobs))
        self.assertEqual(run['id'], 10)
        for conclusion in ('failure', 'cancelled', 'skipped', None):
            jobs[11][0]['conclusion'] = conclusion
            with self.assertRaises(ValueError):
                stage.latest_canary('owner/repo', SHA, self.api([self.run_record(), self.run_record(11)], jobs))

    def test_retained_canary_receipt_uses_its_actual_attempt(self):
        run = self.run_record(); run['run_attempt'] = 2
        base = self.api([run])
        def api(path):
            if '/attempts/2/jobs?' in path:
                return {'jobs': [{'name': 'Siri launch diagnostic', 'status': 'completed', 'conclusion': 'success'}]}
            return base(path)
        evidence = stage.require_pinned_canary('owner/repo', SHA, api, Mock(return_value=self.archive(self.files())))
        self.assertEqual(evidence['job_id'], 100)

    def test_older_run_later_failed_or_queued_attempt_supersedes_new_run_success(self):
        older = self.run_record(10)
        newer = self.run_record(11)
        older.update(run_attempt=2, run_started_at='2026-10-28T00:00:20Z')
        jobs = {10: [dict(id=100, name=stage.CANARY_JOB, status='completed', conclusion='failure')],
                11: [dict(id=101, name=stage.CANARY_JOB, status='completed', conclusion='success')]}
        for status in ('completed', 'queued', 'in_progress'):
            older['status'] = status
            older['conclusion'] = 'failure' if status == 'completed' else None
            jobs[10] = [] if status != 'completed' else [dict(id=100, name=stage.CANARY_JOB, status='completed', conclusion='failure')]
            with self.assertRaises(ValueError):
                stage.latest_canary('owner/repo', SHA, self.api([older, newer], jobs))

    def test_unrelated_later_rerun_does_not_refresh_old_canary_timestamp(self):
        older = self.run_record(10)
        older.update(run_attempt=2, run_started_at='2026-10-28T00:00:30Z')
        newer = self.run_record(11)
        jobs = {10: [dict(id=100, name=stage.CANARY_JOB, status='completed', conclusion='success')],
                11: [dict(id=101, name=stage.CANARY_JOB, status='completed', conclusion='failure')]}
        base = self.api([older, newer], jobs)
        def api(path):
            if '/runs/10/attempts/2/jobs?' in path:
                return {'jobs': [{'name': 'Siri launch diagnostic', 'status': 'completed', 'conclusion': 'success'}]}
            return base(path)
        with self.assertRaises(ValueError):
            stage.latest_canary('owner/repo', SHA, api)

    def test_remote_only_advance_is_rejected_by_host_before_native_allocation(self):
        allocated = Mock()
        for expected, actual, required in [(SHA, 'b' * 40, False), (SHA, 'b' * 40, True), ('', SHA, True)]:
            with self.assertRaises(ValueError):
                stage.validate_expected_sha(actual, expected, required)
                allocated()
        allocated.assert_not_called()
        stage.validate_expected_sha(SHA, SHA, True)
        stage.validate_expected_sha(SHA, '', False)

    def test_failing_cheap_gate_never_reaches_receipt_network_or_dispatch(self):
        native = Mock(); receipt = Mock()
        started = time.monotonic()
        with self.assertRaises(subprocess.CalledProcessError):
            stage.dispatch('canary', Path('fixtures'), Path('canary'), run=native, check=lambda: SHA,
                           gate=Mock(side_effect=subprocess.CalledProcessError(1, ['injected-cheap-gate'])),
                           local=receipt)
        native.assert_not_called(); receipt.assert_not_called()
        print(json.dumps({'demonstration': 'failing-supported-dispatch', 'wall_seconds': time.monotonic() - started,
                          'github_mutations': 0, 'macos_allocations': 0, 'scope': 'controlled fake process/API boundary'}))

    def test_invalid_local_receipt_stops_dispatch_before_github(self):
        native = Mock()
        with self.assertRaises(ValueError):
            stage.dispatch('ci', Path('fixtures'), Path('canary'), run=native, check=lambda: SHA,
                           gate=Mock(), local=Mock(side_effect=ValueError('stale')))
        native.assert_not_called()

    def test_latest_local_failure_blocks_even_valid_older_supplied_receipts(self):
        invoked = Mock()
        with patch.object(stage.subprocess, 'check_output', return_value='/tmp/fake-common-dir\n'):
            with self.assertRaisesRegex(ValueError, 'known failure'):
                stage.dispatch('canary', Path('older-fixtures'), Path('older-canary'), run=invoked,
                               check=lambda: SHA, gate=Mock(), local=Mock(),
                               latest=Mock(side_effect=ValueError('known failure')))
        invoked.assert_not_called()

    def test_unchanged_passing_candidate_dispatches_only_after_ordered_prerequisites(self):
        events = []
        def check(): events.append('source'); return SHA
        def read(command, **kwargs):
            if command[1:3] == ['symbolic-ref', '--short']: return 'test/candidate\n'
            if command[1] == 'rev-parse': return '/tmp/fake-common-dir\n'
            if command[1] == 'ls-remote': return SHA + '\trefs/heads/test/candidate\n'
            if command[0:3] == ['gh', 'repo', 'view']: return 'owner/repo\n'
            self.fail('Unexpected process: ' + repr(command))
        with patch.object(stage.subprocess, 'check_output', side_effect=read):
            stage.dispatch('ci', Path('fixtures'), Path('canary'), check=check,
                           gate=lambda: events.append('cheap'),
                           local=lambda path, sha, kind: events.append(kind), latest=lambda *args, **kwargs: events.append('latest-local'),
                           run=lambda cmd, **kwargs: events.append(('dispatch', cmd, kwargs)))
        self.assertEqual(events[:-1], ['source', 'cheap', 'fixtures', 'canary', 'latest-local', 'source'])
        self.assertEqual(events[-1][2]['cwd'], stage.ROOT)
        self.assertEqual(events[-1][1], ['gh', 'workflow', 'run', 'swift-ci.yml', '--ref', 'test/candidate', '-f', 'expected_sha=' + SHA])

    def test_dispatch_reserves_receipts_through_network_and_allocation(self):
        from local_validation_attempt import LocalAttempt
        points = []
        def blocked(point):
            with self.assertRaises(ValueError):
                with LocalAttempt(self.receipt_root, SHA, 'v', Path('output')):
                    self.fail('Concurrent validation acquired dispatch reservation')
            points.append(point)
        def read(command, **kwargs):
            if command[1] == 'symbolic-ref': return 'test/candidate'
            if command[1] == 'ls-remote':
                blocked('remote')
                return SHA + '\tref'
            self.fail(repr(command))
        with patch.object(stage.subprocess, 'check_output', side_effect=read):
            stage.dispatch('ci', Path('fixtures'), Path('canary'), check=lambda: SHA,
                           gate=Mock(), local=Mock(), latest=Mock(),
                           run=lambda *args, **kwargs: blocked('dispatch'))
        self.assertEqual(points, ['remote', 'dispatch'])
        self.assertFalse((self.receipt_root / 'attempt.lock').exists())

    def test_workflow_failure_graph_allocates_no_native_job_and_fails_required_names(self):
        workflow = json.loads(subprocess.check_output(['ruby', '-rjson', '-ryaml', '-e',
            'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))',
            str(stage.ROOT / '.github/workflows/swift-ci.yml')]))
        jobs = workflow['jobs']
        self.assertEqual(jobs['cheap-contracts']['runs-on'], 'ubuntu-latest')
        steps = jobs['cheap-contracts']['steps']
        self.assertIn('expected-sha', steps[1]['run'])
        self.assertEqual(steps[1]['env']['EXPECTED_SHA'], '${{ inputs.expected_sha }}')
        self.assertFalse(any('staged_validation.py pinned' in step.get('run', '') for step in jobs['cheap-contracts']['steps']))
        for key in ('build', 'release-build', 'compatibility-canary', 'siri-launch-diagnostic'):
            self.assertEqual(jobs[key]['needs'], 'cheap-contracts')
        for key, native, name in [('build-required', 'build', 'Build & Test'), ('release-required', 'release-build', 'Release SDK Build')]:
            job = jobs[key]
            self.assertEqual(job['needs'], ['cheap-contracts', native])
            self.assertIn('always()', job['if'])
            self.assertIn("|| '" + name + "'", job['name'])
            self.assertIn('not requested', job['name'])
            self.assertEqual(job['runs-on'], 'ubuntu-latest')
            command = job['steps'][0]['run']
            for cheap, actual, cancelled in [('failure', 'skipped', 'false'), ('success', 'cancelled', 'false'),
                                              ('success', 'success', 'true'), ('skipped', 'success', 'false')]:
                self.assertNotEqual(subprocess.run(['sh', '-c', command], env=dict(os.environ,
                    CHEAP_RESULT=cheap, NATIVE_RESULT=actual, CANCELLED=cancelled)).returncode, 0)
            self.assertEqual(subprocess.run(['sh', '-c', command], env=dict(os.environ,
                    CHEAP_RESULT='success', NATIVE_RESULT='success', CANCELLED='false')).returncode, 0)
        exhaustive = (stage.ROOT / '.github/workflows/swift-exhaustive.yml').read_text()
        self.assertIn('needs: preflight', exhaustive)
        self.assertIn('require-full-preflight.py "$GITHUB_SHA" --pinned-canary', exhaustive)
        self.assertIn('verify-shopping-full-attestation.sh', exhaustive)


if __name__ == '__main__':
    unittest.main()
