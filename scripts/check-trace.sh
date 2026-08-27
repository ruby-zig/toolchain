#!/usr/bin/env bash

set -euo pipefail

trace="${1:?usage: check-trace.sh TRACE RECEIPTS [--allow-no-native]}"
receipts="${2:?usage: check-trace.sh TRACE RECEIPTS [--allow-no-native]}"
allow_no_native="${3:-}"

if [[ ! -s "$trace" ]]; then
  printf 'missing or empty process trace: %s\n' "$trace" >&2
  exit 2
fi
if grep -Eq 'execveat\(|<\.\.\. execveat resumed>' "$trace"; then
  printf 'execveat cannot be resolved safely by this auditor:\n' >&2
  grep -E 'execveat\(|<\.\.\. execveat resumed>' "$trace" | sed -n '1,20p' >&2
  exit 9
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper_dir="$root/toolchain/bin"
forbidden_file="$trace.forbidden"
executables_file="$trace.executables"
processes_file="$trace.processes"
: >"$forbidden_file"
sed -n 's/.*execve("\([^"]*\)".*/\1/p' "$trace" >"$executables_file"
sed -n 's/^\([0-9][0-9]*\)[[:space:]]\+.*execve("\([^"]*\)".*/\1\t\2/p' \
  "$trace" >"$processes_file"

while IFS= read -r executable; do
  case "$executable" in
    "$wrapper_dir/rz-cc"|"$wrapper_dir/rz-cxx"|"$wrapper_dir/rz-ar"|\
    "$wrapper_dir/rz-ranlib"|"$wrapper_dir/rz-shared"|\
    "$wrapper_dir/rz-host-cc"|"$wrapper_dir/rz-host-cxx"|\
    "$wrapper_dir/rz-host-ar"|"$wrapper_dir/rz-host-ranlib"|\
    "$wrapper_dir/rz-rust-linker"|"$wrapper_dir/rz-rust-host-linker"|\
    "$wrapper_dir/rz-rustc")
      continue
      ;;
  esac
  if [[ ( -n "${RZ_ZIG:-}" && "$executable" == "$RZ_ZIG" ) || \
        ( -n "${RZ_RUSTC:-}" && "$executable" == "$RZ_RUSTC" ) ]]; then
    continue
  fi

  name="${executable##*/}"
  name="${name%.exe}"
  name="${name,,}"
  case "$name" in
    cc|cc-[0-9]*|*-cc|*-cc-[0-9]*|c89|c99|c11|c17|c23|\
    c++|c++-[0-9]*|*-c++|*-c++-[0-9]*|cpp|cpp-[0-9]*|*-cpp|*-cpp-[0-9]*|\
    gcc|gcc-[0-9]*|*-gcc|*-gcc-[0-9]*|g++|g++-[0-9]*|*-g++|*-g++-[0-9]*|\
    clang|clang-[0-9]*|*-clang|*-clang-[0-9]*|clang++|clang++-[0-9]*|\
    *-clang++|*-clang++-[0-9]*|clang-cl|clang-cl-[0-9]*|cl|link|lld-link|\
    ld|ld.*|*-ld|*-ld.*|lld|lld-[0-9]*|ld64.lld|gold|mold|\
    rust-lld|rust-lld-*|*-rust-lld|*-rust-lld-*|\
    ar|ar-[0-9]*|*-ar|*-ar-[0-9]*|ranlib|ranlib-[0-9]*|*-ranlib|*-ranlib-[0-9]*|\
    llvm-link|llvm-lipo|as|*-as|nasm|yasm|llvm-mc|\
    collect2|cc1|cc1plus|ccache|sccache|distcc|zig|zig-*|rustc|rustc-*|*-rustc)
      printf '%s\n' "$executable" >>"$forbidden_file"
      ;;
  esac
done <"$executables_file"

if [[ -s "$forbidden_file" ]]; then
  printf 'foreign native tool invocation detected:\n' >&2
  sed -n '1,20p' "$forbidden_file" >&2
  exit 3
fi

receipt_file="$receipts/invocations.tsv"
if [[ "$allow_no_native" != '--allow-no-native' && ! -s "$receipt_file" ]]; then
  printf 'no Zig or Rust wrapper receipts were recorded: %s\n' "$receipt_file" >&2
  exit 4
fi

declare -A receipt_compilers=()
if [[ -s "$receipt_file" ]]; then
  valid_receipt=$'^time=[^\t]+\tpid=[0-9]+\ttool=(cc|cxx|ar|ranlib|shared|rust-link|rust-host-link|host-cc|host-cxx|host-ar|host-ranlib|rustc-target|rustc-host)\ttarget=[^\t]+\toperation=(probe|compile|link|archive|rust-compile)\tcwd=[^\t]+\targv=.*$'
  if grep -Ev "$valid_receipt" "$receipt_file" >"$receipt_file.invalid"; then
    printf 'invalid or interleaved wrapper receipt:\n' >&2
    sed -n '1,20p' "$receipt_file.invalid" >&2
    exit 5
  fi
  if [[ "$allow_no_native" != '--allow-no-native' ]] && \
     ! grep -Eq $'\toperation=(compile|link|archive|rust-compile)\t' "$receipt_file"; then
    printf 'wrapper receipts contain probes but no native transformation\n' >&2
    exit 6
  fi

  while IFS=$'\t' read -r _ pid_field tool_field _; do
    pid="${pid_field#pid=}"
    tool="${tool_field#tool=}"
    case "$tool" in
      rustc-target|rustc-host)
        : "${RZ_RUSTC:?RZ_RUSTC is required to correlate Rust receipts}"
        expected="$RZ_RUSTC"
        compiler_kind=rustc
        ;;
      *)
        : "${RZ_ZIG:?RZ_ZIG is required to correlate Zig receipts}"
        expected="$RZ_ZIG"
        compiler_kind=zig
        ;;
    esac
    if ! awk -v pid="$pid" -v needle="execve(\"$expected\"" \
      '$1 == pid && index($0, needle) { found = 1 } END { exit !found }' "$trace"; then
      printf 'Receipt has no matching traced process: pid=%s tool=%s executable=%s\n' \
        "$pid" "$tool" "$expected" >&2
      exit 7
    fi
    receipt_compilers["$pid|$compiler_kind"]=1
  done <"$receipt_file"
fi

declare -A parent_by_pid=()
while IFS=$'\t' read -r parent child; do
  parent_by_pid["$child"]="$parent"
done < <(
  awk '
    ($0 ~ /^[0-9]+[[:space:]]+(clone|clone3|fork|vfork)\(/ ||
     $0 ~ /^[0-9]+[[:space:]]+<\.\.\. (clone|clone3|fork|vfork) resumed>/) &&
    $(NF - 1) == "=" && $NF ~ /^[0-9]+$/ {
      print $1 "\t" $NF
    }
  ' "$trace"
)

while IFS=$'\t' read -r pid executable; do
  case "$executable" in
    "${RZ_ZIG:-}") compiler_kind=zig ;;
    "${RZ_RUSTC:-}") compiler_kind=rustc ;;
    *) continue ;;
  esac

  cursor="$pid"
  matched=0
  depth=0
  while [[ -n "$cursor" && $depth -lt 128 ]]; do
    if [[ -n "${receipt_compilers["$cursor|$compiler_kind"]:-}" ]]; then
      matched=1
      break
    fi
    cursor="${parent_by_pid["$cursor"]:-}"
    depth=$((depth + 1))
  done
  if [[ $matched -ne 1 ]]; then
    printf 'Pinned compiler process has no wrapper-receipt ancestor: pid=%s compiler=%s\n' \
      "$pid" "$compiler_kind" >&2
    exit 8
  fi
done <"$processes_file"

printf 'toolchain trace accepted\n'
