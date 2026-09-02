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
  bash "$root/source-contract.sh" "$work" >/dev/null

case "${sha: -1}" in
  0) bad_sha="${sha%?}1" ;;
  *) bad_sha="${sha%?}0" ;;
esac
if RZ_SOURCE_REF="$bad_sha" RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$work" >/dev/null 2>&1; then
  printf 'source contract accepted a mismatched SHA\n' >&2
  exit 1
fi
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=main \
  bash "$root/source-contract.sh" "$work" >/dev/null 2>&1; then
  printf 'source contract accepted an untracked branch\n' >&2
  exit 1
fi
if RZ_SOURCE_REF=master RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$work" >/dev/null 2>&1; then
  printf 'source contract accepted a symbolic ref\n' >&2
  exit 1
fi
printf 'dirty\n' >"$work/untracked.txt"
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$work" >/dev/null 2>&1; then
  printf 'source contract accepted a dirty worktree\n' >&2
  exit 1
fi

printf 'sdbm source contract tests passed\n'
