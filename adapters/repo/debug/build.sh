#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_files=(
  "$source_root/ext/debug/extconf.rb"
  "$source_root/ext/debug/debug.c"
  "$source_root/ext/debug/iseq_collector.c"
  "$source_root/lib/debug/version.rb"
)
for source_file in "${source_files[@]}"; do
  [[ -f "$source_file" ]] || {
    printf 'run this adapter from the debug repository root; missing %s\n' \
      "$source_file" >&2
    exit 66
  }
done

bash "$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
: "${RZ_RECEIPT_DIR:?certified adapters require a wrapper receipt directory}"
[[ "$RZ_ZIG_TARGET" == x86_64-linux-gnu.2.17 ]] || {
  printf 'debug adapter is implemented only for Zig target x86_64-linux-gnu.2.17; got %s\n' \
    "$RZ_ZIG_TARGET" >&2
  exit 78
}
[[ -x "$RZ_ZIG" ]] || {
  printf 'RZ_ZIG must be the executable pinned Zig compiler: %s\n' \
    "$RZ_ZIG" >&2
  exit 78
}
[[ -d "$RZ_RECEIPT_DIR" ]] || {
  printf 'wrapper receipt directory is missing: %s\n' "$RZ_RECEIPT_DIR" >&2
  exit 66
}

for command_name in \
  ruby make file readelf sha256sum git grep awk sed sort tail env realpath cp; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'debug adapter requires %s\n' "$command_name" >&2
    exit 69
  }
done

specifications=(
  CC:rz-cc
  CXX:rz-cxx
  AR:rz-ar
  RANLIB:rz-ranlib
  LD:rz-cc
  LDSHARED:rz-shared
)
for specification in "${specifications[@]}"; do
  variable="${specification%%:*}"
  wrapper="${specification#*:}"
  expected="$RZ_TOOLCHAIN_BIN/$wrapper"
  actual="${!variable:-}"
  [[ "$actual" == "$expected" && -x "$actual" ]] || {
    printf '%s must be the executable controller wrapper %s, got %s\n' \
      "$variable" "$expected" "${actual:-unset}" >&2
    exit 78
  }
done

actual_ruby_version="$(ruby -e 'print RUBY_VERSION')"
[[ "$actual_ruby_version" == "$expected_ruby_version" ]] || {
  printf 'debug adapter requires Ruby %s; got %s\n' \
    "$expected_ruby_version" "$actual_ruby_version" >&2
  exit 78
}

jobs="${RZ_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
  printf 'RZ_JOBS must be a positive integer\n' >&2
  exit 64
}

output_parent="$(dirname -- "$source_root")"
build_root="$(realpath -m "${RZ_BUILD_ROOT:-$output_parent/.ruby-zig-build}")"
artifact_root="$(realpath -m "${RZ_ARTIFACT_DIR:-$output_parent/.ruby-zig-artifacts}")"
for output_root in "$build_root" "$artifact_root"; do
  case "$output_root" in
    "$source_root"|"$source_root"/*)
      printf 'debug adapter outputs must remain outside the source worktree: %s\n' \
        "$output_root" >&2
      exit 78
      ;;
  esac
done

build_dir="$build_root/debug-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET/debug"
for path in "$build_dir" "$artifact_dir"; do
  [[ ! -e "$path" ]] || {
    printf 'refusing to reuse adapter output: %s\n' "$path" >&2
    exit 73
  }
done
mkdir -p "$build_dir" "$artifact_dir"
export ZIG_LOCAL_CACHE_DIR="$build_dir/.zig-local-cache"
export ZIG_GLOBAL_CACHE_DIR="$build_dir/.zig-global-cache"

staged_repo="$build_dir/source"
compile_dir="$build_dir/work"
mkdir -p "$staged_repo/ext/debug" "$staged_repo/lib/debug" "$compile_dir"
cp "$source_root/ext/debug/extconf.rb" "$staged_repo/ext/debug/extconf.rb"
cp "$source_root/ext/debug/debug.c" "$staged_repo/ext/debug/debug.c"
cp "$source_root/ext/debug/iseq_collector.c" \
  "$staged_repo/ext/debug/iseq_collector.c"
cp "$source_root/lib/debug/version.rb" "$staged_repo/lib/debug/version.rb"

(
  cd "$compile_dir"
  ruby -rrbconfig -e '
    %w[CC CXX AR RANLIB LD LDSHARED].each do |key|
      value = ENV.fetch(key)
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    {
      "CFLAGS" => "-O2 -Wno-default-const-init-field-unsafe",
      "CXXFLAGS" => "-O2 -Wno-default-const-init-field-unsafe",
      "CPPFLAGS" => "",
      "LDFLAGS" => "",
      "DLDFLAGS" => "",
      "RPATHFLAG" => ""
    }.each do |key, value|
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    %w[LIBRUBYARG LIBRUBYARG_SHARED].each do |key|
      value = RbConfig::CONFIG[key].to_s
      value = value.gsub(/(?:\A|\s)-Wl,-rpath(?:,|=)[^\s]+/, "").strip
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    script = File.realpath(ARGV.shift)
    ARGV.unshift("--srcdir=#{File.dirname(script)}")
    load script
  ' "$staged_repo/ext/debug/extconf.rb"
  [[ -s debug_version.h ]] || {
    printf 'debug version header was not generated in the isolated build stage\n' >&2
    exit 70
  }
  make -j"$jobs" V=1 \
    "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
    "LD=$LD" "LDSHARED=$LDSHARED"
)

artifact="$compile_dir/debug.so"
[[ -s "$artifact" ]] || {
  printf 'debug extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/debug.so"
artifact="$artifact_dir/debug.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected debug artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq \
  'Machine:[[:space:]]+Advanced Micro Devices X86-64'

mapfile -t init_exports < <(
  readelf --dyn-syms --wide "$artifact" |
    awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}' |
    sort
)
if [[ ${#init_exports[@]} -ne 2 ||
      "${init_exports[0]:-}" != Init_debug ||
      "${init_exports[1]:-}" != Init_iseq_collector ]]; then
  printf 'debug artifact must export Init_debug and its collector initializer; got: %s\n' \
    "${init_exports[*]:-none}" >&2
  exit 70
fi

dynamic="$(readelf -d "$artifact")"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
  printf 'debug artifact must not contain RPATH or RUNPATH\n' >&2
  exit 70
fi

glibc_max="$(
  readelf --version-info "$artifact" |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
    sort -V |
    tail -n 1
)"
if [[ -n "$glibc_max" ]]; then
  newest="$(printf '%s\n%s\n' 2.17 "$glibc_max" | sort -V | tail -n 1)"
  [[ "$newest" == 2.17 ]] || {
    printf 'debug requires GLIBC_%s, above the declared 2.17 ceiling\n' \
      "$glibc_max" >&2
    exit 70
  }
fi

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
[[ -s "$receipt_file" ]] || {
  printf 'debug build produced no Zig wrapper receipts: %s\n' \
    "$receipt_file" >&2
  exit 70
}
grep -Eq $'\ttool=cc\t.*\toperation=compile\t' "$receipt_file" || {
  printf 'debug build has no Zig C compilation receipt\n' >&2
  exit 70
}
grep -Eq $'\ttool=shared\t.*\toperation=link\t' "$receipt_file" || {
  printf 'debug build has no Zig shared-link receipt\n' >&2
  exit 70
}

env -u RUBYLIB -u RUBYOPT \
  ruby --disable-gems "$adapter_root/runtime-test.rb" "$artifact"

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'debug source HEAD changed during the build\n' >&2
  exit 70
}
post_status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$post_status" ]] || {
  printf 'debug build modified the source worktree:\n%s\n' "$post_status" >&2
  exit 70
}

printf 'debug GNU artifact loaded and passed runtime tests; glibc_max=%s\n' \
  "${glibc_max:-none}"
sha256sum "$artifact"
