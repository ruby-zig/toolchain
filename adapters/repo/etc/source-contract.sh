#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: source-contract.sh SOURCE_ROOT\n' >&2
  exit 64
fi

source_root="$(cd -- "$1" && pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="$adapter_root/adapter.json"
: "${RZ_SOURCE_REF:?RZ_SOURCE_REF must be the exact source commit SHA}"
: "${RZ_SOURCE_REF_NAME:?RZ_SOURCE_REF_NAME must name the tracked source branch}"

for command_name in git jq; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'etc source contract requires %s\n' "$command_name" >&2
    exit 69
  }
done
[[ -f "$manifest" ]] || {
  printf 'etc adapter manifest is missing: %s\n' "$manifest" >&2
  exit 66
}
expected_repository="$(jq -er '.repository | strings' "$manifest")"
expected_source_ref="$(
  jq -er '.upstream_sha | strings | select(test("^[0-9a-f]{40}$"))' \
    "$manifest"
)"
[[ "$expected_repository" == ruby/etc ]] || {
  printf 'etc adapter manifest names unexpected repository %s\n' \
    "$expected_repository" >&2
  exit 78
}

[[ "$RZ_SOURCE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'RZ_SOURCE_REF must be a lowercase full commit SHA\n' >&2
  exit 64
}
[[ "$RZ_SOURCE_REF" == "$expected_source_ref" ]] || {
  printf 'etc adapter expects fleet-lock source %s, got %s\n' \
    "$expected_source_ref" "$RZ_SOURCE_REF" >&2
  exit 78
}
[[ "$RZ_SOURCE_REF_NAME" == master ]] || {
  printf 'etc adapter only supports the tracked master branch\n' >&2
  exit 78
}
git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  printf 'etc source must be a Git worktree\n' >&2
  exit 66
}

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'etc source is %s, expected %s\n' \
    "$actual_sha" "$RZ_SOURCE_REF" >&2
  exit 78
}

status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$status" ]] || {
  printf 'etc adapter requires a clean source worktree:\n%s\n' "$status" >&2
  exit 73
}

printf 'etc source accepted: master@%s\n' "$actual_sha"
