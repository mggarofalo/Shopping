#!/usr/bin/env python3
"""Exercise provenance in normal, detached, incremental, and worktree builds."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd, env=None, succeeds=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    return result.stdout.strip()


with tempfile.TemporaryDirectory() as temporary:
    repo = Path(temporary) / 'repo'
    repo.mkdir()
    run('git', 'init', '-b', 'main', cwd=repo)
    run('git', 'config', 'user.email', 'test@example.invalid', cwd=repo)
    run('git', 'config', 'user.name', 'Build identity test', cwd=repo)
    (repo / '.github/scripts').mkdir(parents=True)
    guard = repo / '.github/scripts/validate-release-source.sh'
    shutil.copy(ROOT / '.github/scripts/validate-release-source.sh', guard)
    run('git', 'add', '.', cwd=repo)
    run('git', 'commit', '-m', 'Initial fixture', cwd=repo)
    sha = run('git', 'rev-parse', 'HEAD', cwd=repo)
    output = Path(temporary) / 'products'
    env = dict(os.environ, SRCROOT=str(repo), TARGET_BUILD_DIR=str(output),
               UNLOCALIZED_RESOURCES_FOLDER_PATH='Shopping.app', GITHUB_ACTIONS='false')

    def write(expected):
        run('bash', str(ROOT / 'scripts/write-build-identity.sh'), cwd=repo, env=env)
        assert (output / 'Shopping.app/BuildCommit.txt').read_text().strip() == expected

    write(sha)
    run('bash', str(guard), cwd=repo, env=env)
    (repo / 'local-edit').write_text('dirty')
    write(sha + '-dirty')
    run('bash', str(guard), cwd=repo, env=env, succeeds=False)
    run('git', 'add', '.', cwd=repo)
    run('git', 'commit', '-m', 'Next commit', cwd=repo)
    sha = run('git', 'rev-parse', 'HEAD', cwd=repo)
    write(sha)
    run('git', 'checkout', '--detach', cwd=repo)
    write(sha)
    run('bash', str(guard), cwd=repo, env=env, succeeds=False)
    ci = dict(env, GITHUB_ACTIONS='true', GITHUB_REF='refs/heads/main', GITHUB_SHA=sha)
    run('bash', str(guard), cwd=repo, env=ci)
    run('bash', str(guard), cwd=repo, env=dict(ci, GITHUB_REF='refs/heads/feature'), succeeds=False)
    run('bash', str(guard), cwd=repo, env=dict(ci, GITHUB_SHA='0' * 40), succeeds=False)
    worktree = Path(temporary) / 'worktree'
    run('git', 'worktree', 'add', '-b', 'development', str(worktree), cwd=repo)
    env['SRCROOT'] = str(worktree)
    write(sha)
    missing = Path(temporary) / 'no-git'
    missing.mkdir()
    env['SRCROOT'] = str(missing)
    run('bash', str(ROOT / 'scripts/write-build-identity.sh'), cwd=repo, env=env, succeeds=False)

print('Build identity checks passed.')
