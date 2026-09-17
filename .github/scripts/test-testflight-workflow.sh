#!/bin/bash

set -euo pipefail

readonly REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WORKFLOW_PATH="$REPOSITORY_ROOT/.github/workflows/testflight.yml"
readonly UPLOAD_SCRIPT_PATH="$REPOSITORY_ROOT/.github/scripts/upload-testflight.sh"

ruby -e 'require "yaml"; YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)' "$WORKFLOW_PATH"
bash -n "$UPLOAD_SCRIPT_PATH"

assert_contains() {
    local expected="$1"
    local path="$2"

    if ! grep -Fq -- "$expected" "$path"; then
        echo "$path must contain: $expected" >&2
        exit 1
    fi
}

assert_contains "workflow_dispatch:" "$WORKFLOW_PATH"
assert_contains 'if: ${{ inputs.confirm_upload }}' "$WORKFLOW_PATH"
assert_contains "environment: testflight" "$WORKFLOW_PATH"
assert_contains "contents: read" "$WORKFLOW_PATH"
assert_contains "cancel-in-progress: false" "$WORKFLOW_PATH"

if grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$WORKFLOW_PATH"; then
    echo "$WORKFLOW_PATH must remain manually dispatched only." >&2
    exit 1
fi

for secret_name in \
    APP_STORE_CONNECT_API_ISSUER_ID \
    APP_STORE_CONNECT_API_KEY_ID \
    APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 \
    APP_STORE_PROVISIONING_PROFILE_BASE64 \
    APPLE_DISTRIBUTION_CERTIFICATE_BASE64 \
    APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD; do
    assert_contains "secrets.$secret_name" "$WORKFLOW_PATH"
done

assert_contains "trap cleanup EXIT" "$UPLOAD_SCRIPT_PATH"
assert_contains 'security delete-keychain "$KEYCHAIN_PATH"' "$UPLOAD_SCRIPT_PATH"
assert_contains "-t agg" "$UPLOAD_SCRIPT_PATH"
assert_contains "xcrun altool --validate-app" "$UPLOAD_SCRIPT_PATH"
assert_contains "xcrun altool --upload-app" "$UPLOAD_SCRIPT_PATH"

if missing_output="$(env -i PATH="$PATH" bash "$UPLOAD_SCRIPT_PATH" 2>&1)"; then
    echo "$UPLOAD_SCRIPT_PATH must reject missing configuration." >&2
    exit 1
fi
assert_contains "Required environment variable APP_STORE_CONNECT_API_ISSUER_ID is not configured." <(printf '%s' "$missing_output")

if invalid_build_output="$(env -i \
    PATH="$PATH" \
    APP_STORE_CONNECT_API_ISSUER_ID=value \
    APP_STORE_CONNECT_API_KEY_ID=value \
    APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64=value \
    APP_STORE_PROVISIONING_PROFILE_BASE64=value \
    APPLE_DISTRIBUTION_CERTIFICATE_BASE64=value \
    APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD=value \
    BUILD_NUMBER=0 \
    bash "$UPLOAD_SCRIPT_PATH" 2>&1)"; then
    echo "$UPLOAD_SCRIPT_PATH must reject an invalid build number." >&2
    exit 1
fi
assert_contains "BUILD_NUMBER must be a positive integer." <(printf '%s' "$invalid_build_output")

echo "TestFlight workflow checks passed."
