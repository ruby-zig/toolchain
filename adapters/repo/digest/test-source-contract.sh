#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

git -C "$work" init -q
git -C "$work" config user.name 'ruby.zig contract test'
git -C "$work" config user.email 'contract-test@example.invalid'
printf 'source\n' >"$work/source.txt"
git -C "$work" add -- source.txt
git -C "$work" commit -qm source
sha="$(git -C "$work" rev-parse HEAD)"

RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  "$root/source-contract.sh" "$work" >/dev/null

expect_failure() {
  local expected_status="$1"
  local expected_text="$2"
  shift 2
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne $expected_status ]]; then
    printf 'expected status %s, got %s: %s\n' \
      "$expected_status" "$status" "$output" >&2
    exit 1
  fi
  grep -Fq "$expected_text" <<<"$output" || {
    printf 'expected failure text %q, got: %s\n' "$expected_text" "$output" >&2
    exit 1
  }
}

expect_failure 64 'RZ_SOURCE_REF must name the dispatched source commit' \
  env -u RZ_SOURCE_REF RZ_SOURCE_REF_NAME=master \
  "$root/source-contract.sh" "$work"
expect_failure 64 'lowercase full 40-character commit SHA' \
  env RZ_SOURCE_REF=master RZ_SOURCE_REF_NAME=master \
  "$root/source-contract.sh" "$work"
expect_failure 64 'lowercase full 40-character commit SHA' \
  env RZ_SOURCE_REF="${sha^^}" RZ_SOURCE_REF_NAME=master \
  "$root/source-contract.sh" "$work"
expect_failure 64 'RZ_SOURCE_REF_NAME must name the tracked source branch' \
  env -u RZ_SOURCE_REF_NAME RZ_SOURCE_REF="$sha" \
  "$root/source-contract.sh" "$work"
expect_failure 78 'only supports the tracked master branch' \
  env RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=main \
  "$root/source-contract.sh" "$work"
expect_failure 78 'source checkout differs from RZ_SOURCE_REF' \
  env RZ_SOURCE_REF=0000000000000000000000000000000000000000 \
  RZ_SOURCE_REF_NAME=master \
  "$root/source-contract.sh" "$work"

printf 'untracked\n' >"$work/untracked.txt"
expect_failure 73 'requires a clean source checkout' \
  env RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  "$root/source-contract.sh" "$work"

printf 'Digest source contract tests passed\n'
