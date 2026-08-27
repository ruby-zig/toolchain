#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: source-contract.sh SOURCE_ROOT\n' >&2
  exit 64
fi

source_root="$(cd -- "$1" && pwd -P)"
[[ -n "${RZ_SOURCE_REF:-}" ]] || {
  printf 'RZ_SOURCE_REF must name the dispatched source commit\n' >&2
  exit 64
}
[[ -n "${RZ_SOURCE_REF_NAME:-}" ]] || {
  printf 'RZ_SOURCE_REF_NAME must name the tracked source branch\n' >&2
  exit 64
}

[[ "$RZ_SOURCE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'RZ_SOURCE_REF must be a lowercase full 40-character commit SHA\n' >&2
  exit 64
}
[[ "$RZ_SOURCE_REF_NAME" == master ]] || {
  printf 'Digest adapter only supports the tracked master branch\n' >&2
  exit 78
}
git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'Digest source must be a Git worktree\n' >&2
  exit 66
}

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'Digest source checkout differs from RZ_SOURCE_REF: got %s, expected %s\n' \
    "$actual_sha" "$RZ_SOURCE_REF" >&2
  exit 78
}

status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$status" ]] || {
  printf 'Digest adapter requires a clean source checkout:\n%s\n' "$status" >&2
  exit 73
}

printf 'Digest source accepted: master@%s\n' "$actual_sha"
