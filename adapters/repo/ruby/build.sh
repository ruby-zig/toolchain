#!/usr/bin/env bash

set -euo pipefail

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_contract="$adapter_root/source-contract.sh"

for path in \
  "$source_root/autogen.sh" \
  "$source_root/configure.ac" \
  "$source_root/ruby.c" \
  "$source_root/ruby.rs" \
  "$source_contract"; do
  if [[ ! -f "$path" ]]; then
    printf 'CRuby source or adapter file is missing: %s\n' "$path" >&2
    exit 66
  fi
done

for command in awk autoconf cp git grep make nm readelf ruby sed sha256sum sort; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'CRuby adapter requires %s\n' "$command" >&2
    exit 69
  fi
done

: "${RZ_TOOLCHAIN_BIN:?source export-toolchain.sh before running the adapter}"
: "${RZ_ZIG_TARGET:?source export-toolchain.sh before running the adapter}"
: "${RZ_RUST_TARGET:?enable the pinned Rust toolchain before running the adapter}"
: "${RZ_RUST_HOST_TARGET:?enable the pinned Rust toolchain before running the adapter}"
: "${RZ_AUTOCONF_HOST:?source export-toolchain.sh before running the adapter}"
: "${RZ_RECEIPT_DIR:?run the adapter through run-certified.sh}"

case "${RZ_ENABLE_RUST:-false}" in
  1|true) ;;
  *)
    printf 'CRuby adapter requires the pinned Rust lane for YJIT/ZJIT\n' >&2
    exit 78
    ;;
esac

if [[ "$RZ_ZIG_TARGET" != x86_64-linux-gnu.2.17 ||
      "$RZ_RUST_TARGET" != x86_64-unknown-linux-gnu ||
      "$RZ_RUST_HOST_TARGET" != x86_64-unknown-linux-gnu ||
      "$RZ_AUTOCONF_HOST" != x86_64-linux-gnu ]]; then
  printf 'CRuby adapter currently supports only the native x86_64 GNU/Linux profile\n' >&2
  exit 78
fi

expected_variables=(CC CXX AR RANLIB LD LDSHARED RUSTC)
expected_values=(
  "$RZ_TOOLCHAIN_BIN/rz-cc"
  "$RZ_TOOLCHAIN_BIN/rz-cxx"
  "$RZ_TOOLCHAIN_BIN/rz-ar"
  "$RZ_TOOLCHAIN_BIN/rz-ranlib"
  "$RZ_TOOLCHAIN_BIN/rz-cc"
  "$RZ_TOOLCHAIN_BIN/rz-shared"
  "$RZ_TOOLCHAIN_BIN/rz-rustc"
)
for index in "${!expected_variables[@]}"; do
  variable="${expected_variables[$index]}"
  expected="${expected_values[$index]}"
  actual="${!variable:-}"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s must be %s; got %s\n' \
      "$variable" "$expected" "${actual:-unset}" >&2
    exit 64
  fi
done

source_sha="$(git rev-parse HEAD)"
source_branch=
jit_options=()
# shellcheck source=adapters/repo/ruby/source-contract.sh
source "$source_contract"
rz_ruby_source_contract "$source_sha"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  printf 'CRuby adapter requires a clean source checkout\n' >&2
  exit 73
fi

if [[ -n "${RZ_BUILD_JOBS:-}" ]]; then
  jobs=$RZ_BUILD_JOBS
else
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4\n')"
  if (( jobs > 8 )); then jobs=8; fi
fi
case "$jobs" in
  ''|*[!0-9]*)
    printf 'RZ_BUILD_JOBS must be a positive integer\n' >&2
    exit 64
    ;;
esac
if (( jobs < 1 )); then
  printf 'RZ_BUILD_JOBS must be a positive integer\n' >&2
  exit 64
fi

build_root="$source_root/.ruby-zig-build/$RZ_ZIG_TARGET"
if [[ -e "$build_root" ]]; then
  printf 'CRuby adapter requires a clean checkout without %s\n' "$build_root" >&2
  exit 73
fi

baseruby="$(command -v ruby)"
case "$baseruby" in
  /*) ;;
  *)
    printf 'CRuby adapter requires an absolute baseruby path\n' >&2
    exit 69
    ;;
esac

export RZ_ZIG_HOST_TARGET=x86_64-linux-gnu.2.17
export JSON_DISABLE_SIMD=1
bash "$source_root/autogen.sh"
if [[ ! -x "$source_root/tool/config.sub" ]]; then
  printf 'autogen.sh did not produce executable tool/config.sub\n' >&2
  exit 66
fi
build_tuple="$("$source_root/tool/config.sub" "$RZ_AUTOCONF_HOST")"
if [[ "$build_tuple" != x86_64-pc-linux-gnu ]]; then
  printf 'unexpected canonical native tuple: %s\n' "$build_tuple" >&2
  exit 65
fi

mkdir -p "$build_root"
export ZIG_LOCAL_CACHE_DIR="$build_root/.zig-local-cache"
export ZIG_GLOBAL_CACHE_DIR="$build_root/.zig-global-cache"
cd "$build_root"

# CRuby appends -A -n when its strip probe succeeds. A configure-time `:`
# would therefore become `: -A -n`; make the probe fail without invoking strip.
"$source_root/configure" \
  --srcdir="$source_root" \
  --build="$build_tuple" \
  --host="$build_tuple" \
  --with-baseruby="$baseruby" \
  --without-git \
  --without-gmp \
  --disable-install-doc \
  --disable-fortify-source \
  --enable-shared \
  "${jit_options[@]}" \
  CC="$CC" \
  CXX="$CXX" \
  CPP="$CC -E" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LD="$LD" \
  LDSHARED="$LDSHARED" \
  RUSTC="$RUSTC" \
  OBJCOPY=: \
  STRIP=/bin/false \
  LIBS=-lgcc_s \
  warnflags='-Wall -Wextra -Werror=unknown-warning-option -Wno-missing-field-initializers -Wno-unused-parameter'

cp config.log "$source_root/config.log"

configured_objcopy="$(awk -F '[[:space:]]*=[[:space:]]*' \
  '$1 == "OBJCOPY" {print $2; exit}' Makefile)"
if [[ "$configured_objcopy" != : ]]; then
  printf 'configured OBJCOPY must be inert; got %s\n' \
    "${configured_objcopy:-unset}" >&2
  exit 65
fi

config_status_strip_records() {
  awk 'index($0, "S[\"STRIP\"]=") == 1 {print}' config.status
}

configured_strip_record="$(config_status_strip_records)"
if [[ "$configured_strip_record" != 'S["STRIP"]="/bin/false"' ]]; then
  printf 'config.status has unexpected STRIP record: %s\n' \
    "${configured_strip_record:-unset}" >&2
  exit 65
fi

# mkconfig.rb reads STRIP from config.status. Normalize only the verified
# generated record before any make target can create rbconfig.rb.
sed -i 's|^S\["STRIP"\]="/bin/false"$|S["STRIP"]=":"|' config.status
configured_strip_record="$(config_status_strip_records)"
if [[ "$configured_strip_record" != 'S["STRIP"]=":"' ]]; then
  printf 'could not normalize config.status STRIP record: %s\n' \
    "${configured_strip_record:-unset}" >&2
  exit 65
fi

make_value() {
  local name=$1
  local rule
  printf -v rule \
    "ruby_zig_print:;@printf \"%%s\\\\n\" \"\$(%s)\"" "$name"
  make -s --no-print-directory -f Makefile 'OBJCOPY=:' 'STRIP=:' \
    --eval="$rule" ruby_zig_print
}

mainlibs="$(make_value MAINLIBS)"
case " $mainlibs " in
  *' -lgcc_s '*) ;;
  *)
    printf 'configured MAINLIBS does not contain -lgcc_s: %s\n' "$mainlibs" >&2
    exit 65
    ;;
esac

ldflags="$(make_value LDFLAGS)"
ldflags="${ldflags//-rdynamic/}"
ldflags="${ldflags//-Wl,-export-dynamic/}"
ldflags="${ldflags//-Wl,--export-dynamic/}"
if [[ "$ldflags" == *export-dynamic* ]]; then
  printf 'could not remove executable export-dynamic flags: %s\n' "$ldflags" >&2
  exit 65
fi

rust_archive="$build_root/target/release/libruby.a"
c_archive="$build_root/libruby-zig-c-only.a"
export_map="$build_root/ruby-zig.exports"
base_overrides=(
  'RUST_LIBOBJ='
  'OBJCOPY=:'
  'STRIP=:'
  "LIBRUBY_A=$c_archive"
  "MAINLIBS=$rust_archive $mainlibs"
  "SOLIBS=$rust_archive $mainlibs"
  "EXE_LDFLAGS=$ldflags"
)

make -j"$jobs" V=1 'OBJCOPY=:' 'STRIP=:' rust-lib
if [[ ! -s "$rust_archive" ]]; then
  printf 'CRuby Rust archive was not built: %s\n' "$rust_archive" >&2
  exit 66
fi

# A shared-only profile keeps C and Rust archives separate. The C archive is
# an internal dependency of libruby.so, not an installable static CRuby.
make -j"$jobs" V=1 "${base_overrides[@]}" "$c_archive"
if [[ ! -s "$c_archive" ]]; then
  printf 'CRuby C sidecar archive was not built: %s\n' "$c_archive" >&2
  exit 66
fi

{
  printf '{\n  global:\n'
  nm -P -g --defined-only "$c_archive" "$rust_archive" |
    awk '$1 ~ /^(Onig|RUBY_|coroutine_|dln_|onig|pm_|rb_|rbimpl_|ruby_)/ &&
         $1 !~ /^ruby_static_id_/ && $1 !~ /_(ec|threadptr)_/ {print $1}' |
    sort -u |
    sed 's/$/;/'
  printf '  local:\n    *;\n};\n'
} >"$export_map"
map_symbols="$(grep -c ';$' "$export_map")"
if (( map_symbols < 100 )); then
  printf 'CRuby export map is unexpectedly small: %s symbols\n' "$map_symbols" >&2
  exit 65
fi

make -j"$jobs" V=1 "${base_overrides[@]}" miniruby

libruby_so="$(make_value LIBRUBY_SO)"
dldflags="$(make_value DLDFLAGS)"

# Finish the ordinary build first so every generated DSO input and extension is
# stable. Then remove only that disposable DSO target and relink it once with
# the exact Ruby export map. The map is never propagated to extension links.
make -j"$jobs" V=1 "${base_overrides[@]}"
shared="$build_root/$libruby_so"
if [[ ! -s "$shared" ]]; then
  printf 'ordinary CRuby build did not produce %s\n' "$shared" >&2
  exit 66
fi
rm -f -- "$shared"
make -j"$jobs" V=1 "${base_overrides[@]}" \
  "DLDFLAGS=$dldflags -Wl,--version-script=$export_map" \
  "$libruby_so"

make V=1 "${base_overrides[@]}" showflags
make V=1 "${base_overrides[@]}" yes-test-leaked-globals
make -j"$jobs" V=1 "${base_overrides[@]}" test

for artifact in "$build_root/miniruby" "$build_root/ruby" "$shared"; do
  if [[ ! -s "$artifact" ]]; then
    printf 'missing CRuby shared-profile artifact: %s\n' "$artifact" >&2
    exit 66
  fi
  rust_exports="$(
    nm -D -P --defined-only "$artifact" |
      awk '
        function is_rust_v0(symbol) {
          return symbol ~ /^_R/
        }
        function is_legacy_rust(symbol) {
          return symbol ~ /^_ZN.*17h[0-9a-f]{16}E([.@].*)?$/
        }
        is_rust_v0($1) || is_legacy_rust($1) { count++ }
        END { print count + 0 }
      '
  )"
  if [[ $rust_exports -ne 0 ]]; then
    printf '%s exposes %s Rust-mangled dynamic symbols\n' \
      "$artifact" "$rust_exports" >&2
    exit 65
  fi
done

expected_api=(ruby_init rb_yjit_enable)
if [[ "$source_branch" == master || "$source_branch" == ruby_4_0 ]]; then
  expected_api+=(rb_zjit_enable)
fi
for symbol in "${expected_api[@]}"; do
  if ! nm -D -P --defined-only "$shared" |
       awk -v symbol="$symbol" '$1 == symbol {found=1} END {exit !found}'; then
    printf '%s does not export expected API symbol %s\n' "$shared" "$symbol" >&2
    exit 65
  fi
done

if [[ -e "$build_root/libruby-static.a" || -e "${rust_archive%.a}.o" ]]; then
  printf 'shared-only CRuby profile unexpectedly produced a static or partial-link artifact\n' >&2
  exit 65
fi

export LD_LIBRARY_PATH="$build_root${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
./ruby --disable-gems -I"$source_root/lib" -I. -rrbconfig -e '
  required = {
    "CC" => ENV.fetch("CC"),
    "CXX" => ENV.fetch("CXX"),
    "AR" => ENV.fetch("AR"),
    "RANLIB" => ENV.fetch("RANLIB"),
    "LD" => ENV.fetch("LD"),
    "LDSHARED" => ENV.fetch("LDSHARED"),
    "RUSTC" => ENV.fetch("RUSTC"),
    "OBJCOPY" => ":",
    "STRIP" => ":",
  }
  required.each do |key, expected|
    actual = RbConfig::CONFIG.fetch(key)
    abort "#{key}=#{actual.inspect}, expected #{expected.inspect}" unless actual == expected
    puts "#{key}=#{actual}"
  end
  abort "shared CRuby is disabled" unless RbConfig::CONFIG["ENABLE_SHARED"] == "yes"
'

./ruby --disable-gems --yjit -e \
  'abort "YJIT disabled" unless RubyVM::YJIT.enabled?'
if [[ "$source_branch" == master || "$source_branch" == ruby_4_0 ]]; then
  ./ruby --disable-gems --zjit -e \
    'abort "ZJIT disabled" unless RubyVM::ZJIT.enabled?'
fi
./ruby --disable-gems \
  -I"$source_root/lib" -I.ext/common -I.ext/x86_64-linux \
  -rdate -rdigest -rio/console -rjson -rsocket -rstringio -rstrscan \
  -e 'puts "native extension smoke passed"'

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
if [[ ! -s "$receipt_file" ]]; then
  printf 'missing wrapper receipt ledger: %s\n' "$receipt_file" >&2
  exit 66
fi
if grep -q $'\ttool=rust-link\t' "$receipt_file"; then
  printf 'CRuby shared profile unexpectedly performed a Rust partial link\n' >&2
  exit 65
fi
if grep -F "$rust_archive" "$receipt_file" | grep -F "$libruby_so" >/dev/null; then
  :
else
  printf 'no direct Rust-archive shared-link receipt found for %s\n' "$libruby_so" >&2
  exit 65
fi

dso_receipts="$(grep -F 'tool=shared' "$receipt_file" | grep -F "$libruby_so")"
mapped_dso_links="$(printf '%s\n' "$dso_receipts" |
  grep -cF "version-script=$export_map" || :)"
if [[ "$mapped_dso_links" -ne 1 ]]; then
  printf 'expected exactly one mapped CRuby DSO link; got %s\n' \
    "$mapped_dso_links" >&2
  exit 65
fi
final_dso_receipt="$(printf '%s\n' "$dso_receipts" | tail -n 1)"
if [[ "$final_dso_receipt" != *"version-script=$export_map"* ]]; then
  printf 'the mapped CRuby DSO link was not the final DSO link\n' >&2
  exit 65
fi

artifacts=(
  ./miniruby
  ./ruby
  "$shared"
  "$c_archive"
  "$rust_archive"
  "$export_map"
  ./rbconfig.rb
)
for artifact in "${artifacts[@]}"; do
  if [[ ! -s "$artifact" ]]; then
    printf 'missing CRuby build artifact: %s\n' "$artifact" >&2
    exit 66
  fi
done

for elf in ./miniruby ./ruby "$shared"; do
  readelf -h "$elf"
  max_glibc="$(
    readelf --version-info "$elf" |
      grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' |
      sort -Vu |
      tail -n 1
  )"
  if [[ -z "$max_glibc" ||
        "$(printf '%s\n%s\n' "$max_glibc" GLIBC_2.17 | sort -V | tail -n 1)" != GLIBC_2.17 ]]; then
    printf '%s exceeds or does not expose the GLIBC_2.17 ceiling: %s\n' \
      "$elf" "${max_glibc:-none}" >&2
    exit 65
  fi
  printf '%s max_glibc=%s\n' "$elf" "$max_glibc"
done

"$AR" t "$c_archive" >/dev/null
"$AR" t "$rust_archive" >/dev/null
printf 'source_branch=%s source_sha=%s jobs=%s shared=%s map_symbols=%s mapped_dso_links=%s\n' \
  "$source_branch" "$source_sha" "$jobs" "$libruby_so" "$map_symbols" \
  "$mapped_dso_links"
./ruby --disable-gems --version
sha256sum "${artifacts[@]}"

artifact_root="${RZ_ARTIFACT_DIR:-$source_root/.ruby-zig-artifacts}"
cruby_artifact_dir="$artifact_root/$RZ_ZIG_TARGET/cruby"
if [[ -e "$cruby_artifact_dir" ]]; then
  printf 'refusing to reuse CRuby evidence directory: %s\n' \
    "$cruby_artifact_dir" >&2
  exit 73
fi
report_dir="$cruby_artifact_dir/reports"
mkdir -p "$report_dir"

cp -- \
  ./miniruby \
  ./ruby \
  "$shared" \
  "$export_map" \
  ./rbconfig.rb \
  "$cruby_artifact_dir/"

for elf in ./miniruby ./ruby "$shared"; do
  name="${elf##*/}"
  readelf -h "$elf" >"$report_dir/$name.readelf-header.txt"
  readelf --version-info "$elf" \
    >"$report_dir/$name.readelf-version-info.txt"
  readelf -d "$elf" >"$report_dir/$name.readelf-dynamic.txt"
  nm -D -P --defined-only "$elf" \
    >"$report_dir/$name.nm-dynamic-defined.txt"
done

(
  cd "$cruby_artifact_dir"
  sha256sum \
    miniruby \
    ruby \
    "$libruby_so" \
    ruby-zig.exports \
    rbconfig.rb \
    reports/* >sha256.txt
)
printf 'staged curated CRuby evidence: %s\n' "$cruby_artifact_dir"
