#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gate="$script_dir/verify-shopping-full-attestation.sh"
sha="0123456789abcdef0123456789abcdef01234567"

"$gate" "$sha" success >/dev/null

if "$gate" "" success >/dev/null 2>&1; then
    echo "Gate accepted a missing workflow SHA." >&2
    exit 1
fi

if "$gate" "$sha" failure >/dev/null 2>&1; then
    echo "Gate accepted a failed local status." >&2
    exit 1
fi

echo "ShoppingFull attestation gate tests passed."
