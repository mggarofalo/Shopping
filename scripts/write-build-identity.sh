#!/bin/bash
set -euo pipefail

# Always run: HEAD may change without any source file changing.
readonly source_root="${SRCROOT:?}"
readonly output_path="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/BuildCommit.txt"
commit=$(git -C "$source_root" rev-parse --verify HEAD)
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: Cannot determine the source Git SHA." >&2
    exit 1
fi
if [[ -n "$(git -C "$source_root" status --porcelain --untracked-files=normal)" ]]; then
    commit="$commit-dirty"
fi
mkdir -p "$(dirname "$output_path")"
printf '%s\n' "$commit" > "$output_path"
