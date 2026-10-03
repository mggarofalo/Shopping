#!/bin/bash
set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repository_root"
readonly commit="$(git rev-parse --verify HEAD)"
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then
    if [[ "${GITHUB_REF:-}" != refs/heads/main || "${GITHUB_SHA:-}" != "$commit" ]]; then
        echo "Releases must build the dispatched main commit." >&2
        exit 1
    fi
elif [[ "$(git symbolic-ref --quiet --short HEAD || true)" != main ]]; then
    echo "Releases must build from main." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Releases require a clean checkout." >&2
    exit 1
fi
printf 'Release source: %s\n' "$commit"
