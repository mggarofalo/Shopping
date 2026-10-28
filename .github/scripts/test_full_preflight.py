import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('preflight', Path(__file__).with_name('require-full-preflight.py'))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class FullPreflightTests(unittest.TestCase):
    def run_record(self, **overrides):
        return dict({'id': 1, 'head_sha': 'candidate', 'event': 'workflow_dispatch',
                     'status': 'completed', 'conclusion': 'success',
                     'run_started_at': f"2026-10-28T00:00:{overrides.get('id', 1):02d}Z"}, **overrides)

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

    def test_partial_rerun_keeps_other_successful_job_from_same_run(self):
        build = dict(name='Build & Test', status='completed', conclusion='success')
        release = dict(name='Release SDK Build', status='completed', conclusion='success')
        attempts = {1: [dict(build, conclusion='failure'), release], 2: [build]}
        jobs = preflight.latest_required_jobs(2, attempts.__getitem__)
        preflight.require_jobs(jobs)
        self.assertEqual(jobs, [build, release])

    def test_old_success_never_masks_new_failed_or_skipped_job(self):
        for conclusion in ['failure', 'skipped', 'cancelled']:
            build = dict(name='Build & Test', status='completed', conclusion='success')
            release = dict(name='Release SDK Build', status='completed', conclusion='success')
            attempts = {1: [build, release], 2: [dict(build, conclusion=conclusion)]}
            with self.assertRaises(ValueError):
                preflight.require_jobs(preflight.latest_required_jobs(2, attempts.__getitem__))

    def test_duplicate_job_in_latest_attempt_is_not_hidden(self):
        build = dict(name='Build & Test', status='completed', conclusion='success')
        release = dict(name='Release SDK Build', status='completed', conclusion='success')
        with self.assertRaises(ValueError):
            preflight.require_jobs(preflight.latest_required_jobs(1, lambda _: [build, build, release]))

    def test_staged_preflight_ignores_only_named_diagnostics_not_newer_normal_failures(self):
        old = self.run_record(id=1)
        diagnostic = self.run_record(id=3, display_title='Shopping compatibility canary')
        self.assertEqual(preflight.successful_candidate([old, diagnostic], 'candidate', True), old)
        for status, conclusion in [('completed', 'failure'), ('completed', 'cancelled'), ('in_progress', None)]:
            newer = self.run_record(id=2, status=status, conclusion=conclusion, display_title='Shopping routine CI')
            with self.assertRaises(ValueError):
                preflight.successful_candidate([old, newer, diagnostic], 'candidate', True)
        unknown = self.run_record(id=4, conclusion='failure', display_title='Unrecognized diagnostic')
        with self.assertRaises(ValueError):
            preflight.successful_candidate([old, unknown], 'candidate', True)

    def test_older_normal_run_rerun_failure_supersedes_newer_created_success(self):
        old = self.run_record(id=1, run_started_at='2026-10-28T00:00:20Z')
        new = self.run_record(id=2)
        for status, conclusion in [('completed', 'failure'), ('queued', None), ('in_progress', None)]:
            with self.assertRaises(ValueError):
                preflight.successful_candidate([dict(old, status=status, conclusion=conclusion), new], 'candidate', True)

    def test_staged_preflight_requires_native_jobs_as_well_as_aggregates(self):
        names = preflight.REQUIRED_JOBS + preflight.NATIVE_JOBS
        jobs = [dict(name=name, status='completed', conclusion='success') for name in names]
        preflight.require_jobs(jobs, names)
        for native in preflight.NATIVE_JOBS:
            with self.assertRaises(ValueError):
                preflight.require_jobs([job for job in jobs if job['name'] != native], names)

    def test_preflight_precedes_expensive_operations(self):
        runner = Path(__file__).with_name('run-local-shopping-full.sh').read_text()
        self.assertLess(runner.index('require-full-preflight.py'), runner.index('mktemp'))
        self.assertLess(runner.index('require-full-preflight.py'), runner.index('xcrun simctl'))


if __name__ == '__main__':
    unittest.main()
