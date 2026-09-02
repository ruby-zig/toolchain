#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: source-contract.sh SOURCE_ROOT\n' >&2
  exit 64
fi

source_root="$1"
if [[ -z "${RZ_SOURCE_REF:-}" ]]; then
  printf 'RZ_SOURCE_REF must name the dispatched source commit\n' >&2
  exit 64
fi
if [[ -z "${RZ_SOURCE_REF_NAME:-}" ]]; then
  printf 'RZ_SOURCE_REF_NAME must name the tracked source branch\n' >&2
  exit 64
fi
[[ "$RZ_SOURCE_REF" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'RZ_SOURCE_REF must be a lowercase full 40-character commit SHA\n' >&2
  exit 64
}
[[ "$RZ_SOURCE_REF_NAME" == master ]] || {
  printf 'StringIO adapter only supports the tracked master branch\n' >&2
  exit 78
}

command -v git >/dev/null 2>&1 || {
  printf 'StringIO source verification requires git\n' >&2
  exit 69
}
actual_source_sha="$(git -C "$source_root" rev-parse --verify HEAD 2>/dev/null)" || {
  printf 'StringIO source is not a Git checkout\n' >&2
  exit 66
}
[[ "$actual_source_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'StringIO source checkout differs from RZ_SOURCE_REF: %s != %s\n' \
    "$actual_source_sha" "$RZ_SOURCE_REF" >&2
  exit 78
}
if [[ -n "$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  printf 'StringIO adapter requires a clean source checkout\n' >&2
  exit 73
fi

printf 'StringIO source accepted: master@%s\n' "$actual_source_sha"
