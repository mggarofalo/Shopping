#!/bin/bash

set -uo pipefail

plan_name="$1"
result_path="$2"
build_log="$3"
test_log="$4"
markdown_path="$5"
json_path="$6"
build_seconds_path="$7"
test_seconds_path="$8"

read_seconds() {
    local path="$1"
    if [[ -f "$path" ]]; then
        tr -cd '0-9' < "$path"
    else
        printf 'unknown'
    fi
}

build_seconds="$(read_seconds "$build_seconds_path")"
test_seconds="$(read_seconds "$test_seconds_path")"

if [[ -d "$result_path" ]] && xcrun xcresulttool get test-results summary --path "$result_path" > "$json_path"; then
    result="$(jq -r '.result // "Unknown"' "$json_path")"
    total="$(jq -r '.totalTestCount // 0' "$json_path")"
    passed="$(jq -r '.passedTests // 0' "$json_path")"
    failed="$(jq -r '.failedTests // 0' "$json_path")"
    skipped="$(jq -r '.skippedTests // 0' "$json_path")"
    duration="$(jq -r 'if .startTime and .finishTime then ((.finishTime - .startTime) | round | tostring) else "unknown" end' "$json_path")"
    environment="$(jq -r '.environmentDescription // "Not reported"' "$json_path")"

    {
        printf '# %s\n\n' "$plan_name"
        printf -- '- Result: %s\n' "$result"
        printf -- '- Tests: %s passed, %s failed, %s skipped, %s total\n' "$passed" "$failed" "$skipped" "$total"
        printf -- '- Build step: %s seconds\n' "$build_seconds"
        printf -- '- Test step: %s seconds\n' "$test_seconds"
        printf -- '- Test report: %s seconds\n' "$duration"
        printf -- '- Environment: %s\n' "$environment"

        failure_count="$(jq '[if (.testFailures | type) == "array" then .testFailures[] elif (.testFailures | type) == "object" then .testFailures else empty end] | length' "$json_path")"
        if [[ "$failure_count" -gt 0 ]]; then
            printf '\n## Failures\n\n'
            jq -r '
                if (.testFailures | type) == "array" then .testFailures[]
                elif (.testFailures | type) == "object" then .testFailures
                else empty
                end
                | [
                    "- `",
                    (.testIdentifierString // .name // "Unknown test"),
                    "`: ",
                    ((.failureText // "No failure detail") | gsub("[\\r\\n]+"; " "))
                ]
                | join("")
            ' "$json_path"
        fi
    } > "$markdown_path"
    exit 0
fi

printf '{"result":"No test result bundle"}\n' > "$json_path"
{
    printf '# %s\n\n' "$plan_name"
    printf -- '- Result: No test result bundle\n'
    printf -- '- Build step: %s seconds\n' "$build_seconds"
    printf -- '- Test step: %s seconds\n' "$test_seconds"
    printf '\n## Relevant log lines\n\n'
    for log_path in "$build_log" "$test_log"; do
        if [[ -f "$log_path" ]]; then
            grep -E '(^|[[:space:]])(error:|fatal error:|.*failed|.*failure)' "$log_path" | tail -20 | sed 's/^/- /'
        fi
    done
} > "$markdown_path"
