#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'
readonly platform_include_dir='/usr/include'
readonly platform_zlib_header='/usr/include/zlib.h'
readonly platform_zconf_header='/usr/include/zconf.h'
readonly platform_library_dir='/usr/lib/x86_64-linux-gnu'
readonly platform_linker_input='/usr/lib/x86_64-linux-gnu/libz.so'
readonly platform_runtime_input='/usr/lib/x86_64-linux-gnu/libz.so.1'

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_files=(
  "$source_root/ext/zlib/extconf.rb"
  "$source_root/ext/zlib/zlib.c"
)
for source_file in "${source_files[@]}"; do
  [[ -f "$source_file" ]] || {
    printf 'run this adapter from the zlib repository root; missing %s\n' \
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
  printf 'zlib adapter is implemented only for Zig target x86_64-linux-gnu.2.17; got %s\n' \
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
  awk cp env file git grep make readelf realpath ruby sed sha256sum sort tail; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'zlib adapter requires %s\n' "$command_name" >&2
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
  printf 'zlib adapter requires Ruby %s; got %s\n' \
    "$expected_ruby_version" "$actual_ruby_version" >&2
  exit 78
}

for platform_input in \
  "$platform_zlib_header" "$platform_zconf_header" \
  "$platform_linker_input" "$platform_runtime_input"; do
  [[ -s "$platform_input" ]] || {
    printf 'declared GNU zlib platform input is missing: %s\n' \
      "$platform_input" >&2
    exit 69
  }
done

platform_soname="$({
  readelf -d "$platform_runtime_input" |
    sed -n 's/.*(SONAME).*\[\([^]]*\)\].*/\1/p'
} | tail -n 1)"
[[ "$platform_soname" == libz.so.1 ]] || {
  printf 'declared GNU zlib runtime input has unexpected SONAME: %s\n' \
    "${platform_soname:-none}" >&2
  exit 70
}

platform_glibc_max="$({
  readelf --version-info "$platform_runtime_input" |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
    sort -V
} | tail -n 1)"
if [[ -n "$platform_glibc_max" ]]; then
  newest="$(printf '%s\n%s\n' 2.17 "$platform_glibc_max" | sort -V | tail -n 1)"
  [[ "$newest" == 2.17 ]] || {
    printf 'declared GNU zlib input requires GLIBC_%s, above the 2.17 ceiling\n' \
      "$platform_glibc_max" >&2
    exit 70
  }
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
      printf 'zlib adapter outputs must remain outside the source worktree: %s\n' \
        "$output_root" >&2
      exit 78
      ;;
  esac
done

build_dir="$build_root/zlib-$RZ_ZIG_TARGET"
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

staged_source="$build_dir/source"
compile_dir="$build_dir/work"
mkdir -p "$staged_source" "$compile_dir"
cp "$source_root/ext/zlib/extconf.rb" "$staged_source/extconf.rb"
cp "$source_root/ext/zlib/zlib.c" "$staged_source/zlib.c"

preprocess_source="$build_dir/zlib-platform-probe.c"
preprocess_output="$build_dir/zlib-platform-probe.i"
printf '%s\n' \
  '#include <zlib.h>' \
  'const char *ruby_zig_zlib_version = ZLIB_VERSION;' \
  >"$preprocess_source"
"$CC" -E -I"$platform_include_dir" \
  "$preprocess_source" -o "$preprocess_output"
[[ -s "$preprocess_output" ]] || {
  printf 'Zig preprocessing did not produce the zlib platform probe\n' >&2
  exit 70
}
grep -Fq 'ruby_zig_zlib_version' "$preprocess_output" || {
  printf 'Zig preprocessing omitted the zlib version declaration\n' >&2
  exit 70
}
if grep -Fq 'ZLIB_VERSION' "$preprocess_output"; then
  printf 'Zig preprocessing did not expand the zlib version macro\n' >&2
  exit 70
fi

(
  cd "$compile_dir"
  RZ_ZLIB_PLATFORM_INCLUDE="$platform_include_dir" \
    RZ_ZLIB_PLATFORM_LIB="$platform_library_dir" \
    ruby -rrbconfig -e '
    %w[CC CXX AR RANLIB LD LDSHARED].each do |key|
      value = ENV.fetch(key)
      RbConfig::CONFIG[key] = value
      RbConfig::MAKEFILE_CONFIG[key] = value
    end
    cpp = "#{ENV.fetch("CC")} -E"
    RbConfig::CONFIG["CPP"] = cpp
    RbConfig::MAKEFILE_CONFIG["CPP"] = cpp
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
    ARGV.unshift("--with-zlib-lib=#{ENV.fetch("RZ_ZLIB_PLATFORM_LIB")}")
    ARGV.unshift("--with-zlib-include=#{ENV.fetch("RZ_ZLIB_PLATFORM_INCLUDE")}")
    ARGV.unshift("--srcdir=#{File.dirname(script)}")
    load script
  ' "$staged_source/extconf.rb"
  make -j"$jobs" V=1 \
    "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" \
    "LD=$LD" "LDSHARED=$LDSHARED" "CPP=$CC -E"
)

artifact="$compile_dir/zlib.so"
[[ -s "$artifact" ]] || {
  printf 'zlib extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/zlib.so"
artifact="$artifact_dir/zlib.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected zlib artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq \
  'Machine:[[:space:]]+Advanced Micro Devices X86-64'

mapfile -t init_exports < <(
  readelf --dyn-syms --wide "$artifact" |
    awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
)
if [[ ${#init_exports[@]} -ne 1 || "${init_exports[0]:-}" != Init_zlib ]]; then
  printf 'zlib artifact must export only Init_zlib; got: %s\n' \
    "${init_exports[*]:-none}" >&2
  exit 70
fi

dynamic="$(readelf -d "$artifact")"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
  printf 'zlib artifact must not contain RPATH or RUNPATH\n' >&2
  exit 70
fi

mapfile -t dependencies < <(
  sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' <<<"$dynamic" | sort -u
)
printf '%s\n' "${dependencies[@]}" | grep -Fxq libz.so.1 || {
  printf 'zlib artifact does not depend on the declared libz.so.1 input\n' >&2
  exit 70
}
ruby_soname="$(ruby -rrbconfig -e 'print RbConfig::CONFIG.fetch("LIBRUBY_SONAME")')"
printf '%s\n' "${dependencies[@]}" | grep -Fxq "$ruby_soname" || {
  printf 'zlib artifact does not depend on the active Ruby runtime: %s\n' \
    "$ruby_soname" >&2
  exit 70
}

glibc_max="$({
  readelf --version-info "$artifact" |
    sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' |
    sort -V
} | tail -n 1)"
if [[ -n "$glibc_max" ]]; then
  newest="$(printf '%s\n%s\n' 2.17 "$glibc_max" | sort -V | tail -n 1)"
  [[ "$newest" == 2.17 ]] || {
    printf 'zlib extension requires GLIBC_%s, above the declared 2.17 ceiling\n' \
      "$glibc_max" >&2
    exit 70
  }
fi

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
[[ -s "$receipt_file" ]] || {
  printf 'zlib build produced no Zig wrapper receipts: %s\n' \
    "$receipt_file" >&2
  exit 70
}
grep -Eq $'\ttool=cc\t.*\toperation=probe\t' "$receipt_file" || {
  printf 'zlib build has no Zig preprocessing receipt\n' >&2
  exit 70
}
grep -Eq $'\ttool=cc\t.*\toperation=compile\t' "$receipt_file" || {
  printf 'zlib build has no Zig C compilation receipt\n' >&2
  exit 70
}
grep -Eq $'\ttool=cc\t.*\toperation=link\t' "$receipt_file" || {
  printf 'zlib build has no Zig configuration-link receipt\n' >&2
  exit 70
}
grep -Eq $'\ttool=shared\t.*\toperation=link\t' "$receipt_file" || {
  printf 'zlib build has no Zig shared-link receipt\n' >&2
  exit 70
}

env -u RUBYLIB -u RUBYOPT \
  ruby --disable-gems "$adapter_root/runtime-test.rb" "$artifact"

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'zlib source HEAD changed during the build\n' >&2
  exit 70
}
post_status="$(git -C "$source_root" status --porcelain=v1 --untracked-files=all)"
[[ -z "$post_status" ]] || {
  printf 'zlib build modified the source worktree:\n%s\n' "$post_status" >&2
  exit 70
}

dependency_csv="$(IFS=,; printf '%s' "${dependencies[*]}")"
printf 'zlib GNU artifact passed; glibc_max=%s platform_glibc_max=%s dependencies=%s\n' \
  "${glibc_max:-none}" "${platform_glibc_max:-none}" "$dependency_csv"
sha256sum "$artifact"
