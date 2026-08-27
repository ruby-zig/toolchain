#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

cat >"$work/foreign-trace" <<'EOF'
1 execve("/usr/bin/gcc-14", ["gcc-14", "-c", "bad.c"], 0x0) = 0
2 execve("/usr/bin/aarch64-linux-gnu-gcc", ["aarch64-linux-gnu-gcc"], 0x0) = 0
EOF
mkdir -p "$work/foreign-receipts"

if "$root/scripts/check-trace.sh" "$work/foreign-trace" "$work/foreign-receipts" 2>/dev/null; then
  printf 'auditor accepted a foreign compiler\n' >&2
  exit 1
fi

cat >"$work/rust-lld-trace" <<'EOF'
3 execve("/toolchain/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld", ["rust-lld"], 0x0) = 0
EOF
mkdir -p "$work/rust-lld-receipts"
if "$root/scripts/check-trace.sh" \
  "$work/rust-lld-trace" "$work/rust-lld-receipts" --allow-no-native 2>/dev/null; then
  printf 'auditor accepted rust-lld as a native linker\n' >&2
  exit 1
fi

printf '5 execve("%s", ["rz-gcc", "-c", "bad.c"], 0x0) = 0\n' \
  "$root/toolchain/bin/rz-gcc" >"$work/unlisted-wrapper-trace"
mkdir -p "$work/unlisted-wrapper-receipts"
if "$root/scripts/check-trace.sh" \
  "$work/unlisted-wrapper-trace" "$work/unlisted-wrapper-receipts" \
  --allow-no-native 2>/dev/null; then
  printf 'auditor accepted an unlisted rz-prefixed executable\n' >&2
  exit 1
fi

cat >"$work/execveat-trace" <<'EOF'
4 execveat(3, "", ["renamed-compiler", "-c", "bad.c"], 0x0, AT_EMPTY_PATH) = 0
EOF
mkdir -p "$work/execveat-receipts"
if "$root/scripts/check-trace.sh" \
  "$work/execveat-trace" "$work/execveat-receipts" --allow-no-native 2>/dev/null; then
  printf 'auditor accepted an unresolved execveat invocation\n' >&2
  exit 1
fi

fake_zig="$work/fake-zig"
printf '7 execve("%s", ["fake-zig", "cc", "--version"], 0x0) = 0\n' "$fake_zig" >"$work/probe-trace"
mkdir -p "$work/probe-receipts"
printf 'time=2026-01-01T00:00:00Z\tpid=7\ttool=cc\ttarget=native\toperation=probe\tcwd=/tmp\targv=--version\n' \
  >"$work/probe-receipts/invocations.tsv"

if RZ_ZIG="$fake_zig" "$root/scripts/check-trace.sh" \
  "$work/probe-trace" "$work/probe-receipts" 2>/dev/null; then
  printf 'auditor accepted a probe as a native transformation\n' >&2
  exit 1
fi

cat >"$work/unwrapped-trace" <<EOF
7 execve("$fake_zig", ["fake-zig", "cc", "-c", "good.c"], 0x0) = 0
8 execve("$fake_zig", ["fake-zig", "cc", "-c", "unwrapped.c"], 0x0) = 0
EOF
mkdir -p "$work/unwrapped-receipts"
printf 'time=2026-01-01T00:00:00Z\tpid=7\ttool=cc\ttarget=native\toperation=compile\tcwd=/tmp\targv=-c good.c\n' \
  >"$work/unwrapped-receipts/invocations.tsv"

if RZ_ZIG="$fake_zig" "$root/scripts/check-trace.sh" \
  "$work/unwrapped-trace" "$work/unwrapped-receipts" 2>/dev/null; then
  printf 'auditor accepted an unwrapped pinned compiler invocation\n' >&2
  exit 1
fi

cat >"$work/descendant-trace" <<EOF
7 execve("$fake_zig", ["fake-zig", "cc", "-c", "good.c"], 0x0) = 0
7 clone(child_stack=NULL, flags=SIGCHLD) = 9
9 execve("$fake_zig", ["fake-zig", "clang", "-cc1", "good.c"], 0x0) = 0
EOF
mkdir -p "$work/descendant-receipts"
printf 'time=2026-01-01T00:00:00Z\tpid=7\ttool=cc\ttarget=native\toperation=compile\tcwd=/tmp\targv=-c good.c\n' \
  >"$work/descendant-receipts/invocations.tsv"
RZ_ZIG="$fake_zig" "$root/scripts/check-trace.sh" \
  "$work/descendant-trace" "$work/descendant-receipts" >/dev/null

cat >"$work/thread-fork-trace" <<EOF
41  execve("$fake_zig", ["fake-zig", "cc", "-c", "good.c"], 0x0) = 0
41  clone(child_stack=0x1, flags=CLONE_VM|CLONE_THREAD) = 42
42  fork() = 43
43  execve("$fake_zig", ["fake-zig", "clang", "-cc1", "good.c"], 0x0) = 0
EOF
mkdir -p "$work/thread-fork-receipts"
printf 'time=2026-01-01T00:00:00Z\tpid=41\ttool=cc\ttarget=native\toperation=compile\tcwd=/tmp\targv=-c good.c\n' \
  >"$work/thread-fork-receipts/invocations.tsv"
RZ_ZIG="$fake_zig" "$root/scripts/check-trace.sh" \
  "$work/thread-fork-trace" "$work/thread-fork-receipts" >/dev/null

printf 'auditor negative controls passed\n'
