#!/usr/bin/env bash

set -euo pipefail

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
extconf="$source_root/ext/strscan/extconf.rb"
[[ -f "$extconf" && -f "$source_root/ext/strscan/strscan.c" ]] || {
  printf 'run this adapter from the strscan repository root\n' >&2
  exit 66
}

"$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"

case "$RZ_ZIG_TARGET" in
  x86_64-linux-gnu.2.17|x86_64-linux-musl) ;;
  *)
    printf 'strscan adapter has not been validated for Zig target %s\n' \
      "$RZ_ZIG_TARGET" >&2
    exit 78
    ;;
esac

for command in ruby make file readelf sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'strscan adapter requires %s\n' "$command" >&2
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
build_dir="$build_root/strscan-$RZ_ZIG_TARGET"
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

artifact="$build_dir/strscan.so"
[[ -s "$artifact" ]] || {
  printf 'strscan extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/strscan.so"
artifact="$artifact_dir/strscan.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected strscan artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'

case "$RZ_ZIG_TARGET" in
  x86_64-linux-gnu.2.17)
    glibc_max="$(
      readelf --version-info "$artifact" |
        sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
        sort -V |
        tail -n 1
    )"
    if [[ -n "$glibc_max" ]]; then
      newest="$(printf '%s\n%s\n' 2.17 "$glibc_max" | sort -V | tail -n 1)"
      [[ "$newest" == 2.17 ]] || {
        printf 'strscan requires GLIBC_%s, above the declared 2.17 ceiling\n' \
          "$glibc_max" >&2
        exit 70
      }
    fi
    # The following single-quoted program is Ruby, not shell.
    # shellcheck disable=SC2016
    ruby --disable-gems -e '
      artifact = File.realpath(ARGV.fetch(0))
      require artifact
      loaded = $LOADED_FEATURES.map { |path| File.realpath(path) rescue path }
      abort "exact strscan artifact was not loaded" unless loaded.include?(artifact)
      scanner = StringScanner.new("ruby-zig 3.2.3")
      abort "strscan smoke failed" unless scanner.scan(/ruby-zig/) == "ruby-zig"
      abort "strscan position failed" unless scanner.pos == 8
    ' "$artifact"
    printf 'strscan GNU artifact loaded and passed runtime smoke\n'
    ;;
  x86_64-linux-musl)
    if readelf --version-info "$artifact" | grep -q 'Name: GLIBC_'; then
      printf 'musl artifact unexpectedly contains a GLIBC version reference\n' >&2
      exit 70
    fi

    mapfile -t init_exports < <(
      readelf --dyn-syms --wide "$artifact" |
        awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
    )
    if [[ ${#init_exports[@]} -ne 1 ||
          "${init_exports[0]:-}" != 'Init_strscan' ]]; then
      printf 'strscan musl artifact must export only Init_strscan; got: %s\n' \
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
          printf 'strscan musl artifact has unexpected DT_NEEDED entry: %s\n' \
            "$library" >&2
          exit 70
          ;;
      esac
    done
    if [[ "${#needed[@]}" -ne 2 ||
          "$seen_libruby" != true ||
          "$seen_libc" != true ]]; then
      printf '%s\n' \
        'strscan musl artifact must need exactly libruby-3.2.so.3.2 and libc.so' >&2
      exit 70
    fi
    if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
      printf 'strscan musl artifact must not contain RPATH or RUNPATH\n' >&2
      exit 70
    fi

    printf '%s\n' \
      'experimental musl ELF inspection passed; target Ruby ABI and runtime unverified'
    ;;
esac

sha256sum "$artifact"
