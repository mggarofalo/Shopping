#!/usr/bin/env python3
"""Check exact-source routine CI before spending an hour on local Full."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlencode

sys.dont_write_bytecode = True
from staged_validation import require_pinned_canary, NATIVE_JOBS, execution_key


ROOT = Path(__file__).resolve().parents[2]
REQUIRED_JOBS = ('Build & Test', 'Release SDK Build')


def candidate_runs(runs, sha, ignore_diagnostics=False):
    # PR runs test a synthetic merge commit. A manual run or main push tests
    # the stated head itself and can establish compiler compatibility here.
    candidates = [run for run in runs if run.get('head_sha') == sha
                  and (run.get('event') == 'workflow_dispatch'
                       or (run.get('event') == 'push' and run.get('head_branch') == 'main'))]
    if ignore_diagnostics:
        diagnostic_titles = {'Shopping compatibility canary', 'Shopping Siri diagnostic'}
        candidates = [run for run in candidates if run.get('display_title') not in diagnostic_titles]
    return candidates


def successful_candidate(runs, sha, ignore_diagnostics=False):
    candidates = candidate_runs(runs, sha, ignore_diagnostics)
    if not candidates:
        raise ValueError('Run Swift CI on this exact branch commit before local Full')
    latest = max(candidates, key=execution_key)
    newest_time = execution_key(latest)[0]
    ambiguous_failure = any(execution_key(run)[0] == newest_time and
                            (run.get('status') != 'completed' or run.get('conclusion') != 'success') for run in candidates)
    if ambiguous_failure:
        raise ValueError('Latest exact-source Swift CI has not passed; wait or fix it before local Full')
    return latest


def require_jobs(jobs, names=REQUIRED_JOBS):
    for name in names:
        matches = [job for job in jobs if job.get('name') == name]
        if len(matches) != 1 or matches[0].get('status') != 'completed' or matches[0].get('conclusion') != 'success':
            raise ValueError(f'Required job {name} has not passed exactly once')


def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], cwd=ROOT, text=True, timeout=60))


def latest_required_jobs(last_attempt, fetch, names=REQUIRED_JOBS):
    """A partial rerun retains successful jobs from earlier attempts of this run."""
    jobs = []
    for attempt in range(last_attempt, 0, -1):
        missing = set(names) - {job.get('name') for job in jobs}
        if not missing:
            break
        jobs.extend(job for job in fetch(attempt) if job.get('name') in missing)
    return jobs


def retained_job_evidence(run, names, fetch_jobs, fetch_attempt):
    jobs = []
    for attempt in range(run['run_attempt'], 0, -1):
        missing = set(names) - {job['name'] for job in jobs}
        if not missing:
            break
        batch = [dict(job, evidence_attempt=attempt) for job in fetch_jobs(run['id'], attempt)
                 if job.get('name') in missing]
        for job in batch:
            if not job.get('started_at'):
                if job.get('conclusion') == 'success':
                    raise ValueError('Successful job lacks execution chronology')
                execution = run if attempt == run['run_attempt'] else fetch_attempt(run['id'], attempt)
                job['started_at'] = execution['run_started_at']
        jobs.extend(batch)
    return jobs


def job_time(job):
    return execution_key({'id': job.get('id', 0), 'run_started_at': job['started_at']})[0]


def require_current_job_evidence(runs, candidate, sha, names, fetch_jobs, fetch_attempt):
    """One run supplies positives; every later adverse event remains relevant."""
    own = retained_job_evidence(candidate, names, fetch_jobs, fetch_attempt)
    require_jobs(own, names)
    owned_times = {job['name']: job_time(job) for job in own}
    for run in candidate_runs(runs, sha, True):
        for attempt in range(1, run['run_attempt'] + 1):
            jobs = [dict(job) for job in fetch_jobs(run['id'], attempt) if job.get('name') in names]
            execution = None
            def attempt_record():
                nonlocal execution
                if execution is None:
                    execution = run if attempt == run['run_attempt'] else fetch_attempt(run['id'], attempt)
                    if (execution.get('id'), execution.get('head_sha'), execution.get('run_attempt')) != (run['id'], sha, attempt):
                        raise ValueError('Wrong required-job execution record')
                return execution
            # While a rerun has not published its job selection, old retained
            # jobs cannot establish what this unfinished attempt will validate.
            if attempt == run['run_attempt'] and run.get('status') != 'completed':
                missing = set(names) - {job['name'] for job in jobs}
                jobs.extend({'name': name, 'status': run.get('status'), 'conclusion': None,
                             'started_at': run['run_started_at']} for name in missing)
            elif not jobs:
                metadata = attempt_record()
                if metadata.get('conclusion') != 'success':
                    jobs = [{'name': name, 'status': metadata.get('status'), 'conclusion': None,
                             'started_at': metadata['run_started_at']} for name in names]
            for job in jobs:
                if job.get('status') == 'completed' and job.get('conclusion') == 'success':
                    continue  # Another run's success cannot refresh owned proof.
                if not job.get('started_at'):
                    job['started_at'] = attempt_record()['run_started_at']
                if job_time(job) >= owned_times[job['name']]:
                    raise ValueError('Adverse execution is newer than candidate-owned proof: ' + job['name'])
    return own


def jobs_for_attempt(repository, run_id, attempt):
    jobs = []
    page = 1
    while True:
        batch = api(f'repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}')['jobs']
        jobs.extend(batch)
        if len(batch) < 100:
            return jobs
        page += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sha')
    parser.add_argument('--pinned-canary', action='store_true')
    args = parser.parse_args()
    sha = args.sha
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Expected the captured candidate SHA')
    repository = subprocess.check_output(['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], cwd=ROOT, text=True, timeout=60).strip()
    query = urlencode({'head_sha': sha, 'per_page': 100})
    runs = []
    page = 1
    while True:
        batch = api(f'repos/{repository}/actions/workflows/swift-ci.yml/runs?{query}&page={page}')['workflow_runs']
        runs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    run = successful_candidate(runs, sha, ignore_diagnostics=args.pinned_canary)
    if args.pinned_canary:
        names = REQUIRED_JOBS + NATIVE_JOBS + ('Deterministic validation prerequisites',)
        cache = {}
        def fetch_jobs(run_id, attempt):
            key = run_id, attempt
            if key not in cache:
                cache[key] = jobs_for_attempt(repository, run_id, attempt)
            return cache[key]
        require_current_job_evidence(runs, run, sha, names, fetch_jobs,
            lambda run_id, attempt: api(f'repos/{repository}/actions/runs/{run_id}/attempts/{attempt}'))
        require_pinned_canary(repository, sha)
    else:
        jobs = latest_required_jobs(run['run_attempt'],
                                    lambda attempt: jobs_for_attempt(repository, run['id'], attempt))
        require_jobs(jobs)
    print(f"Exact-source Full preflight passed: {sha} {run['html_url']}")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'Full preflight failed: {error}', file=sys.stderr)
        sys.exit(1)
