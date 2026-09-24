#!/usr/bin/env bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ShoppingFull must run from a clean worktree so its result belongs to one exact commit." >&2
    exit 1
fi

git_common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
commit_sha="$(git rev-parse HEAD)"
history_root="$git_common_dir/shopping-test-timings/$commit_sha"
mkdir -p "$history_root"
reports="$(mktemp -d "$history_root/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
export SHOPPING_TIMING_SHA="$commit_sha"
simulator_id="15066BE0-662A-4573-AA67-12E84FA0C39C"
artifacts="$(mktemp -d "${TMPDIR:-/tmp}/shopping-full-${commit_sha}.XXXXXX")"
result_bundle="$artifacts/Results.xcresult"
snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/shopping-full-source-${commit_sha}.XXXXXX")"
timing="$repository_root/.github/scripts/test-timing.py"
summary="$repository_root/.github/scripts/summarize-xcresult.sh"
phases="$reports/Phases.jsonl"
"$timing" init --plan ShoppingFull --json "$reports/Metadata.json"

finish() {
    local exit_code="$?"
    trap - EXIT
    set +e
    "$timing" run --phases "$phases" --phase summary -- \
        "$summary" \
        ShoppingFull "$result_bundle" "$artifacts/Build.log" "$artifacts/Test.log" \
        "$reports/Summary.md" "$reports/Summary.json" \
        "$artifacts/BuildSeconds.txt" "$artifacts/TestSeconds.txt"
    "$timing" report --plan ShoppingFull --metadata "$reports/Metadata.json" \
        --phases "$phases" --result "$result_bundle" \
        --json "$reports/Timing.json" --markdown "$reports/Timing.md"
    echo "ShoppingFull timing history: $reports"
    echo "ShoppingFull temporary artifacts: $artifacts"
    rm -rf "$snapshot_root"
    exit "$exit_code"
}
trap finish EXIT

# Keep Git provenance available to the app build without modifying the source worktree.
"$timing" run --phases "$phases" --phase snapshot -- bash -euo pipefail -c \
    'git clone --shared --no-checkout "$1" "$2"; git -C "$2" checkout --detach "$3"' \
    bash "$repository_root" "$snapshot_root" "$commit_sha"
cd "$snapshot_root"
# Run the committed helpers even if the original worktree changes during validation.
timing="$snapshot_root/.github/scripts/test-timing.py"
summary="$snapshot_root/.github/scripts/summarize-xcresult.sh"
"$timing" run --phases "$phases" --phase simulator -- \
    xcrun simctl bootstatus "$simulator_id" -b
"$timing" run --phases "$phases" --phase build --record-command \
    --log "$artifacts/Build.log" --seconds "$artifacts/BuildSeconds.txt" -- \
    xcodebuild build-for-testing -project Shopping.xcodeproj -scheme Shopping \
    -testPlan ShoppingFull -destination "platform=iOS Simulator,id=${simulator_id}" \
    -derivedDataPath "$snapshot_root/DerivedData"
"$timing" run --phases "$phases" --phase test --record-command \
    --log "$artifacts/Test.log" --seconds "$artifacts/TestSeconds.txt" -- \
    xcodebuild test-without-building -project Shopping.xcodeproj -scheme Shopping \
    -testPlan ShoppingFull -destination "platform=iOS Simulator,id=${simulator_id}" \
    -derivedDataPath "$snapshot_root/DerivedData" -resultBundlePath "$result_bundle"

cd "$repository_root"
if [[ "$(git rev-parse HEAD)" != "$commit_sha" || -n "$(git status --porcelain)" ]]; then
    echo "HEAD or the worktree changed while ShoppingFull was running; no pass was recorded." >&2
    exit 1
fi

attestation_directory="$git_common_dir/shopping-full-attestations"
mkdir -p "$attestation_directory"
{
    echo "sha=$commit_sha"
    echo "simulator=$simulator_id"
    echo "xcode=$(xcodebuild -version | tr '\n' ' ')"
    echo "passed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "result_bundle=$result_bundle"
    echo "timing_report=$reports/Timing.json"
} > "$attestation_directory/$commit_sha"

echo "ShoppingFull passed for $commit_sha."
echo "After pushing this unchanged commit, run .github/scripts/dispatch-remote-shopping-full.sh."
