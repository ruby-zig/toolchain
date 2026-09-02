#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
extconf="$source_root/ext/sdbm/extconf.rb"
for source_file in \
  "$source_root/ext/sdbm/_sdbm.c" \
  "$source_root/ext/sdbm/init.c" \
  "$source_root/ext/sdbm/sdbm.h"; do
  [[ -f "$source_file" ]] || {
    printf 'run this adapter from the sdbm repository root\n' >&2
    exit 66
  }
done
[[ -f "$extconf" ]] || {
  printf 'run this adapter from the sdbm repository root\n' >&2
  exit 66
}

bash "$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
: "${RZ_RECEIPT_DIR:?source the ruby.zig toolchain environment first}"
[[ "$RZ_ZIG_TARGET" == x86_64-linux-gnu.2.17 ]] || {
  printf 'sdbm adapter has not been certified for Zig target %s\n' \
    "$RZ_ZIG_TARGET" >&2
  exit 78
}
[[ -d "$RZ_RECEIPT_DIR" ]] || {
  printf 'wrapper receipt directory is missing: %s\n' "$RZ_RECEIPT_DIR" >&2
  exit 66
}

for command_name in ruby make file readelf sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'sdbm adapter requires %s\n' "$command_name" >&2
    exit 69
  }
done

for specification in \
  CC:rz-cc \
  CXX:rz-cxx \
  AR:rz-ar \
  RANLIB:rz-ranlib \
  LD:rz-cc \
  LDSHARED:rz-shared; do
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
  printf 'sdbm adapter requires Ruby %s; got %s\n' \
    "$expected_ruby_version" "$actual_ruby_version" >&2
  exit 78
}

jobs="${RZ_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
  printf 'RZ_JOBS must be a positive integer\n' >&2
  exit 64
}

build_root="${RZ_BUILD_ROOT:-$source_root/.ruby-zig-build}"
artifact_root="${RZ_ARTIFACT_DIR:-$source_root/.ruby-zig-artifacts}"
build_dir="$build_root/sdbm-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET"
for path in "$build_dir" "$artifact_dir"; do
  [[ ! -e "$path" ]] || {
    printf 'refusing to reuse adapter output: %s\n' "$path" >&2
    exit 73
  }
done
mkdir -p "$build_dir" "$artifact_dir"

(
  cd "$build_dir"
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
    script = File.expand_path(ARGV.shift)
    ARGV.unshift("--srcdir=#{File.dirname(script)}")
    load script
  ' "$extconf"
  make -j"$jobs" V=1 \
    "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
    "LD=$LD" "LDSHARED=$LDSHARED"
)

artifact="$build_dir/sdbm.so"
[[ -s "$artifact" ]] || {
  printf 'sdbm extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/sdbm.so"
artifact="$artifact_dir/sdbm.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected sdbm artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq \
  'Machine:[[:space:]]+Advanced Micro Devices X86-64'

mapfile -t init_exports < <(
  readelf --dyn-syms --wide "$artifact" |
    awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
)
if [[ ${#init_exports[@]} -ne 1 || "${init_exports[0]:-}" != Init_sdbm ]]; then
  printf 'sdbm artifact must export only Init_sdbm; got: %s\n' \
    "${init_exports[*]:-none}" >&2
  exit 70
fi

dynamic="$(readelf -d "$artifact")"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
  printf 'sdbm artifact must not contain RPATH or RUNPATH\n' >&2
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
    printf 'sdbm requires GLIBC_%s, above the declared 2.17 ceiling\n' \
      "$glibc_max" >&2
    exit 70
  }
fi

[[ "$(git -C "$source_root" rev-parse HEAD)" == "$RZ_SOURCE_REF" ]] || {
  printf 'sdbm source SHA changed during the build\n' >&2
  exit 78
}
git -C "$source_root" diff --quiet --ignore-submodules --
git -C "$source_root" diff --cached --quiet --ignore-submodules --
ruby --disable-gems "$adapter_root/runtime-test.rb" "$artifact"
printf 'sdbm GNU artifact passed database and lock runtime tests; glibc_max=%s\n' \
  "${glibc_max:-none}"
sha256sum "$artifact"
