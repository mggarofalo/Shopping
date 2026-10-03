#!/usr/bin/env python3
"""Require successful push-to-main Swift CI for the dispatched source SHA."""
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlencode


def require_ci(runs, jobs, sha):
    candidates = [run for run in runs if run.get("head_sha") == sha
                  and run.get("head_branch") == "main" and run.get("event") == "push"]
    if not candidates:
        raise ValueError("No push-to-main Swift CI run exists for the release SHA")
    latest = max(candidates, key=lambda run: run["id"])
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("Latest exact-source Swift CI has not passed; wait or diagnose it before release")
    by_name = {job["name"]: job for job in jobs}
    for name in ["Release SDK Build", "Build & Test"]:
        if name not in by_name or by_name[name].get("conclusion") != "success" or by_name[name].get("status") != "completed":
            raise ValueError(f"Required CI job {name} has not passed")
    return latest


def api(path):
    # gh handles the existing GitHub token; no token is interpolated or logged.
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Cannot read release CI; GitHub Actions read permission is required")
    return json.loads(result.stdout)


def main():
    repository, sha = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid release repository/source identity")
    query = urlencode({"head_sha": sha, "branch": "main", "event": "push", "per_page": 100})
    runs = api(f"repos/{repository}/actions/workflows/swift-ci.yml/runs?{query}")["workflow_runs"]
    candidates = [run for run in runs if run.get("head_sha") == sha and run.get("head_branch") == "main" and run.get("event") == "push"]
    if not candidates:
        raise ValueError("No push-to-main Swift CI run exists for the release SHA")
    latest = max(candidates, key=lambda run: run["id"])
    jobs = []
    page = 1
    while True:
        batch = api(f"repos/{repository}/actions/runs/{latest['id']}/attempts/{latest['run_attempt']}/jobs?per_page=100&page={page}")["jobs"]
        jobs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    require_ci(runs, jobs, sha)
    print(f"Release CI passed for {sha}: {latest['html_url']}")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, json.JSONDecodeError) as error:
        print(f"Release CI gate failed: {error}", file=sys.stderr)
        sys.exit(1)
