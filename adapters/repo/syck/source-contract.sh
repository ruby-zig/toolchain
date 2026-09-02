#!/usr/bin/env bash

set -euo pipefail

readonly expected_source_ref_name='master'

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
[[ "$RZ_SOURCE_REF_NAME" == "$expected_source_ref_name" ]] || {
  printf 'Syck adapter only supports the tracked %s branch\n' \
    "$expected_source_ref_name" >&2
  exit 78
}
command -v git >/dev/null 2>&1 || {
  printf 'Syck source verification requires git\n' >&2
  exit 69
}
git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'Syck source must be a Git worktree\n' >&2
  exit 66
}

worktree_root="$(git -C "$source_root" rev-parse --show-toplevel)"
worktree_root="$(cd -- "$worktree_root" && pwd -P)"
[[ "$worktree_root" == "$source_root" ]] || {
  printf 'Syck adapter must run from the source worktree root: %s\n' \
    "$worktree_root" >&2
  exit 66
}

actual_sha="$(git -C "$source_root" rev-parse --verify HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'Syck source is %s, expected %s\n' \
    "$actual_sha" "$RZ_SOURCE_REF" >&2
  exit 78
}

status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$status" ]] || {
  printf 'Syck adapter requires a clean source worktree:\n%s\n' "$status" >&2
  exit 73
}

printf 'Syck source accepted: %s@%s\n' \
  "$expected_source_ref_name" "$actual_sha"
