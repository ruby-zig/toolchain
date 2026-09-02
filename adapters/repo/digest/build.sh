#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'

adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(pwd -P)"
[[ -f "$source_root/ext/digest/extconf.rb" && \
   -f "$source_root/ext/digest/digest.c" && \
   -f "$source_root/ext/digest/blake3/blake3.c" ]] || {
  printf 'run this adapter from the Digest repository root\n' >&2
  exit 66
}

"$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
[[ "$RZ_ZIG_TARGET" == x86_64-linux-gnu.2.17 ]] || {
  printf 'Digest adapter has only been verified for Zig target %s\n' \
    'x86_64-linux-gnu.2.17' >&2
  exit 78
}

for command in ruby make file readelf sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Digest adapter requires %s\n' "$command" >&2
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
  printf 'Digest adapter requires Ruby %s; got %s\n' \
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
build_dir="$build_root/digest-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET/digest"
for path in "$build_dir" "$artifact_dir"; do
  [[ ! -e "$path" ]] || {
    printf 'refusing to reuse adapter output: %s\n' "$path" >&2
    exit 73
  }
done
mkdir -p "$build_dir" "$artifact_dir/digest"

configure_extension() {
  local script="$1"
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
  ' "$script"
}

build_extension() {
  local component="$1"
  local source_dir="$2"
  local output_name="$3"
  local component_build="$build_dir/$component"
  local produced

  mkdir -p "$component_build"
  (
    cd "$component_build"
    configure_extension "$source_dir/extconf.rb"
    make -j"$jobs" V=1 \
      "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
      "LD=$LD" "LDSHARED=$LDSHARED"
  )

  produced="$component_build/$output_name.so"
  [[ -s "$produced" ]] || {
    printf 'Digest %s extension was not produced: %s\n' \
      "$component" "$produced" >&2
    exit 70
  }
  if [[ "$component" == digest ]]; then
    cp "$produced" "$artifact_dir/digest.so"
  else
    cp "$produced" "$artifact_dir/digest/$output_name.so"
  fi
}

build_extension digest "$source_root/ext/digest" digest
for component in md5 rmd160 sha1 sha2 bubblebabble crc32 blake3; do
  build_extension "$component" "$source_root/ext/digest/$component" "$component"
done

declare -A expected_init=(
  [digest.so]=Init_digest
  [digest/md5.so]=Init_md5
  [digest/rmd160.so]=Init_rmd160
  [digest/sha1.so]=Init_sha1
  [digest/sha2.so]=Init_sha2
  [digest/bubblebabble.so]=Init_bubblebabble
  [digest/crc32.so]=Init_crc32
  [digest/blake3.so]=Init_blake3
)

glibc_max=''
for relative in \
  digest.so \
  digest/md5.so \
  digest/rmd160.so \
  digest/sha1.so \
  digest/sha2.so \
  digest/bubblebabble.so \
  digest/crc32.so \
  digest/blake3.so; do
  artifact="$artifact_dir/$relative"
  format="$(file -b "$artifact")"
  [[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
    printf 'unexpected Digest artifact format for %s: %s\n' \
      "$relative" "$format" >&2
    exit 70
  }
  readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
  readelf -h "$artifact" | grep -Eq \
    'Machine:[[:space:]]+Advanced Micro Devices X86-64'

  dynamic="$(readelf -d "$artifact")"
  if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
    printf 'Digest artifact contains RPATH or RUNPATH: %s\n' "$relative" >&2
    exit 70
  fi

  mapfile -t init_exports < <(
    readelf --dyn-syms --wide "$artifact" |
      awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
  )
  if [[ ${#init_exports[@]} -ne 1 ||
        "${init_exports[0]:-}" != "${expected_init[$relative]}" ]]; then
    printf 'Digest artifact %s must export only %s among Init_* symbols; got: %s\n' \
      "$relative" "${expected_init[$relative]}" \
      "${init_exports[*]:-none}" >&2
    exit 70
  fi

  artifact_glibc_max="$(
    readelf --version-info "$artifact" |
      sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
      sort -V |
      tail -n 1
  )"
  if [[ -n "$artifact_glibc_max" ]]; then
    newest="$(printf '%s\n%s\n' 2.17 "$artifact_glibc_max" | sort -V | tail -n 1)"
    [[ "$newest" == 2.17 ]] || {
      printf 'Digest artifact %s requires GLIBC_%s, above the 2.17 ceiling\n' \
        "$relative" "$artifact_glibc_max" >&2
      exit 70
    }
    glibc_max="$(
      printf '%s\n%s\n' "${glibc_max:-0}" "$artifact_glibc_max" |
        sort -V |
        tail -n 1
    )"
  fi
done

ruby --disable-gems "$adapter_root/runtime-test.rb" "$source_root" "$artifact_dir"
printf 'Digest GNU artifacts passed ELF inspection; glibc_max=%s\n' \
  "${glibc_max:-none}"
(
  cd "$artifact_dir"
  sha256sum \
    digest.so \
    digest/md5.so \
    digest/rmd160.so \
    digest/sha1.so \
    digest/sha2.so \
    digest/bubblebabble.so \
    digest/crc32.so \
    digest/blake3.so
)
