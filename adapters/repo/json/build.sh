#!/usr/bin/env bash

set -euo pipefail

source_root="$(pwd -P)"
generator_extconf="$source_root/ext/json/ext/generator/extconf.rb"
parser_extconf="$source_root/ext/json/ext/parser/extconf.rb"
[[ -f "$generator_extconf" && -f "$parser_extconf" ]] || {
  printf 'run this adapter from the json repository root\n' >&2
  exit 66
}
: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"

jobs="${RZ_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
  printf 'RZ_JOBS must be a positive integer\n' >&2
  exit 64
}
export JSON_DISABLE_SIMD=1

build_root="${RZ_BUILD_ROOT:-$source_root/.ruby-zig-build}"
artifact_root="${RZ_ARTIFACT_DIR:-$source_root/.ruby-zig-artifacts}"
profile_build_root="$build_root/json-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET/json/ext"
for path in "$profile_build_root" "$artifact_dir"; do
  [[ ! -e "$path" ]] || {
    printf 'refusing to reuse adapter output: %s\n' "$path" >&2
    exit 73
  }
done
mkdir -p "$profile_build_root/generator" "$profile_build_root/parser"
mkdir -p "$artifact_dir"

configure_extension() {
  local script="$1"
  ruby -rrbconfig -e '
    %w[CC CXX AR RANLIB LDSHARED].each do |key|
      value = ENV.fetch(key)
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    {
      "CFLAGS" => "-O2 -Wno-default-const-init-field-unsafe",
      "CXXFLAGS" => "-O2 -Wno-default-const-init-field-unsafe",
      "CPPFLAGS" => "",
      "LDFLAGS" => "",
      "DLDFLAGS" => ""
    }.each do |key, value|
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    script = File.expand_path(ARGV.shift)
    ARGV.unshift("--srcdir=#{File.dirname(script)}")
    load script
  ' "$script"
}

build_extension() {
  local name="$1"
  local extconf="$2"
  local directory="$profile_build_root/$name"
  (
    cd "$directory"
    configure_extension "$extconf"
    make -j"$jobs" V=1 \
      "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
      "LDSHARED=$LDSHARED"
  )
  [[ -s "$directory/$name.so" ]] || {
    printf 'json %s extension was not produced\n' "$name" >&2
    exit 70
  }
  cp "$directory/$name.so" "$artifact_dir/$name.so"
}

build_extension generator "$generator_extconf"
build_extension parser "$parser_extconf"
sha256sum "$artifact_dir/generator.so" "$artifact_dir/parser.so"
