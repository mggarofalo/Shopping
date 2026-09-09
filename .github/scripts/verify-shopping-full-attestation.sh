#!/usr/bin/env bash

set -euo pipefail

expected_sha="${1:-}"
attestation_state="${2:-missing}"

if [[ -z "$expected_sha" ]]; then
    echo "ShoppingFull requires an exact-commit local pass attestation." >&2
    exit 1
fi

if [[ "$attestation_state" != "success" ]]; then
    echo "Commit $expected_sha has no successful local/ShoppingFull status." >&2
    exit 1
fi

echo "Verified local ShoppingFull pass for $expected_sha."
