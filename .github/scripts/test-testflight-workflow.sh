#!/bin/bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
bash -n "$ROOT/.github/scripts/upload-testflight.sh"
for script in testflight-common preflight-testflight distribute-testflight audit-testflight-audience; do
    ruby -c "$ROOT/.github/scripts/$script.rb"
done
ruby "$ROOT/.github/scripts/test-testflight-workflow.rb"
ruby "$ROOT/.github/scripts/test-testflight-api.rb"
ruby "$ROOT/.github/scripts/test-testflight-audience-audit.rb"
python3 "$ROOT/.github/scripts/test-release-guards.py"
python3 "$ROOT/.github/scripts/test-upload-cleanup.py"
python3 "$ROOT/.github/scripts/test-build-identity.py"
python3 "$ROOT/.github/scripts/validate-cloudkit-sharing.py"
echo "TestFlight workflow checks passed."
