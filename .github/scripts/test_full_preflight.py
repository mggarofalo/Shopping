import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('preflight', Path(__file__).with_name('require-full-preflight.py'))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class FullPreflightTests(unittest.TestCase):
    def run_record(self, **overrides):
        return dict({'id': 1, 'head_sha': 'candidate', 'event': 'workflow_dispatch',
                     'status': 'completed', 'conclusion': 'success'}, **overrides)

    def test_exact_manual_source_passes(self):
        run = self.run_record()
        self.assertEqual(preflight.successful_candidate([run], 'candidate'), run)

    def test_other_sha_and_synthetic_merge_proof_are_rejected(self):
        for run in [self.run_record(head_sha='old'), self.run_record(event='pull_request')]:
            with self.assertRaises(ValueError):
                preflight.successful_candidate([run], 'candidate')

    def test_latest_failure_or_pending_run_invalidates_previous_pass(self):
        for changes in [{'conclusion': 'failure'}, {'status': 'in_progress'}, {'conclusion': 'cancelled'}]:
            with self.assertRaises(ValueError):
                preflight.successful_candidate([self.run_record(), self.run_record(id=2, **changes)], 'candidate')

    def test_main_push_is_valid_but_other_push_is_not(self):
        preflight.successful_candidate([self.run_record(event='push', head_branch='main')], 'candidate')
        with self.assertRaises(ValueError):
            preflight.successful_candidate([self.run_record(event='push', head_branch='feature')], 'candidate')

    def test_both_compilers_must_have_completed_successfully(self):
        jobs = [dict(name=name, status='completed', conclusion='success')
                for name in ('Build & Test', 'Release SDK Build')]
        preflight.require_jobs(jobs)
        for invalid in [jobs[:1], jobs + jobs[:1], [jobs[0], dict(jobs[1], conclusion='skipped')]]:
            with self.assertRaises(ValueError):
                preflight.require_jobs(invalid)

    def test_preflight_precedes_expensive_operations(self):
        runner = Path(__file__).with_name('run-local-shopping-full.sh').read_text()
        self.assertLess(runner.index('require-full-preflight.py'), runner.index('mktemp'))
        self.assertLess(runner.index('require-full-preflight.py'), runner.index('xcrun simctl'))


if __name__ == '__main__':
    unittest.main()
