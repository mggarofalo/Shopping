"""Validate serial cross-test restoration and isolated fixture receipts."""
import json
import uuid


def records(log, prefix):
    return [json.loads(line.split(prefix, 1)[1]) for line in log.splitlines() if prefix in line]


def verify(log, initial, expected_device=None):
    requests = records(log, 'System text size: ')
    fixtures = records(log, 'Compatibility fixture: ')
    commands = records(log, 'Simulator text-size command: ')
    if len(fixtures) != 2 or len({f['store'] for f in fixtures}) != 2:
        raise ValueError('Expected two distinct isolated fixture stores')
    for key in ('nonce', 'process'):
        values = [f[key] for f in fixtures]
        if len(set(values)) != 2:
            raise ValueError(f'Expected independent {key} identities')
        for value in values:
            uuid.UUID(value)
    expected_suites = {'HomeDetailsUITests', 'PersonalCartUITests'}
    if not all(any(suite in f['test'] for f in fixtures) for suite in expected_suites):
        raise ValueError('Missing independent system-size test receipt')
    active = None
    leases = set()
    devices = set()
    categories = set()
    for r in requests:
        if r.get('error') or r.get('original') != initial:
            raise ValueError('Driver error or cross-test original category mismatch')
        devices.add((r['device'], r['deviceSet']))
        if r['operation'] == 'acquire':
            if active or r['lease'] in leases or r['observed'] != initial:
                raise ValueError('Overlapping or reused lease')
            active = r['lease']
            leases.add(active)
            categories = set()
        elif r['lease'] != active:
            raise ValueError('Operation outside its active lease')
        elif r['operation'] == 'set':
            if r['observed'] != r['category']:
                raise ValueError('Set readback mismatch')
            categories.add(r['observed'])
        elif r['operation'] == 'restore':
            if r['observed'] != initial or not {'large', 'accessibility-extra-extra-extra-large'} <= categories:
                raise ValueError('Incomplete category round trip')
            active = None
        else:
            raise ValueError('Unknown driver operation')
    if active or len(leases) != 2 or len(devices) != 1 or not commands:
        raise ValueError('Expected two restored serial leases on one simulator')
    if expected_device and next(iter(devices))[0].lower() != expected_device.lower():
        raise ValueError('Driver used a different simulator')
    pending_seconds = 0.0
    restoration_seconds = []
    for line in log.splitlines():
        if 'Simulator text-size command: ' in line:
            pending_seconds += json.loads(line.split('Simulator text-size command: ', 1)[1])['seconds']
        if 'System text size: ' in line:
            event = json.loads(line.split('System text size: ', 1)[1])
            if event['operation'] == 'restore':
                restoration_seconds.append(pending_seconds)
            pending_seconds = 0.0
    return {'restoration_host_seconds': restoration_seconds, 'original': initial, 'leases': len(leases), 'fixtures': fixtures,
            'device': next(iter(devices)), 'commands': commands,
            'host_command_seconds': sum(c['seconds'] for c in commands),
            'max_host_command_seconds': max(c['seconds'] for c in commands)}
