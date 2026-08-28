#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
source_root="$work/source"
fixture_root="$work/adapter"
mkdir -p "$source_root" "$fixture_root"

for command_name in git jq cp; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'etc source contract test requires %s\n' "$command_name" >&2
    exit 69
  }
done

git -C "$source_root" init -q
git -C "$source_root" config user.name 'ruby.zig contract test'
git -C "$source_root" config user.email 'contract-test@example.invalid'
printf 'source\n' >"$source_root/source.txt"
git -C "$source_root" add -- source.txt
git -C "$source_root" commit -qm source
sha="$(git -C "$source_root" rev-parse HEAD)"

if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract ignored the manifest-pinned fleet-lock SHA\n' >&2
  exit 1
fi

cp "$root/source-contract.sh" "$fixture_root/source-contract.sh"
jq --arg sha "$sha" '.upstream_sha = $sha' \
  "$root/adapter.json" >"$fixture_root/adapter.json"
RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$fixture_root/source-contract.sh" "$source_root" >/dev/null

case "${sha: -1}" in
  0) bad_sha="${sha%?}1" ;;
  *) bad_sha="${sha%?}0" ;;
esac
if RZ_SOURCE_REF="$bad_sha" RZ_SOURCE_REF_NAME=master \
  bash "$fixture_root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a mismatched SHA\n' >&2
  exit 1
fi
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=main \
  bash "$fixture_root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted an untracked branch\n' >&2
  exit 1
fi
if RZ_SOURCE_REF=master RZ_SOURCE_REF_NAME=master \
  bash "$fixture_root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a symbolic ref\n' >&2
  exit 1
fi

jq '.upstream_sha = "master"' \
  "$root/adapter.json" >"$fixture_root/adapter.json"
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$fixture_root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a malformed manifest SHA\n' >&2
  exit 1
fi
jq --arg sha "$sha" '.upstream_sha = $sha' \
  "$root/adapter.json" >"$fixture_root/adapter.json"

printf 'dirty\n' >"$source_root/untracked.txt"
if RZ_SOURCE_REF="$sha" RZ_SOURCE_REF_NAME=master \
  bash "$fixture_root/source-contract.sh" "$source_root" >/dev/null 2>&1; then
  printf 'source contract accepted a dirty worktree\n' >&2
  exit 1
fi

printf 'etc source contract tests passed\n'
