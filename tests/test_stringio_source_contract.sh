#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
contract="$root/adapters/repo/stringio/source-contract.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

source_root="$work/source"
git init -q "$source_root"
git -C "$source_root" config user.name 'ruby.zig tests'
git -C "$source_root" config user.email 'ruby-zig-tests@example.invalid'
printf 'tracked\n' >"$source_root/tracked.txt"
git -C "$source_root" add -- tracked.txt
git -C "$source_root" commit -q -m 'fixture'
source_sha="$(git -C "$source_root" rev-parse HEAD)"

RZ_SOURCE_REF="$source_sha" RZ_SOURCE_REF_NAME=master \
  bash "$contract" "$source_root" >/dev/null

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
  env -u RZ_SOURCE_REF RZ_SOURCE_REF_NAME=master bash "$contract" "$source_root"
expect_failure 64 'lowercase full 40-character commit SHA' \
  env RZ_SOURCE_REF=master RZ_SOURCE_REF_NAME=master \
  bash "$contract" "$source_root"
expect_failure 64 'lowercase full 40-character commit SHA' \
  env RZ_SOURCE_REF="${source_sha^^}" RZ_SOURCE_REF_NAME=master \
  bash "$contract" "$source_root"
expect_failure 64 'RZ_SOURCE_REF_NAME must name the tracked source branch' \
  env -u RZ_SOURCE_REF_NAME RZ_SOURCE_REF="$source_sha" \
  bash "$contract" "$source_root"
expect_failure 78 'only supports the tracked master branch' \
  env RZ_SOURCE_REF="$source_sha" RZ_SOURCE_REF_NAME=main \
  bash "$contract" "$source_root"
expect_failure 78 'source checkout differs from RZ_SOURCE_REF' \
  env RZ_SOURCE_REF=0000000000000000000000000000000000000000 \
  RZ_SOURCE_REF_NAME=master \
  bash "$contract" "$source_root"

printf 'untracked\n' >"$source_root/untracked.txt"
expect_failure 73 'requires a clean source checkout' \
  env RZ_SOURCE_REF="$source_sha" RZ_SOURCE_REF_NAME=master \
  bash "$contract" "$source_root"

printf 'StringIO source contract tests passed\n'
