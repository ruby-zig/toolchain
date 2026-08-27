#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == '--allow-no-native' ]]; then
  audit_mode='--allow-no-native'
  shift
else
  audit_mode=''
fi
if [[ "${1:-}" == '--' ]]; then shift; fi
if [[ $# -eq 0 ]]; then
  printf 'usage: run-certified.sh [--allow-no-native] -- COMMAND [ARG...]\n' >&2
  exit 64
fi
if ! command -v strace >/dev/null 2>&1; then
  printf 'strace is required for Linux certification\n' >&2
  exit 69
fi

trace_root="${RZ_TRACE_DIR:-$root/trace/${RZ_ZIG_TARGET:-native}}"
receipt_dir="${RZ_RECEIPT_DIR:?source export-toolchain.sh first}"
if [[ -e "$receipt_dir/invocations.tsv" ]]; then
  printf 'receipt log must not exist before a certified run: %s\n' \
    "$receipt_dir/invocations.tsv" >&2
  exit 73
fi
mkdir -p "$trace_root" "$receipt_dir"
work="$(mktemp -d "$trace_root/run.XXXXXXXX")"
poison="$work/poison"
trace="$work/execve.log"
"$root/scripts/make-poison-path.sh" "$poison" >/dev/null

set +e
PATH="$poison:$PATH" strace -f -qq \
  -e trace=execve,execveat,clone,clone3,fork,vfork \
  -o "$trace" -- "$@"
status=$?
set -e

"$root/scripts/check-trace.sh" "$trace" "$receipt_dir" $audit_mode
exit "$status"
