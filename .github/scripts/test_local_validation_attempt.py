"""Known supported local failures block stale receipts without a global database."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from local_validation_attempt import LocalAttempt, ReceiptReservation, require_latest

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

    def test_full_reservation_validates_under_owner_and_blocks_writers(self):
        paths = self.passed_attempt()
        before = (self.root / 'Latest.json').read_bytes()
        lease = ReceiptReservation(self.root).__enter__()
        # Shell entrypoints pass this opaque token between reserve and EXIT.
        owner = ReceiptReservation(self.root, lease.token)
        require_latest(self.root, SHA, VERSION, paths, reservation=owner)
        with self.assertRaises(ValueError):
            with LocalAttempt(self.root, SHA, VERSION, self.output): self.fail('Writer entered Full')
        with self.assertRaises(ValueError): ReceiptReservation(self.root).release()
        with self.assertRaises(ValueError): require_latest(self.root, SHA, VERSION, paths)
        owner.release()
        self.assertEqual((self.root / 'Latest.json').read_bytes(), before)
        require_latest(self.root, SHA, VERSION, paths)

    def test_reservation_error_preserves_marker_and_primary_error(self):
        self.passed_attempt()
        before = (self.root / 'Latest.json').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'preflight failed'):
            with ReceiptReservation(self.root): raise RuntimeError('preflight failed')
        self.assertEqual((self.root / 'Latest.json').read_bytes(), before)
        self.assertFalse((self.root / 'attempt.lock').exists())
        with self.assertRaisesRegex(RuntimeError, 'primary'):
            with ReceiptReservation(self.root) as lease:
                with patch.object(lease, 'release', side_effect=OSError('release failed')):
                    lease.__exit__(RuntimeError, RuntimeError('primary'), None)
                raise RuntimeError('primary')

    def test_full_helpers_hold_reservation_until_exit_including_early_errors(self):
        scripts = Path(__file__).resolve().parent
        for name in ('run-local-shopping-full.sh', 'dispatch-remote-shopping-full.sh'):
            source = (scripts / name).read_text()
            self.assertLess(source.index('staged_validation.py reserve'), source.index('require-full-preflight.py'))
            self.assertLess(source.index('trap release_receipts EXIT'), source.index('require-full-preflight.py'))
            self.assertIn('staged_validation.py release "$commit_sha" "$receipt_token"', source)
            self.assertIn('if [[ "$exit_code" -eq 0 ]]; then exit_code="$release_code"; fi', source)
        local = (scripts / 'run-local-shopping-full.sh').read_text()
        finish = local[local.index('finish()'):local.index('trap finish EXIT')]
        self.assertIn('staged_validation.py release', finish)

    def test_incomplete_pair_cannot_mark_attempt_passed(self):
        with self.assertRaises(ValueError):
            with LocalAttempt(self.root, SHA, VERSION, self.output) as attempt:
                attempt.complete({'fixtures': next(iter(self.receipts(attempt).values()))})
        self.assertEqual(json.loads((self.root / 'Latest.json').read_text())['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
