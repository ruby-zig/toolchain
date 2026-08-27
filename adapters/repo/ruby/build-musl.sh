#!/usr/bin/env bash

set -euo pipefail

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_contract="$adapter_root/source-contract.sh"
source_patch="$adapter_root/patches/cross-x86_64-linux-musl.patch"

for path in \
  "$source_root/autogen.sh" \
  "$source_root/configure.ac" \
  "$source_root/ruby.c" \
  "$source_root/thread_pthread.c" \
  "$source_contract" \
  "$source_patch"; do
  if [[ ! -f "$path" ]]; then
    printf 'CRuby source or adapter file is missing: %s\n' "$path" >&2
    exit 66
  fi
done

for command in awk autoconf cp file git grep make nm readelf ruby sed sha256sum sort; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'CRuby musl adapter requires %s\n' "$command" >&2
    exit 69
  fi
done

: "${RZ_TOOLCHAIN_BIN:?source export-toolchain.sh before running the adapter}"
: "${RZ_ZIG_TARGET:?source export-toolchain.sh before running the adapter}"
: "${RZ_AUTOCONF_HOST:?source export-toolchain.sh before running the adapter}"
: "${RZ_RECEIPT_DIR:?run the adapter through run-certified.sh}"
: "${RZ_SOURCE_REF_NAME:?the manifest must bind the source ref name}"
: "${RZ_SOURCE_REF:?the manifest must bind the exact source SHA}"

case "${RZ_ENABLE_RUST:-false}" in
  0|false|'') ;;
  *)
    printf 'CRuby cross compilation does not support rustc; disable Rust for this lane\n' >&2
    exit 78
    ;;
esac
if [[ -n "${RUSTC:-}" ]]; then
  printf 'RUSTC must be unset for the CRuby musl lane; configure receives RUSTC=no\n' >&2
  exit 64
fi

if [[ "$RZ_ZIG_TARGET" != x86_64-linux-musl ||
      "$RZ_AUTOCONF_HOST" != x86_64-linux-musl ]]; then
  printf 'CRuby musl adapter supports only x86_64-linux-musl\n' >&2
  exit 78
fi

expected_variables=(
  CC CXX AR RANLIB LD LDSHARED
  BUILD_CC BUILD_CXX CC_FOR_BUILD CXX_FOR_BUILD AR_FOR_BUILD RANLIB_FOR_BUILD
)
expected_values=(
  "$RZ_TOOLCHAIN_BIN/rz-cc"
  "$RZ_TOOLCHAIN_BIN/rz-cxx"
  "$RZ_TOOLCHAIN_BIN/rz-ar"
  "$RZ_TOOLCHAIN_BIN/rz-ranlib"
  "$RZ_TOOLCHAIN_BIN/rz-cc"
  "$RZ_TOOLCHAIN_BIN/rz-shared"
  "$RZ_TOOLCHAIN_BIN/rz-host-cc"
  "$RZ_TOOLCHAIN_BIN/rz-host-cxx"
  "$RZ_TOOLCHAIN_BIN/rz-host-cc"
  "$RZ_TOOLCHAIN_BIN/rz-host-cxx"
  "$RZ_TOOLCHAIN_BIN/rz-host-ar"
  "$RZ_TOOLCHAIN_BIN/rz-host-ranlib"
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
# shellcheck disable=SC1090
source "$source_contract"
rz_ruby_source_contract "$source_sha"
if [[ "$source_branch" != master ]]; then
  printf 'CRuby musl adapter currently tracks only master\n' >&2
  exit 78
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  printf 'CRuby musl adapter requires a clean source checkout\n' >&2
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
  printf 'CRuby musl adapter requires a clean checkout without %s\n' "$build_root" >&2
  exit 73
fi

patch_sha="$(sha256sum "$source_patch" | awk '{print $1}')"
git apply --check "$source_patch"
git apply "$source_patch"
git diff --check
modified_paths="$(git diff --name-only | sort | tr '\n' ' ')"
if [[ "$modified_paths" != 'common.mk thread_pthread.c tool/dump_ast.mkmf.rb tool/m4/ruby_prog_gnu_ld.m4 ' ]]; then
  printf 'CRuby musl patch changed unexpected paths: %s\n' "$modified_paths" >&2
  exit 65
fi

baseruby="$(command -v ruby)"
case "$baseruby" in
  /*) ;;
  *)
    printf 'CRuby musl adapter requires an absolute baseruby path\n' >&2
    exit 69
    ;;
esac

export RZ_ZIG_HOST_TARGET=x86_64-linux-gnu.2.17
export JSON_DISABLE_SIMD=1
bash "$source_root/autogen.sh"
for helper in config.guess config.sub; do
  if [[ ! -x "$source_root/tool/$helper" ]]; then
    printf 'autogen.sh did not produce executable tool/%s\n' "$helper" >&2
    exit 66
  fi
done
build_tuple="$("$source_root/tool/config.guess")"
build_tuple="$("$source_root/tool/config.sub" "$build_tuple")"
host_tuple="$("$source_root/tool/config.sub" "$RZ_AUTOCONF_HOST")"
if [[ "$build_tuple" != x86_64-pc-linux-gnu ||
      "$host_tuple" != x86_64-pc-linux-musl ||
      "$build_tuple" == "$host_tuple" ]]; then
  printf 'unexpected CRuby build/host tuples: build=%s host=%s\n' \
    "$build_tuple" "$host_tuple" >&2
  exit 65
fi

mkdir -p "$build_root"
export ZIG_LOCAL_CACHE_DIR="$build_root/.zig-local-cache"
export ZIG_GLOBAL_CACHE_DIR="$build_root/.zig-global-cache"
cd "$build_root"

# CRuby appends strip flags after a successful probe. Use a failing executable
# for the probe, verify the result, then normalize the generated setting to `:`.
"$source_root/configure" \
  --srcdir="$source_root" \
  --build="$build_tuple" \
  --host="$host_tuple" \
  --with-baseruby="$baseruby" \
  --without-git \
  --without-gmp \
  --disable-install-doc \
  --disable-fortify-source \
  --disable-shared \
  --with-static-linked-ext \
  --with-out-ext='*fiddle*,*win32ole*,openssl,psych,zlib' \
  --disable-yjit \
  --disable-zjit \
  CC="$CC" \
  CXX="$CXX" \
  CPP="$CC -E" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LD="$LD" \
  LDSHARED="$LDSHARED" \
  BUILD_CC="$BUILD_CC" \
  BUILD_CXX="$BUILD_CXX" \
  CC_FOR_BUILD="$CC_FOR_BUILD" \
  CXX_FOR_BUILD="$CXX_FOR_BUILD" \
  AR_FOR_BUILD="$AR_FOR_BUILD" \
  RANLIB_FOR_BUILD="$RANLIB_FOR_BUILD" \
  RUSTC=no \
  OBJCOPY=: \
  STRIP=/bin/false \
  warnflags='-Wall -Wextra -Werror=unknown-warning-option -Wno-missing-field-initializers -Wno-unused-parameter'

config_status_strip_records() {
  awk 'index($0, "S[\"STRIP\"]=") == 1 {print}' config.status
}
configured_strip_record="$(config_status_strip_records)"
if [[ "$configured_strip_record" != 'S["STRIP"]="/bin/false"' ]]; then
  printf 'config.status has unexpected STRIP record: %s\n' \
    "${configured_strip_record:-unset}" >&2
  exit 65
fi
sed -i 's|^S\["STRIP"\]="/bin/false"$|S["STRIP"]=":"|' config.status
configured_strip_record="$(config_status_strip_records)"
if [[ "$configured_strip_record" != 'S["STRIP"]=":"' ]]; then
  printf 'could not normalize config.status STRIP record: %s\n' \
    "${configured_strip_record:-unset}" >&2
  exit 65
fi
./config.status Makefile

make_value() {
  local name=$1
  local rule
  # shellcheck disable=SC2016
  printf -v rule 'ruby_zig_print:;@printf "%%s\\n" "$(%s)"' "$name"
  make -s --no-print-directory -f Makefile 'OBJCOPY=:' 'STRIP=:' \
    --eval="$rule" ruby_zig_print
}
if [[ "$(make_value CROSS_COMPILING)" != yes ||
      "$(make_value RUSTC)" != no ||
      "$(make_value CC)" != "$CC" ||
      "$(make_value AR)" != "$AR" ]]; then
  printf 'generated CRuby Makefile does not preserve the cross Zig contract\n' >&2
  exit 65
fi

overrides=('OBJCOPY=:' 'STRIP=:' 'RUSTC=no')
make -j"$jobs" V=1 "${overrides[@]}"
# Cross builds use baseruby as their generator; request the target miniruby
# explicitly so both target executables are built and runnable evidence exists.
make -j"$jobs" V=1 "${overrides[@]}" miniruby
make V=1 "${overrides[@]}" showflags

artifacts=(./miniruby ./ruby ./libruby-static.a ./rbconfig.rb)
for artifact in "${artifacts[@]}"; do
  if [[ ! -s "$artifact" ]]; then
    printf 'missing CRuby musl artifact: %s\n' "$artifact" >&2
    exit 66
  fi
done

for elf in ./miniruby ./ruby; do
  file "$elf"
  if ! file "$elf" | grep -q 'statically linked'; then
    printf '%s is not a static executable\n' "$elf" >&2
    exit 65
  fi
  readelf -h "$elf"
  if readelf -l "$elf" | grep -q INTERP; then
    printf '%s unexpectedly has a program interpreter\n' "$elf" >&2
    exit 65
  fi
  if readelf -d "$elf" 2>/dev/null | grep -q NEEDED; then
    printf '%s unexpectedly has dynamic dependencies\n' "$elf" >&2
    exit 65
  fi
  if readelf --version-info "$elf" 2>/dev/null | grep -q GLIBC_; then
    printf '%s unexpectedly has a glibc symbol-version dependency\n' "$elf" >&2
    exit 65
  fi
  for symbol in __init_libc __libc_start_main __libc_start_init; do
    if ! nm -P "$elf" | awk -v symbol="$symbol" \
      '$1 == symbol {found=1} END {exit !found}'; then
      printf '%s lacks musl startup symbol %s\n' "$elf" "$symbol" >&2
      exit 65
    fi
  done
done

./miniruby --disable-gems --version
./ruby --disable-gems --version
./ruby --disable-gems -I. -rrbconfig -e '
  required = {
    "CC" => ENV.fetch("CC"),
    "CXX" => ENV.fetch("CXX"),
    "AR" => ENV.fetch("AR"),
    "RANLIB" => ENV.fetch("RANLIB"),
    "LD" => ENV.fetch("LD"),
    "LDSHARED" => ENV.fetch("LDSHARED"),
    "RUSTC" => "no",
    "ENABLE_SHARED" => "no",
    "YJIT_SUPPORT" => "no",
    "ZJIT_SUPPORT" => "no",
  }
  required.each do |key, expected|
    actual = RbConfig::CONFIG.fetch(key)
    abort "#{key}=#{actual.inspect}, expected #{expected.inspect}" unless actual == expected
  end
  abort "not musl" unless RbConfig::CONFIG.fetch("host_os").include?("musl")
  abort "YJIT constant present" if defined?(RubyVM::YJIT)
  abort "ZJIT constant present" if defined?(RubyVM::ZJIT)
  puts "static musl configuration passed"
'

bootstrap_log="$build_root/bootstraptest.log"
basic_log="$build_root/basictest.log"
make -j"$jobs" V=1 "${overrides[@]}" btest-bruby 2>&1 | tee "$bootstrap_log"
./ruby --disable-gems -I"$source_root/lib" -W1 \
  "$source_root/basictest/test.rb" >"$basic_log" 2>&1
grep -F 'end of test' "$basic_log"
./ruby --disable-gems \
  -I"$source_root/lib" -I. -I.ext/common \
  -rdate -rdigest -rio/console -rjson -rsocket -rstringio -rstrscan \
  -e 'puts "static musl extension smoke passed"'

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
if [[ ! -s "$receipt_file" ]]; then
  printf 'missing wrapper receipt ledger: %s\n' "$receipt_file" >&2
  exit 66
fi
if grep -Eq $'\ttool=(rustc-target|rustc-host|rust-link|rust-host-link)\t' "$receipt_file"; then
  printf 'CRuby musl lane unexpectedly invoked Rust\n' >&2
  exit 65
fi
awk -F '\t' '
  {
    tool=""; target=""; operation=""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^tool=/) tool = substr($i, 6)
      if ($i ~ /^target=/) target = substr($i, 8)
      if ($i ~ /^operation=/) operation = substr($i, 11)
    }
    if (tool ~ /^host-/) {
      if (target != "x86_64-linux-gnu.2.17") bad = 1
      if (operation ~ /^(compile|link|archive)$/) host++
    }
    else {
      if (target != "x86_64-linux-musl") bad = 1
      if (operation ~ /^(compile|link|archive)$/) target_ops++
    }
  }
  END {exit bad || !host || !target_ops}
' "$receipt_file" || {
  printf 'wrapper receipts do not prove distinct GNU host and musl target transformations\n' >&2
  exit 65
}
if ! grep -F $'tool=host-cc\ttarget=x86_64-linux-gnu.2.17' "$receipt_file" |
     grep -F '/build-tool' >/dev/null; then
  printf 'no host-Zig receipt found for CRuby build-tool/dump_ast\n' >&2
  exit 65
fi

artifact_root="${RZ_ARTIFACT_DIR:-$source_root/.ruby-zig-artifacts}"
evidence_dir="$artifact_root/$RZ_ZIG_TARGET/cruby"
if [[ -e "$evidence_dir" ]]; then
  printf 'refusing to reuse CRuby musl evidence directory: %s\n' "$evidence_dir" >&2
  exit 73
fi
report_dir="$evidence_dir/reports"
mkdir -p "$report_dir"
cp -- "${artifacts[@]}" "$source_patch" "$bootstrap_log" "$basic_log" "$evidence_dir/"
for elf in ./miniruby ./ruby; do
  name="${elf##*/}"
  readelf -h "$elf" >"$report_dir/$name.readelf-header.txt"
  readelf -l "$elf" >"$report_dir/$name.readelf-program.txt"
  readelf -d "$elf" >"$report_dir/$name.readelf-dynamic.txt"
  nm -P "$elf" >"$report_dir/$name.nm.txt"
done
awk -F '\t' '
  {
    tool=""; target=""; operation=""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^tool=/) tool = substr($i, 6)
      if ($i ~ /^target=/) target = substr($i, 8)
      if ($i ~ /^operation=/) operation = substr($i, 11)
    }
    counts[tool "/" target "/" operation]++
  }
  END {for (key in counts) print key, counts[key]}
' "$receipt_file" | sort >"$report_dir/receipt-summary.txt"
(
  cd "$evidence_dir"
  sha256sum miniruby ruby libruby-static.a rbconfig.rb \
    cross-x86_64-linux-musl.patch bootstraptest.log basictest.log reports/* \
    >sha256.txt
)

printf 'source_branch=%s source_sha=%s patch_sha=%s build=%s host=%s jobs=%s\n' \
  "$source_branch" "$source_sha" "$patch_sha" "$build_tuple" "$host_tuple" "$jobs"
printf 'staged curated CRuby musl evidence: %s\n' "$evidence_dir"
