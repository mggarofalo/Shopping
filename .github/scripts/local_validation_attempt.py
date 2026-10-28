"""Serialize supported local staged attempts; known failures invalidate reuse."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import uuid


def receipt_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    temporary = path.with_name(path.name + '.tmp-' + str(uuid.uuid4()))
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


class ReceiptReservation:
    """Same directory lock as writers, with a token for cross-process release."""
    def __init__(self, root, token=None):
        self.root = root
        self.lock = root / 'attempt.lock'
        self.token = token or str(uuid.uuid4())

    def __enter__(self):
        self.root.mkdir(parents=True, exist_ok=True)
        try:
            self.lock.mkdir()
        except FileExistsError as error:
            raise ValueError('Local receipt owner is active or crashed') from error
        # A crash before publishing the token deliberately leaves a closed lock.
        (self.lock / 'owner').write_text(self.token)
        return self

    def verify_owner(self):
        if (self.lock / 'owner').read_text() != self.token:
            raise ValueError('Receipt reservation belongs to another owner')

    def release(self):
        self.verify_owner()
        (self.lock / 'owner').unlink()
        self.lock.rmdir()

    def __exit__(self, kind, error, traceback):
        try:
            self.release()
        except BaseException as cleanup_error:
            if error is None:
                raise
            error.add_note(f'Receipt reservation cleanup failed: {cleanup_error}')
        return False


class LocalAttempt:
    def __init__(self, root, sha, version, artifacts):
        self.root = root
        self.reservation = ReceiptReservation(root)
        self.lock = self.reservation.lock
        self.record = {'schema_version': 1, 'id': str(uuid.uuid4()), 'sha': sha,
                       'gate_version': version, 'status': 'running', 'pid': os.getpid(),
                       'started_at': datetime.now(timezone.utc).isoformat(), 'artifacts': str(artifacts)}

    @property
    def id(self):
        return self.record['id']

    def save(self):
        history = self.root / 'attempts'
        history.mkdir(exist_ok=True)
        write_json(history / (self.id + '.json'), self.record)
        write_json(self.root / 'Latest.json', self.record)

    def __enter__(self):
        self.reservation.__enter__()
        # A crash after locking remains fail-closed, even before this write.
        self.save()
        return self

    def complete(self, receipts):
        if set(receipts) != {'fixtures', 'canary'}:
            raise ValueError('Both current local receipts are required')
        for path in receipts.values():
            receipt = json.loads(path.read_text())
            if receipt.get('local_attempt') != self.id or receipt.get('sha') != self.record['sha'] or receipt.get('gate_version') != self.record['gate_version']:
                raise ValueError('Receipt does not belong to this local attempt')
        self.record.update(status='passed', receipts={kind: receipt_digest(path) for kind, path in receipts.items()})
        self.save()

    def __exit__(self, kind, error, traceback):
        if error is not None or self.record['status'] != 'passed':
            status = 'cancelled' if isinstance(error, (KeyboardInterrupt, InterruptedError)) else 'failed'
            self.record.update(status=status, error=str(error) if error else 'No completed receipt pair')
            try:
                self.save()
            except OSError:
                # Leave the lock fail-closed if failure persistence is broken,
                # and preserve the original native/cancellation exception.
                if error is not None:
                    return False
                raise
        self.reservation.__exit__(kind, error, traceback)
        if error is None and self.record['status'] != 'passed':
            raise ValueError('Local attempt ended without passing receipts')
        return False


def require_latest(root, sha, version, receipts, reservation=None):
    if reservation is not None:
        if reservation.root != root:
            raise ValueError('Wrong receipt reservation root')
        reservation.verify_owner()
    elif (root / 'attempt.lock').exists():
        raise ValueError('Latest supported local attempt is running or crashed')
    record = json.loads((root / 'Latest.json').read_text())
    if (record.get('schema_version'), record.get('sha'), record.get('gate_version'), record.get('status')) != (1, sha, version, 'passed'):
        raise ValueError('Latest supported local attempt has not passed for this candidate')
    uuid.UUID(record['id'])
    if set(receipts) != {'fixtures', 'canary'} or set(record.get('receipts', {})) != set(receipts):
        raise ValueError('Incomplete local attempt receipt pair')
    for kind, path in receipts.items():
        if json.loads(path.read_text()).get('local_attempt') != record['id'] or receipt_digest(path) != record['receipts'][kind]:
            raise ValueError('Receipt is stale relative to the latest supported local attempt')
    return record
