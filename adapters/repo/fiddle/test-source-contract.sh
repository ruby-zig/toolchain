#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
source_root="$work/source"
mkdir -p "$source_root"

command -v git >/dev/null 2>&1 || {
  printf 'fiddle source contract test requires git\n' >&2
  exit 69
}

git -C "$source_root" init -q
git -C "$source_root" config user.name 'ruby.zig contract test'
git -C "$source_root" config user.email 'contract-test@example.invalid'
printf 'source\n' >"$source_root/source.txt"
git -C "$source_root" add -- source.txt
git -C "$source_root" commit -qm source
sha="$(git -C "$source_root" rev-parse HEAD)"

RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$source_root" >/dev/null

case "${sha: -1}" in
  0) bad_sha="${sha%?}1" ;;
  *) bad_sha="${sha%?}0" ;;
esac
if RZ_SOURCE_REF="$bad_sha" RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a mismatched SHA\n' >&2
  exit 1
fi
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=main \
  bash "$root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted an untracked branch\n' >&2
  exit 1
fi
if RZ_SOURCE_REF=master RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a symbolic ref\n' >&2
  exit 1
fi

printf 'dirty\n' >"$source_root/untracked.txt"
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a dirty worktree\n' >&2
  exit 1
fi

printf 'fiddle source contract tests passed\n'
