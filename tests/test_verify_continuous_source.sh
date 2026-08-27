#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/ruby-zig-source-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/remotes/ruby" "$fixture/remotes/ruby-zig"
git init --bare --quiet "$fixture/remotes/ruby/native.git"
git init --bare --quiet "$fixture/remotes/ruby-zig/native.git"
git init --quiet "$fixture/seed"
git -C "$fixture/seed" config user.name "Ruby Zig Test"
git -C "$fixture/seed" config user.email "ruby-zig-test@example.invalid"
printf 'baseline\n' > "$fixture/seed/history.txt"
git -C "$fixture/seed" add history.txt
git -C "$fixture/seed" commit --quiet -m baseline
git -C "$fixture/seed" branch -M master
baseline="$(git -C "$fixture/seed" rev-parse HEAD)"
git -C "$fixture/seed" remote add upstream "$fixture/remotes/ruby/native.git"
git -C "$fixture/seed" remote add fork "$fixture/remotes/ruby-zig/native.git"
git -C "$fixture/seed" push --quiet upstream master
git -C "$fixture/seed" push --quiet fork master

printf 'candidate\n' >> "$fixture/seed/history.txt"
git -C "$fixture/seed" commit --quiet -am candidate
candidate="$(git -C "$fixture/seed" rev-parse HEAD)"
git -C "$fixture/seed" push --quiet upstream master
git -C "$fixture/seed" push --quiet fork master

RZ_TEST_ALLOW_LOCAL_GIT_ROOT=1 \
RZ_TEST_GIT_ROOT="$fixture/remotes" \
  bash "$root/scripts/verify-continuous-source.sh" \
    ruby/native ruby-zig/native master "$baseline" "$candidate"

git --git-dir="$fixture/remotes/ruby-zig/native.git" \
  update-ref refs/heads/master "$baseline"
if RZ_TEST_ALLOW_LOCAL_GIT_ROOT=1 \
  RZ_TEST_GIT_ROOT="$fixture/remotes" \
  bash "$root/scripts/verify-continuous-source.sh" \
    ruby/native ruby-zig/native master "$baseline" "$candidate"; then
  printf 'candidate absent from the fork unexpectedly passed\n' >&2
  exit 1
fi

tree="$(git -C "$fixture/seed" rev-parse "$candidate^{tree}")"
divergent="$(printf 'divergent\n' | git -C "$fixture/seed" commit-tree "$tree")"
git -C "$fixture/seed" push --quiet --force \
  upstream "$divergent:refs/heads/master"
if RZ_TEST_ALLOW_LOCAL_GIT_ROOT=1 \
  RZ_TEST_GIT_ROOT="$fixture/remotes" \
  bash "$root/scripts/verify-continuous-source.sh" \
    ruby/native ruby-zig/native master "$baseline" "$divergent"; then
  printf 'candidate outside the certified baseline unexpectedly passed\n' >&2
  exit 1
fi

printf 'continuous source graph tests passed\n'
