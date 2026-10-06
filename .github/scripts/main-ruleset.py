#!/usr/bin/env python3
"""Inspect or explicitly apply Shopping's required CI checks without replacing other rules."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys

POLICY = Path(__file__).resolve().parents[1] / 'main-ruleset.json'
WRITABLE = ('name', 'target', 'enforcement', 'conditions', 'rules', 'bypass_actors')


def desired_ruleset(current, policy):
    if (current.get('name') != 'main' or current.get('target') != 'branch'
            or current.get('enforcement') != 'active'
            or current.get('conditions') != {'ref_name': {'exclude': [], 'include': ['~DEFAULT_BRANCH']}}):
        raise ValueError('Unexpected ruleset scope; review it before changing policy')
    result = {key: deepcopy(current[key]) for key in WRITABLE}
    rules = result['rules']
    for kind in ('deletion', 'non_fast_forward', 'pull_request'):
        if sum(rule['type'] == kind for rule in rules) != 1:
            raise ValueError(f'Expected one existing {kind} rule')
    pull_request = next(rule for rule in rules if rule['type'] == 'pull_request')
    if pull_request['parameters']['required_approving_review_count'] != 0:
        raise ValueError('Approval policy changed; do not overwrite it automatically')
    matches = [rule for rule in rules if rule['type'] == 'required_status_checks']
    if len(matches) > 1:
        raise ValueError('Multiple status-check rules need manual reconciliation')
    if matches:
        checks_rule = matches[0]
    else:
        checks_rule = {'type': 'required_status_checks', 'parameters': {
            'strict_required_status_checks_policy': True, 'do_not_enforce_on_create': False,
            'required_status_checks': []}}
        rules.append(checks_rule)
    parameters = checks_rule['parameters']
    parameters['strict_required_status_checks_policy'] = True
    checks = parameters['required_status_checks']
    for expected in policy['required_status_checks']:
        existing = [check for check in checks if check['context'] == expected['context']]
        if len(existing) > 1:
            raise ValueError('Duplicate required check contexts need manual reconciliation')
        if existing:
            existing[0]['integration_id'] = expected['integration_id']
        else:
            checks.append(deepcopy(expected))
    return result


def api(path, payload=None):
    command = ['gh', 'api', path]
    if payload is not None:
        command += ['--method', 'PUT', '--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Update the existing live ruleset, then verify')
    parser.add_argument('--check', action='store_true', help='Fail if live policy differs; never write')
    args = parser.parse_args()
    if args.apply and args.check:
        parser.error('Choose apply or check')
    policy = json.loads(POLICY.read_text())
    path = f"repos/{policy['repository']}/rulesets/{policy['ruleset_id']}"
    current = api(path)
    desired = desired_ruleset(current, policy)
    actual = {key: current[key] for key in WRITABLE}
    if args.apply and desired != actual:
        # Refuse an observed concurrent change rather than replacing someone else's edits.
        if api(path) != current:
            raise ValueError('Ruleset changed during review; rerun against the new policy')
        api(path, desired)
        current = api(path)
        actual = {key: current[key] for key in WRITABLE}
        if desired != actual:
            raise ValueError('Ruleset read-back differs from the applied policy')
    print(json.dumps(desired, indent=2))
    if args.check and desired != actual:
        raise ValueError('Required CI policy is not active')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Ruleset validation failed: {error}', file=sys.stderr)
        sys.exit(1)
