#!/usr/bin/env python3
"""Check exact-source routine CI before spending an hour on local Full."""
import json
import re
import subprocess
import sys
from urllib.parse import urlencode


def successful_candidate(runs, sha):
    # PR runs test a synthetic merge commit. A manual run or main push tests
    # the stated head itself and can establish compiler compatibility here.
    candidates = [run for run in runs if run.get('head_sha') == sha
                  and (run.get('event') == 'workflow_dispatch'
                       or (run.get('event') == 'push' and run.get('head_branch') == 'main'))]
    if not candidates:
        raise ValueError('Run Swift CI on this exact branch commit before local Full')
    latest = max(candidates, key=lambda run: run['id'])
    if latest.get('status') != 'completed' or latest.get('conclusion') != 'success':
        raise ValueError('Latest exact-source Swift CI has not passed; wait or fix it before local Full')
    return latest


def require_jobs(jobs):
    for name in ('Build & Test', 'Release SDK Build'):
        matches = [job for job in jobs if job.get('name') == name]
        if len(matches) != 1 or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
            raise ValueError(f'Required job {name} has not passed exactly once')


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def main():
    sha = sys.argv[1] if len(sys.argv) == 2 else ''
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Expected the captured candidate SHA')
    repository = subprocess.check_output(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], text=True).strip()
    query = urlencode({'head_sha': sha, 'per_page': 100})
    runs = []
    page = 1
    while True:
        batch = api(f'repos/{repository}/actions/workflows/swift-ci.yml/runs?{query}&page={page}')['workflow_runs']
        runs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    run = successful_candidate(runs, sha)
    jobs = []
    page = 1
    while True:
        batch = api(f"repos/{repository}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100&page={page}")['jobs']
        jobs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    require_jobs(jobs)
    print(f"Exact-source Full preflight passed: {sha} {run['html_url']}")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Full preflight failed: {error}', file=sys.stderr)
        sys.exit(1)
