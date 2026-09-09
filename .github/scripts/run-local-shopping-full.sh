#!/usr/bin/env bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ShoppingFull must run from a clean worktree so its result belongs to one exact commit." >&2
    exit 1
fi

commit_sha="$(git rev-parse HEAD)"
simulator_id="15066BE0-662A-4573-AA67-12E84FA0C39C"
result_bundle="$(mktemp -d "${TMPDIR:-/tmp}/shopping-full-${commit_sha}.XXXXXX")"
rmdir "$result_bundle"
snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/shopping-full-source-${commit_sha}.XXXXXX")"
trap 'rm -rf "$snapshot_root"' EXIT
git archive "$commit_sha" | tar -x -C "$snapshot_root"
cd "$snapshot_root"

xcodebuild test \
    -project Shopping.xcodeproj \
    -scheme Shopping \
    -testPlan ShoppingFull \
    -destination "platform=iOS Simulator,id=${simulator_id}" \
    -resultBundlePath "$result_bundle"

cd "$repository_root"
if [[ "$(git rev-parse HEAD)" != "$commit_sha" || -n "$(git status --porcelain)" ]]; then
    echo "HEAD or the worktree changed while ShoppingFull was running; no pass was recorded." >&2
    exit 1
fi

attestation_directory="$(git rev-parse --git-common-dir)/shopping-full-attestations"
mkdir -p "$attestation_directory"
{
    echo "sha=$commit_sha"
    echo "simulator=$simulator_id"
    echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
    echo "passed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "result_bundle=$result_bundle"
} > "$attestation_directory/$commit_sha"

echo "ShoppingFull passed for $commit_sha."
echo "After pushing this unchanged commit, run .github/scripts/dispatch-remote-shopping-full.sh."
