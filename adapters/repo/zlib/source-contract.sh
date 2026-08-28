#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: source-contract.sh SOURCE_ROOT\n' >&2
  exit 64
fi

source_root="$(cd -- "$1" && pwd -P)"
: "${RZ_SOURCE_REF:?RZ_SOURCE_REF must be the exact source commit SHA}"
: "${RZ_SOURCE_REF_NAME:?RZ_SOURCE_REF_NAME must name the tracked source branch}"

[[ "$RZ_SOURCE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'RZ_SOURCE_REF must be a lowercase full commit SHA\n' >&2
  exit 64
}
[[ "$RZ_SOURCE_REF_NAME" == master ]] || {
  printf 'zlib adapter only supports the tracked master branch\n' >&2
  exit 78
}
git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'zlib source must be a Git worktree\n' >&2
  exit 66
}

git_root="$(git -C "$source_root" rev-parse --show-toplevel)"
git_root="$(cd -- "$git_root" && pwd -P)"
[[ "$git_root" == "$source_root" ]] || {
  printf 'zlib source root must be the Git worktree root: %s\n' "$git_root" >&2
  exit 66
}

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'zlib source is %s, expected %s\n' \
    "$actual_sha" "$RZ_SOURCE_REF" >&2
  exit 78
}

status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$status" ]] || {
  printf 'zlib adapter requires a clean source worktree:\n%s\n' "$status" >&2
  exit 73
}

printf 'zlib source accepted: master@%s\n' "$actual_sha"
