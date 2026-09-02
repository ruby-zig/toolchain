#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'
readonly implemented_target='x86_64-linux-gnu.2.17'
readonly implemented_host='x86_64-linux-gnu'

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
pin_file="$adapter_root/libffi.json"
source_files=(
  "$source_root/ext/fiddle/extconf.rb"
  "$source_root/ext/fiddle/closure.c"
  "$source_root/ext/fiddle/closure.h"
  "$source_root/ext/fiddle/conversions.c"
  "$source_root/ext/fiddle/conversions.h"
  "$source_root/ext/fiddle/fiddle.c"
  "$source_root/ext/fiddle/fiddle.h"
  "$source_root/ext/fiddle/function.c"
  "$source_root/ext/fiddle/function.h"
  "$source_root/ext/fiddle/handle.c"
  "$source_root/ext/fiddle/memory_view.c"
  "$source_root/ext/fiddle/pinned.c"
  "$source_root/ext/fiddle/pointer.c"
  "$source_root/ext/fiddle/depend"
  "$source_root/lib/fiddle.rb"
  "$source_root/lib/fiddle/closure.rb"
  "$source_root/lib/fiddle/function.rb"
  "$source_root/lib/fiddle/version.rb"
  "$pin_file"
)
for source_file in "${source_files[@]}"; do
  [[ -f "$source_file" ]] || {
    printf 'run this adapter from the fiddle repository root; missing %s\n' \
      "$source_file" >&2
    exit 66
  }
done

bash "$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
: "${RZ_AUTOCONF_HOST:?source the ruby.zig toolchain environment first}"
: "${RZ_RECEIPT_DIR:?certified adapters require a wrapper receipt directory}"
: "${RZ_DEP_LIBFFI_ARCHIVE:?set RZ_DEP_LIBFFI_ARCHIVE to the pinned libffi release archive}"

[[ "$RZ_ZIG_TARGET" == "$implemented_target" ]] || {
  printf 'fiddle adapter is implemented only for Zig target %s; got %s\n' \
    "$implemented_target" "$RZ_ZIG_TARGET" >&2
  exit 78
}
[[ "$RZ_AUTOCONF_HOST" == "$implemented_host" ]] || {
  printf 'fiddle adapter requires Autoconf host %s; got %s\n' \
    "$implemented_host" "$RZ_AUTOCONF_HOST" >&2
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
[[ -f "$RZ_DEP_LIBFFI_ARCHIVE" ]] || {
  printf 'pinned libffi archive is missing: %s\n' "$RZ_DEP_LIBFFI_ARCHIVE" >&2
  exit 66
}

for command_name in \
  awk cp env file git grep ln make readelf realpath ruby sed sha256sum sort \
  stat tail tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'fiddle adapter requires %s\n' "$command_name" >&2
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

# This native lane uses the same GNU tuple for build and target. Keep
# Autoconf's build-machine probes on the certified target wrappers as well.
export BUILD_CC="$CC"
export BUILD_CXX="$CXX"
export CC_FOR_BUILD="$CC"
export CXX_FOR_BUILD="$CXX"
export AR_FOR_BUILD="$AR"
export RANLIB_FOR_BUILD="$RANLIB"
export HOST_CC="$CC"
export HOST_CXX="$CXX"
export HOST_AR="$AR"
export HOST_RANLIB="$RANLIB"

actual_ruby_version="$(ruby -e 'print RUBY_VERSION')"
[[ "$actual_ruby_version" == "$expected_ruby_version" ]] || {
  printf 'fiddle adapter requires Ruby %s; got %s\n' \
    "$expected_ruby_version" "$actual_ruby_version" >&2
  exit 78
}

libffi_version="$(ruby --disable-gems -rjson -e \
  'print JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' "$pin_file")"
libffi_root="$(ruby --disable-gems -rjson -e \
  'print JSON.parse(File.read(ARGV.fetch(0))).fetch("archive_root")' "$pin_file")"
libffi_size="$(ruby --disable-gems -rjson -e \
  'print JSON.parse(File.read(ARGV.fetch(0))).fetch("archive_size")' "$pin_file")"
libffi_sha="$(ruby --disable-gems -rjson -e \
  'print JSON.parse(File.read(ARGV.fetch(0))).fetch("sha256")' "$pin_file")"
[[ "$libffi_version" == 3.4.6 && "$libffi_root" == libffi-3.4.6 ]] || {
  printf 'unsupported libffi source pin\n' >&2
  exit 65
}

archive="$(realpath "$RZ_DEP_LIBFFI_ARCHIVE")"
actual_size="$(stat -c %s "$archive")"
[[ "$actual_size" == "$libffi_size" ]] || {
  printf 'libffi archive size mismatch: got %s expected %s\n' \
    "$actual_size" "$libffi_size" >&2
  exit 65
}
actual_libffi_sha="$(sha256sum "$archive" | awk '{print $1}')"
[[ "$actual_libffi_sha" == "$libffi_sha" ]] || {
  printf 'libffi archive SHA-256 mismatch: got %s expected %s\n' \
    "$actual_libffi_sha" "$libffi_sha" >&2
  exit 65
}

archive_listing="$(tar -tzf "$archive")"
[[ -n "$archive_listing" ]] || {
  printf 'libffi archive is empty\n' >&2
  exit 65
}
while IFS= read -r member; do
  case "$member" in
    "$libffi_root"|"$libffi_root/"|"$libffi_root/"*) ;;
    *)
      printf 'libffi archive member escapes the pinned root: %s\n' "$member" >&2
      exit 65
      ;;
  esac
  case "/$member/" in
    *'/../'*|*'/./'*)
      printf 'libffi archive member contains an unsafe path component: %s\n' \
        "$member" >&2
      exit 65
      ;;
  esac
done <<<"$archive_listing"
if tar -tvzf "$archive" | awk '$1 ~ /^[lh]/ { unsafe = 1 } END { exit !unsafe }'; then
  printf 'libffi archive contains a symbolic or hard link\n' >&2
  exit 65
fi

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
      printf 'fiddle adapter outputs must remain outside the source worktree: %s\n' \
        "$output_root" >&2
      exit 78
      ;;
  esac
done

build_dir="$build_root/fiddle-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET"
for path in "$build_dir" "$artifact_dir"; do
  [[ ! -e "$path" ]] || {
    printf 'refusing to reuse adapter output: %s\n' "$path" >&2
    exit 73
  }
done
mkdir -p "$build_dir" "$artifact_dir"
export ZIG_LOCAL_CACHE_DIR="$build_dir/.zig-local-cache"
export ZIG_GLOBAL_CACHE_DIR="$build_dir/.zig-global-cache"

dependency_dir="$build_dir/dependency"
staged_source="$build_dir/source"
compile_dir="$build_dir/work"
runtime_dir="$build_dir/runtime"
mkdir -p "$dependency_dir" "$staged_source" "$compile_dir" "$runtime_dir"
tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$dependency_dir"
libffi_source="$dependency_dir/$libffi_root"
for dependency_file in \
  "$libffi_source/configure" \
  "$libffi_source/LICENSE" \
  "$libffi_source/src/closures.c" \
  "$libffi_source/src/prep_cif.c"; do
  [[ -f "$dependency_file" ]] || {
    printf 'pinned libffi source is missing %s\n' "$dependency_file" >&2
    exit 65
  }
done

cp -a "$source_root/ext/fiddle/." "$staged_source/"
# The interpolation below is evaluated by Ruby, not by this shell.
# shellcheck disable=SC2016
ruby --disable-gems -e '
  path = ARGV.fetch(0)
  source = File.read(path)
  quote = 39.chr
  old = "  args << ($enable_shared || !$static ? #{quote}--enable-shared#{quote} : #{quote}--enable-static#{quote})"
  replacement = "  args.concat($enable_shared || !$static ? [#{quote}--enable-shared#{quote}] : [#{quote}--enable-static#{quote}, #{quote}--disable-shared#{quote}])"
  abort "unexpected bundled libffi configure recipe" unless source.scan(old).length == 1
  File.write(path, source.sub(old, replacement))
' "$staged_source/extconf.rb"

export STRIP=:

(
  cd "$compile_dir"
  # Environment references in this program are evaluated by Ruby.
  # shellcheck disable=SC2016
  RZ_LIBFFI_SOURCE="$libffi_source" ruby -rrbconfig -e '
    %w[CC CXX AR RANLIB LD LDSHARED].each do |key|
      value = ENV.fetch(key)
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    cpp = "#{ENV.fetch("CC")} -E"
    RbConfig::CONFIG["CPP"] = cpp
    RbConfig::MAKEFILE_CONFIG["CPP"] = cpp
    {
      "host" => ENV.fetch("RZ_AUTOCONF_HOST"),
      "target" => ENV.fetch("RZ_AUTOCONF_HOST"),
      "CFLAGS" => "-O2 -fPIC -Wno-default-const-init-field-unsafe",
      "CXXFLAGS" => "-O2 -fPIC -Wno-default-const-init-field-unsafe",
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
    ARGV.unshift("--with-libffi-source-dir=#{ENV.fetch("RZ_LIBFFI_SOURCE")}")
    ARGV.unshift("--srcdir=#{File.dirname(script)}")
    require "mkmf"
    $static = true
    $enable_shared = false
    $LIBRUBYARG = ""
    $LIBRUBYARG_STATIC = ""
    load script
  ' "$staged_source/extconf.rb"
  make -j"$jobs" V=1 \
    "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
    "LD=$LD" "LDSHARED=$LDSHARED" "CPP=$CC -E" "STRIP=:"
)

static_libffi="$libffi_source/.libs/libffi_convenience.a"
[[ -s "$static_libffi" ]] || {
  printf 'static libffi convenience archive was not produced: %s\n' \
    "$static_libffi" >&2
  exit 70
}
shopt -s nullglob
shared_libffi=("$libffi_source/.libs"/libffi.so*)
shopt -u nullglob
if [[ ${#shared_libffi[@]} -ne 0 ]]; then
  printf 'libffi dependency build unexpectedly produced shared libraries: %s\n' \
    "${shared_libffi[*]}" >&2
  exit 70
fi

artifact="$compile_dir/fiddle.so"
[[ -s "$artifact" ]] || {
  printf 'fiddle extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/fiddle.so"
artifact="$artifact_dir/fiddle.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected fiddle artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq \
  'Machine:[[:space:]]+Advanced Micro Devices X86-64'

mapfile -t init_exports < <(
  readelf --dyn-syms --wide "$artifact" |
    awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}' |
    sort -u
)
expected_init_exports=(
  Init_fiddle
  Init_fiddle_closure
  Init_fiddle_function
  Init_fiddle_handle
  Init_fiddle_memory_view
  Init_fiddle_pinned
  Init_fiddle_pointer
)
if [[ "${init_exports[*]}" != "${expected_init_exports[*]}" ]]; then
  printf 'fiddle artifact has an unexpected Init export set: %s\n' \
    "${init_exports[*]:-none}" >&2
  exit 70
fi

dynamic="$(readelf -d "$artifact")"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
  printf 'fiddle artifact must not contain RPATH or RUNPATH\n' >&2
  exit 70
fi
mapfile -t dependencies < <(
  sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' <<<"$dynamic" | sort -u
)
if printf '%s\n' "${dependencies[@]}" | grep -Eiq '^libffi([.-]|$)'; then
  printf 'fiddle artifact must not have a dynamic libffi dependency\n' >&2
  exit 70
fi
if readelf --dyn-syms --wide "$artifact" |
  awk '$7 == "UND" && $8 ~ /^ffi_/ { unresolved = 1 } END { exit !unresolved }'; then
  printf 'fiddle artifact has unresolved libffi symbols\n' >&2
  exit 70
fi
for embedded_symbol in ffi_call ffi_closure_alloc ffi_prep_cif; do
  readelf --syms --wide "$artifact" |
    awk -v symbol="$embedded_symbol" \
      '$7 != "UND" && $8 == symbol { found = 1 } END { exit !found }' || {
    printf 'fiddle artifact does not contain static libffi symbol %s\n' \
      "$embedded_symbol" >&2
    exit 70
  }
done

glibc_max="$(
  readelf --version-info "$artifact" |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
    sort -V |
    tail -n 1
)"
if [[ -n "$glibc_max" ]]; then
  newest="$(printf '%s\n%s\n' 2.17 "$glibc_max" | sort -V | tail -n 1)"
  [[ "$newest" == 2.17 ]] || {
    printf 'fiddle requires GLIBC_%s, above the declared 2.17 ceiling\n' \
      "$glibc_max" >&2
    exit 70
  }
fi

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
[[ -s "$receipt_file" ]] || {
  printf 'fiddle build produced no Zig wrapper receipts: %s\n' \
    "$receipt_file" >&2
  exit 70
}
if grep -Ev $'\ttarget='"$RZ_ZIG_TARGET"$'\t' "$receipt_file" \
  >"$build_dir/wrong-target-receipts.tsv"; then
  printf 'fiddle build produced receipts for a target other than %s\n' \
    "$RZ_ZIG_TARGET" >&2
  exit 70
fi
grep -Eq $'\ttool=cc\t.*\toperation=compile\t.*libffi-3.4.6' \
  "$receipt_file" || {
  printf 'fiddle build has no Zig C compilation receipt for libffi\n' >&2
  exit 70
}
grep -Eq $'\ttool=cc\t.*\toperation=compile\t.*fiddle' "$receipt_file" || {
  printf 'fiddle build has no Zig C compilation receipt for Fiddle\n' >&2
  exit 70
}
grep -Eq $'\ttool=ar\t.*\toperation=archive\t.*libffi' "$receipt_file" || {
  printf 'fiddle build has no Zig archive receipt for libffi\n' >&2
  exit 70
}
grep -Eq $'\ttool=ranlib\t.*\toperation=archive\t.*libffi' \
  "$receipt_file" || {
  printf 'fiddle build has no Zig ranlib receipt for libffi\n' >&2
  exit 70
}
grep -Eq $'\ttool=shared\t.*\toperation=link\t.*fiddle' "$receipt_file" || {
  printf 'fiddle build has no Zig shared-link receipt\n' >&2
  exit 70
}

cp -a "$source_root/lib/." "$runtime_dir/"
ln -s "$artifact" "$runtime_dir/fiddle.so"
env -u RUBYLIB -u RUBYOPT \
  ruby --disable-gems "$adapter_root/runtime-test.rb" "$artifact" "$runtime_dir"

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'fiddle source HEAD changed during the build\n' >&2
  exit 70
}
post_status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$post_status" ]] || {
  printf 'fiddle build modified the source worktree:\n%s\n' "$post_status" >&2
  exit 70
}

static_libffi_sha="$(sha256sum "$static_libffi" | awk '{print $1}')"
artifact_sha="$(sha256sum "$artifact" | awk '{print $1}')"
dependency_csv="$(IFS=,; printf '%s' "${dependencies[*]}")"
printf 'fiddle GNU artifact passed; glibc_max=%s dependencies=%s\n' \
  "${glibc_max:-none}" "${dependency_csv:-none}"
printf 'libffi_source_sha256=%s libffi_static_sha256=%s\n' \
  "$actual_libffi_sha" "$static_libffi_sha"
printf '%s  %s\n' "$artifact_sha" "$artifact"
