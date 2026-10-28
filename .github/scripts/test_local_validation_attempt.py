"""Known supported local failures block stale receipts without a global database."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from local_validation_attempt import LocalAttempt, require_latest

SHA = 'a' * 40
VERSION = 'v1'


class LocalAttemptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / 'records'
        self.output = Path(temporary.name) / 'artifacts'
        self.output.mkdir()

    def receipts(self, attempt):
        paths = {}
        for kind in ('fixtures', 'canary'):
            path = self.output / (kind + '-' + attempt.id + '.json')
            path.write_text(json.dumps({'sha': SHA, 'gate_version': VERSION, 'local_attempt': attempt.id, 'kind': kind}))
            paths[kind] = path
        return paths

    def passed_attempt(self):
        with LocalAttempt(self.root, SHA, VERSION, self.output) as attempt:
            paths = self.receipts(attempt)
            attempt.complete(paths)
        require_latest(self.root, SHA, VERSION, paths)
        return paths

    def test_newer_failed_or_cancelled_attempt_rejects_old_explicit_paths(self):
        prior = self.passed_attempt()
        for failure in (RuntimeError('native failed'), InterruptedError('cancelled'), KeyboardInterrupt()):
            with self.assertRaises(type(failure)):
                with LocalAttempt(self.root, SHA, VERSION, self.output):
                    with self.assertRaises(ValueError): require_latest(self.root, SHA, VERSION, prior)
                    raise failure
            with self.assertRaises(ValueError): require_latest(self.root, SHA, VERSION, prior)
            self.assertFalse((self.root / 'attempt.lock').exists())
        self.assertEqual(len(list((self.root / 'attempts').glob('*.json'))), 4)

    def test_new_pass_binds_current_pair_and_rejects_older_receipts(self):
        old = self.passed_attempt()
        new = self.passed_attempt()
        require_latest(self.root, SHA, VERSION, new)
        with self.assertRaises(ValueError): require_latest(self.root, SHA, VERSION, old)
        new['fixtures'].write_text(new['fixtures'].read_text() + ' ')
        with self.assertRaises(ValueError): require_latest(self.root, SHA, VERSION, new)

    def test_lock_serializes_attempts_and_crash_remains_fail_closed(self):
        prior = self.passed_attempt()
        owner = LocalAttempt(self.root, SHA, VERSION, self.output)
        owner.__enter__()  # Simulate a crash before __exit__.
        with self.assertRaises(ValueError):
            with LocalAttempt(self.root, SHA, VERSION, self.output): self.fail('Concurrent owner entered')
        record = json.loads((self.root / 'Latest.json').read_text())
        self.assertEqual(record['id'], owner.id)
        self.assertEqual(record['status'], 'running')
        with self.assertRaises(ValueError): require_latest(self.root, SHA, VERSION, prior)

    def test_failure_to_persist_cancellation_keeps_lock_and_original_error(self):
        failure = InterruptedError('original cancellation')
        attempt = LocalAttempt(self.root, SHA, VERSION, self.output)
        attempt.__enter__()
        with self.assertRaises(InterruptedError) as raised:
            with patch.object(attempt, 'save', side_effect=OSError('disk full')):
                try:
                    raise failure
                except InterruptedError as error:
                    if not attempt.__exit__(type(error), error, None):
                        raise
        self.assertIs(raised.exception, failure)
        self.assertTrue((self.root / 'attempt.lock').exists())
        with self.assertRaises(ValueError):
            require_latest(self.root, SHA, VERSION, {})

    def test_incomplete_pair_cannot_mark_attempt_passed(self):
        with self.assertRaises(ValueError):
            with LocalAttempt(self.root, SHA, VERSION, self.output) as attempt:
                attempt.complete({'fixtures': next(iter(self.receipts(attempt).values()))})
        self.assertEqual(json.loads((self.root / 'Latest.json').read_text())['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
