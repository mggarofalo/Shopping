"""Protect exact inventory, cross-test state and fail-before-launch ordering."""
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import uuid
from unittest.mock import Mock

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
