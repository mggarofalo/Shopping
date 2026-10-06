"""Required check reconciliation must preserve unrelated repository protection."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('ruleset', Path(__file__).with_name('main-ruleset.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RulesetTests(unittest.TestCase):
    def setUp(self):
        self.current = {
            'name': 'main', 'target': 'branch', 'enforcement': 'active',
            'conditions': {'ref_name': {'exclude': [], 'include': ['~DEFAULT_BRANCH']}},
            'bypass_actors': [], 'id': 12,
            'rules': [{'type': 'deletion'}, {'type': 'non_fast_forward'},
                      {'type': 'pull_request', 'parameters': {'required_approving_review_count': 0,
                       'dismiss_stale_reviews_on_push': True}}]}
        self.policy = {'required_status_checks': [{'context': 'Build & Test', 'integration_id': 15368},
                                                 {'context': 'Release SDK Build', 'integration_id': 15368}]}

    def test_adds_required_checks_without_changing_existing_protection(self):
        original = deepcopy(self.current)
        desired = module.desired_ruleset(self.current, self.policy)
        self.assertEqual(self.current, original)
        self.assertEqual(desired['rules'][:-1], original['rules'])
        self.assertEqual(desired['bypass_actors'], [])
        self.assertNotIn('id', desired)
        self.assertEqual(desired['rules'][-1]['parameters']['required_status_checks'], self.policy['required_status_checks'])
        self.assertTrue(desired['rules'][-1]['parameters']['strict_required_status_checks_policy'])
        self.assertFalse(desired['rules'][-1]['parameters']['do_not_enforce_on_create'])
        self.assertEqual(module.desired_ruleset(desired, self.policy), desired)

    def test_preserves_other_checks_and_binds_our_checks_to_actions(self):
        self.current['rules'].append({'type': 'required_status_checks', 'parameters': {
            'strict_required_status_checks_policy': False, 'do_not_enforce_on_create': True,
            'required_status_checks': [{'context': 'Other', 'integration_id': 42},
                                       {'context': 'Build & Test', 'integration_id': None}]}})
        desired = module.desired_ruleset(self.current, self.policy)
        parameters = desired['rules'][-1]['parameters']
        self.assertEqual(parameters['required_status_checks'][0], {'context': 'Other', 'integration_id': 42})
        self.assertEqual(parameters['required_status_checks'][1]['integration_id'], 15368)
        self.assertTrue(parameters['do_not_enforce_on_create'])

    def test_refuses_changed_scope_approval_or_missing_protection(self):
        for field, value in [('enforcement', 'disabled'), ('target', 'tag'), ('conditions', {})]:
            changed = deepcopy(self.current)
            changed[field] = value
            with self.assertRaises(ValueError):
                module.desired_ruleset(changed, self.policy)
        self.current['rules'][-1]['parameters']['required_approving_review_count'] = 1
        with self.assertRaises(ValueError):
            module.desired_ruleset(self.current, self.policy)
        self.current['rules'].pop()
        with self.assertRaises(ValueError):
            module.desired_ruleset(self.current, self.policy)


if __name__ == '__main__':
    unittest.main()
