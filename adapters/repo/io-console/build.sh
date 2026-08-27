#!/usr/bin/env bash

set -euo pipefail

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
extconf="$source_root/ext/io/console/extconf.rb"
[[ -f "$extconf" && -f "$source_root/ext/io/console/console.c" ]] || {
  printf 'run this adapter from the io-console repository root\n' >&2
  exit 66
}

"$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
[[ "$RZ_ZIG_TARGET" == x86_64-linux-gnu.2.17 ]] || {
  printf 'io-console adapter has not been certified for Zig target %s\n' \
    "$RZ_ZIG_TARGET" >&2
  exit 78
}

for command in ruby make file readelf sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'io-console adapter requires %s\n' "$command" >&2
    exit 69
  }
done

expected_ruby=3.2.3
ruby -e 'abort "expected Ruby #{ARGV[0]}, got #{RUBY_VERSION}" unless RUBY_VERSION == ARGV[0]' \
  "$expected_ruby"

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

jobs="${RZ_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
  printf 'RZ_JOBS must be a positive integer\n' >&2
  exit 64
}

build_root="${RZ_BUILD_ROOT:-$source_root/.ruby-zig-build}"
artifact_root="${RZ_ARTIFACT_DIR:-$source_root/.ruby-zig-artifacts}"
build_dir="$build_root/io-console-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET/io"
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
      "DLDFLAGS" => ""
    }.each do |key, value|
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

artifact="$build_dir/console.so"
[[ -s "$artifact" ]] || {
  printf 'io-console extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/console.so"
artifact="$artifact_dir/console.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected io-console artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
mapfile -t init_exports < <(
  readelf --dyn-syms --wide "$artifact" |
    awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
)
if [[ ${#init_exports[@]} -ne 1 || "${init_exports[0]:-}" != Init_console ]]; then
  printf 'io-console artifact must export only Init_console; got: %s\n' \
    "${init_exports[*]:-none}" >&2
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
    printf 'io-console requires GLIBC_%s, above the declared 2.17 ceiling\n' \
      "$glibc_max" >&2
    exit 70
  }
fi

# This loads the exact staged artifact and performs terminal operations against
# a real pseudoterminal. It does not fall back to Ruby's installed io-console.
# shellcheck disable=SC2016
ruby --disable-gems -e '
  artifact = File.realpath(ARGV.fetch(0))
  require artifact
  loaded = $LOADED_FEATURES.map { |path| File.realpath(path) rescue path }
  abort "exact io-console artifact was not loaded" unless loaded.include?(artifact)

  require "pty"
  require "timeout"
  master, slave = PTY.open
  master.sync = slave.sync = true
  begin
    abort "slave is not a tty" unless slave.tty?
    original_echo = slave.echo?

    raw_result = slave.raw do |tty|
      abort "raw mode retained echo" if tty.echo?
      :raw_completed
    end
    abort "raw block did not complete" unless raw_result == :raw_completed
    abort "raw block did not restore echo" unless slave.echo? == original_echo

    noecho_result = slave.noecho do |tty|
      abort "noecho left echo enabled" if tty.echo?
      :noecho_completed
    end
    abort "noecho block did not complete" unless noecho_result == :noecho_completed
    abort "noecho block did not restore echo" unless slave.echo? == original_echo

    original_size = slave.winsize
    slave.winsize = [31, 97]
    abort "winsize round trip failed" unless slave.winsize == [31, 97]
    slave.winsize = original_size

    password = nil
    transcript = +""
    Timeout.timeout(5) do
      reader = Thread.new { slave.getpass("Password: ") }
      until transcript.include?("Password: ")
        readable = IO.select([master], nil, nil, 1)
        abort "getpass prompt was not emitted" unless readable
        transcript << master.read_nonblock(4096)
      end
      master.write("ruby-zig-secret\n")
      password = reader.value
      if IO.select([master], nil, nil, 0.1)
        transcript << master.read_nonblock(4096, exception: false).to_s
      end
    end
    abort "getpass returned the wrong value" unless password == "ruby-zig-secret"
    abort "getpass echoed the secret" if transcript.include?("ruby-zig-secret")
  ensure
    master.close unless master.closed?
    slave.close unless slave.closed?
  end
  puts "io-console exact artifact PTY runtime passed"
' "$artifact"

printf 'io-console GNU artifact loaded; PTY runtime passed; glibc_max=%s\n' \
  "${glibc_max:-none}"
sha256sum "$artifact"
