#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'

adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(pwd -P)"
extconf="$source_root/ext/stringio/extconf.rb"
source_file="$source_root/ext/stringio/stringio.c"
[[ -f "$extconf" && -f "$source_file" ]] || {
  printf 'run this adapter from the stringio repository root\n' >&2
  exit 66
}

bash "$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
case "$RZ_ZIG_TARGET" in
  x86_64-linux-gnu.2.17|x86_64-linux-musl) ;;
  *)
    printf 'StringIO adapter has not been certified for Zig target %s\n' \
      "$RZ_ZIG_TARGET" >&2
    exit 78
    ;;
esac

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
  printf 'StringIO adapter requires Ruby %s; got %s\n' \
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
build_dir="$build_root/stringio-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET"
for path in "$build_dir" "$artifact_dir"; do
  [[ ! -e "$path" ]] || {
    printf 'refusing to reuse adapter output: %s\n' "$path" >&2
    exit 73
  }
done
mkdir -p "$build_dir" "$artifact_dir"

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

(
  cd "$build_dir"
  configure_extension "$extconf"
  make -j"$jobs" V=1 \
    "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" "LD=$LD" \
    "LDSHARED=$LDSHARED"
)

artifact="$build_dir/stringio.so"
[[ -s "$artifact" ]] || {
  printf 'StringIO extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/stringio.so"
artifact="$artifact_dir/stringio.so"

readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
readelf -h "$artifact" | grep -Eq 'Data:[[:space:]]+2.s complement, little endian'
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN .Shared object file.'
readelf -h "$artifact" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'

case "$RZ_ZIG_TARGET" in
  x86_64-linux-gnu.2.17)
    glibc_max="$(
      readelf --version-info "$artifact" |
        sed -n 's/.*Name: GLIBC_\([^[:space:]]*\).*/\1/p' |
        sort -V |
        tail -n 1
    )"
    if [[ -n "$glibc_max" ]] && \
       [[ "$(printf '%s\n%s\n' "$glibc_max" '2.17' | sort -V | tail -n 1)" != '2.17' ]]; then
      printf 'StringIO artifact exceeds GLIBC_2.17: GLIBC_%s\n' "$glibc_max" >&2
      exit 70
    fi
    # The embedded program is Ruby, not shell.
    # shellcheck disable=SC2016
    ruby --disable-gems -e '
      path = File.realpath(ARGV.fetch(0))
      require path
      loaded = $LOADED_FEATURES.map { |entry| File.expand_path(entry) }
      raise "exact artifact was not loaded" unless loaded.include?(path)
      io = StringIO.new("zig")
      raise "read smoke failed" unless io.read == "zig"
      io = StringIO.new
      io.write("ruby")
      raise "write smoke failed" unless io.string == "ruby"
    ' "$artifact"
    printf 'runtime=verified glibc_max=%s\n' "${glibc_max:-none}"
    ;;
  x86_64-linux-musl)
    if readelf --version-info "$artifact" | grep -q 'GLIBC_'; then
      printf 'musl artifact contains a GLIBC version dependency\n' >&2
      exit 70
    fi

    mapfile -t init_exports < <(
      readelf --dyn-syms --wide "$artifact" |
        awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
    )
    if [[ ${#init_exports[@]} -ne 1 ||
          "${init_exports[0]:-}" != 'Init_stringio' ]]; then
      printf 'musl StringIO artifact must export only Init_stringio; got: %s\n' \
        "${init_exports[*]:-none}" >&2
      exit 70
    fi

    dynamic="$(readelf -d "$artifact")"
    mapfile -t needed < <(
      sed -n 's/.*(NEEDED).*Shared library: \[\([^]]*\)\].*/\1/p' <<<"$dynamic"
    )
    seen_libruby=false
    seen_libc=false
    for library in "${needed[@]}"; do
      case "$library" in
        libruby-3.2.so.3.2) seen_libruby=true ;;
        libc.so) seen_libc=true ;;
        *)
          printf 'musl StringIO artifact has unexpected DT_NEEDED entry: %s\n' \
            "$library" >&2
          exit 70
          ;;
      esac
    done
    if [[ "${#needed[@]}" -ne 2 ||
          "$seen_libruby" != true ||
          "$seen_libc" != true ]]; then
      printf '%s\n' \
        'musl StringIO artifact must need exactly libruby-3.2.so.3.2 and libc.so' >&2
      exit 70
    fi
    if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
      printf 'musl StringIO artifact must not contain RPATH or RUNPATH\n' >&2
      exit 70
    fi

    printf '%s\n' \
      'experimental musl ELF inspection passed; target Ruby ABI and runtime unverified'
    ;;
esac

file "$artifact"
sha256sum "$artifact"
