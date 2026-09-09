#!/usr/bin/env bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Refusing to attest a dirty worktree." >&2
    exit 1
fi

branch="$(git symbolic-ref --quiet --short HEAD)" || {
    echo "Refusing to dispatch from a detached HEAD." >&2
    exit 1
}
commit_sha="$(git rev-parse HEAD)"
attestation="$(git rev-parse --git-common-dir)/shopping-full-attestations/$commit_sha"

if [[ ! -f "$attestation" ]] || ! grep -Fxq "sha=$commit_sha" "$attestation"; then
    echo "No local ShoppingFull pass is recorded for $commit_sha." >&2
    exit 1
fi

remote_sha="$(git ls-remote --heads origin "refs/heads/$branch" | awk '{print $1}')"
if [[ "$remote_sha" != "$commit_sha" ]]; then
    echo "origin/$branch does not point to locally attested commit $commit_sha." >&2
    exit 1
fi

repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
gh api --method POST "repos/$repository/statuses/$commit_sha" \
    -f state=success \
    -f context='local/ShoppingFull' \
    -f description='ShoppingFull passed locally on the pinned simulator' >/dev/null

gh workflow run swift-exhaustive.yml \
    --ref "$branch" \
    -f suite=full

echo "Dispatched remote ShoppingFull for $commit_sha."
