"""Protect exact inventory, cross-test state and fail-before-launch ordering."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import subprocess
import os
import sys
import unittest
import uuid
from unittest.mock import Mock, patch

from compatibility_evidence import verify
from selected_test_inventory import selected_tests, verify_products, verify_report

ROOT = Path(__file__).resolve().parents[2]
PLAN = 'ShoppingCompatibility'
spec = importlib.util.spec_from_file_location('canary', ROOT / '.github/scripts/run-compatibility-canary.py')
canary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(canary)


class CanaryContracts(unittest.TestCase):
    def test_transport_defect_stops_before_ui_or_simulator_launch(self):
        launch = Mock()
        # Inject a setter that acknowledges mutation but leaves native state unchanged.
        # The real driver's readback contract fails, and the canary never launches.
        from test_system_text_size import DriverTests
        case = DriverTests('test_exact_readback_and_original_restoration')
        case.setUp()
        case.driver.command = lambda device, category=None, **kwargs: 'large'
        def broken_transport():
            case.test_exact_readback_and_original_restoration()
        with self.assertRaises(KeyError):
            canary.gate_then_run(broken_transport, launch)
        self.assertTrue(case.driver.failed)
        launch.assert_not_called()

    def test_workflow_diagnostic_modes_preserve_required_gates(self):
        workflow = json.loads(subprocess.check_output([
            'ruby', '-rjson', '-ryaml', '-e',
            'puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))',
            str(ROOT / '.github/workflows/swift-ci.yml')]))
        jobs = workflow['jobs']
        for name in ('build', 'release-build'):
            self.assertEqual(jobs[name]['if'], "${{ github.event_name != 'workflow_dispatch' || (!inputs.siri_launch_diagnostic && !inputs.compatibility_canary) }}")
        diagnostic = jobs['compatibility-canary']
        self.assertEqual(diagnostic['if'], "${{ github.event_name == 'workflow_dispatch' && inputs.compatibility_canary }}")
        self.assertNotIn(diagnostic['name'], ('Build & Test', 'Release SDK Build'))
        steps = {s.get('name'): s for s in jobs['build']['steps']}
        self.assertIn('test_compatibility_canary.py', steps['Validate compatibility canary contracts']['run'])
        self.assertTrue(any('Xcode_16.4.app' in step.get('run', '') for step in diagnostic['steps']))
        self.assertTrue(any('SimRuntime.iOS-18-5' in step.get('run', '') for step in diagnostic['steps']))

    def test_timeout_is_failure_even_after_successful_cleanup(self):
        process = Mock()
        process.wait.side_effect = subprocess.TimeoutExpired(['command'], 1)
        with patch.object(canary, 'cleanup_group') as cleanup:
            with self.assertRaises(subprocess.TimeoutExpired):
                canary.bounded_call(['command'], env={}, timeout=1, popen=Mock(return_value=process))
        cleanup.assert_called_once_with(process)

    def test_dead_leader_still_allows_driver_restoration_and_preserves_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / 'driver.py'
            child.write_text("""import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
native = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
def stop(signum, frame):
    (root / 'term').write_text('received')
    os.killpg(native.pid, signal.SIGTERM)
    native.wait(timeout=5)
    (root / 'restored').write_text('yes')
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
(root / 'ready').write_text(str(native.pid))
while True: time.sleep(0.05)
""")
            leader = root / 'leader.py'
            leader.write_text("""import subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
subprocess.Popen([sys.executable, str(root / 'driver.py'), str(root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
while not (root / 'ready').exists(): time.sleep(0.01)
sys.exit(65)
""")
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                canary.bounded_call([sys.executable, leader, root], env=dict(os.environ), timeout=10)
            self.assertEqual(raised.exception.returncode, 65)
            self.assertEqual((root / 'term').read_text(), 'received')
            self.assertEqual((root / 'restored').read_text(), 'yes')
            with self.assertRaises(ProcessLookupError):
                os.kill(int((root / 'ready').read_text()), 0)

    def test_failed_test_is_not_replaced_by_failed_report(self):
        original = subprocess.CalledProcessError(65, ['test'])
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            canary.test_and_report(Mock(side_effect=original), Mock(side_effect=ValueError('bad report')))
        self.assertIs(raised.exception, original)
        with self.assertRaisesRegex(ValueError, 'bad report'):
            canary.test_and_report(Mock(), Mock(side_effect=ValueError('bad report')))

    def test_exact_planned_built_executed_inventory(self):
        selected = selected_tests(plan_name=PLAN)
        self.assertEqual(len(selected), 4)
        self.assertTrue(all(count == 1 for count in selected.values()))
        for identifier in selected:
            suite, method = identifier.split('/')
            self.assertIn('func ' + method + '(', (ROOT / 'ShoppingTests' / (suite + '.swift')).read_text())
        data = {'TestPlan': {'Name': PLAN}, 'TestConfigurations': [{'TestTargets': [
            {'BlueprintName': 'ShoppingTests', 'OnlyTestIdentifiers': list(selected)}]}]}
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            path = products / 'plan.xctestrun'
            path.write_bytes(plistlib.dumps(data))
            verify_products(products, plan_name=PLAN)
            for ids in ([], list(selected)[:-1], list(selected) + [next(iter(selected))], ['Other/test']):
                broken = deepcopy(data)
                broken['TestConfigurations'][0]['TestTargets'][0]['OnlyTestIdentifiers'] = ids
                path.write_bytes(plistlib.dumps(broken))
                with self.assertRaises(ValueError):
                    verify_products(products, plan_name=PLAN)
        tests = [{'identifier': x + '()', 'bundle': 'ShoppingTests', 'result': 'Passed'} for x in selected]
        report = {'tests': tests, 'counts': {'totalTestCount': 4, 'passedTests': 4, 'failedTests': 0, 'skippedTests': 0}}
        verify_report(report, plan_name=PLAN)
        for mutation in ('skip', 'duplicate', 'missing', 'extra'):
            broken = deepcopy(report)
            if mutation == 'skip': broken['tests'][0]['result'] = 'Skipped'
            if mutation == 'duplicate': broken['tests'].append(tests[0])
            if mutation == 'missing': broken['tests'].pop()
            if mutation == 'extra': broken['tests'].append(dict(tests[0], identifier='Other/test'))
            with self.assertRaises(ValueError):
                verify_report(broken, plan_name=PLAN)

    def receipt(self):
        lines, events, fixtures = [], [], []
        for suite in ('HomeDetailsUITests', 'PersonalCartUITests'):
            lease = str(uuid.uuid4())
            base = dict(lease=lease, device='same-device', deviceSet='/same/set', original='medium')
            events += [dict(base, operation='acquire', observed='medium'),
                       dict(base, operation='set', category='large', observed='large'),
                       dict(base, operation='set', category='accessibility-extra-extra-extra-large', observed='accessibility-extra-extra-extra-large'),
                       dict(base, operation='restore', observed='medium')]
            fixtures.append(dict(test=suite, store='/tmp/' + str(uuid.uuid4()) + '/Shopping.sqlite', nonce=str(uuid.uuid4()), process=str(uuid.uuid4())))
        return events, fixtures

    def log(self, events, fixtures):
        return '\n'.join(['System text size: ' + json.dumps(e) for e in events] +
                         ['Compatibility fixture: ' + json.dumps(f) for f in fixtures] +
                         ['Simulator text-size command: ' + json.dumps({'seconds': 0.1})])

    def test_clean_pair_and_cross_test_contamination(self):
        events, fixtures = self.receipt()
        self.assertEqual(verify(self.log(events, fixtures), 'medium')['leases'], 2)
        for mutation in ('contaminated', 'missing_restore', 'parallel', 'same_store', 'missing_xxxl', 'error'):
            e, f = deepcopy(events), deepcopy(fixtures)
            if mutation == 'contaminated': e[4]['original'] = 'large'
            if mutation == 'missing_restore': e.pop()
            if mutation == 'parallel': e[4]['device'] = 'other-device'
            if mutation == 'same_store': f[1]['store'] = f[0]['store']
            if mutation == 'missing_xxxl': e.pop(2)
            if mutation == 'error': e[1]['error'] = 'transport defect'
            with self.assertRaises(ValueError, msg=mutation):
                verify(self.log(e, f), 'medium')
