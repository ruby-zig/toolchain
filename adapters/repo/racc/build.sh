#!/usr/bin/env bash

set -euo pipefail

readonly expected_ruby_version='3.2.3'

source_root="$(pwd -P)"
adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
extconf="$source_root/ext/racc/cparse/extconf.rb"
racc_info="$source_root/lib/racc/info.rb"
source_files=(
  "$extconf"
  "$source_root/ext/racc/cparse/cparse.c"
  "$racc_info"
  "$source_root/lib/racc/parser.rb"
)
for source_file in "${source_files[@]}"; do
  [[ -f "$source_file" ]] || {
    printf 'run this adapter from the racc repository root; missing %s\n' "$source_file" >&2
    exit 66
  }
done

bash "$adapter_root/source-contract.sh" "$source_root"

: "${RZ_TOOLCHAIN_BIN:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG:?source the ruby.zig toolchain environment first}"
: "${RZ_ZIG_TARGET:?source the ruby.zig toolchain environment first}"
: "${RZ_RECEIPT_DIR:?certified adapters require a wrapper receipt directory}"
[[ "$RZ_ZIG_TARGET" == x86_64-linux-gnu.2.17 ]] || {
  printf 'racc adapter is certified only for Zig target x86_64-linux-gnu.2.17; got %s\n' "$RZ_ZIG_TARGET" >&2
  exit 78
}
[[ -x "$RZ_ZIG" ]] || {
  printf 'RZ_ZIG must be the executable pinned Zig compiler: %s\n' "$RZ_ZIG" >&2
  exit 78
}

for command_name in ruby make file readelf sha256sum git grep awk sed sort tail; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'racc adapter requires %s\n' "$command_name" >&2
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
    printf '%s must be the executable controller wrapper %s, got %s\n' "$variable" "$expected" "${actual:-unset}" >&2
    exit 78
  }
done

actual_ruby_version="$(ruby -e 'print RUBY_VERSION')"
[[ "$actual_ruby_version" == "$expected_ruby_version" ]] || {
  printf 'racc adapter requires Ruby %s; got %s\n' "$expected_ruby_version" "$actual_ruby_version" >&2
  exit 78
}

jobs="${RZ_JOBS:-2}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
  printf 'RZ_JOBS must be a positive integer\n' >&2
  exit 64
}

build_root="${RZ_BUILD_ROOT:-$source_root/.ruby-zig-build}"
artifact_root="${RZ_ARTIFACT_DIR:-$source_root/.ruby-zig-artifacts}"
build_dir="$build_root/racc-$RZ_ZIG_TARGET"
artifact_dir="$artifact_root/$RZ_ZIG_TARGET/racc"
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
    script = File.realpath(ARGV.shift)
    supplied_info = File.realpath(ARGV.shift)
    relative_info = File.realpath(
      File.expand_path("../../../lib/racc/info.rb", File.dirname(script))
    )
    abort "extconf source-relative Racc info path changed" unless
      relative_info == supplied_info
    ARGV.unshift("--srcdir=#{File.dirname(script)}")
    load script
  ' "$extconf" "$racc_info"
  make -j"$jobs" V=1 "CC=$CC" "CXX=$CXX" "AR=$AR" "RANLIB=$RANLIB" "LD=$LD" "LDSHARED=$LDSHARED"
)

artifact="$build_dir/cparse.so"
[[ -s "$artifact" ]] || {
  printf 'racc extension was not produced: %s\n' "$artifact" >&2
  exit 70
}
cp "$artifact" "$artifact_dir/cparse.so"
artifact="$artifact_dir/cparse.so"

format="$(file -b "$artifact")"
[[ "$format" == *'ELF 64-bit LSB shared object, x86-64'* ]] || {
  printf 'unexpected racc artifact format: %s\n' "$format" >&2
  exit 70
}
readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+DYN'
readelf -h "$artifact" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'

mapfile -t init_exports < <(
  readelf --dyn-syms --wide "$artifact" |
    awk '$4 == "FUNC" && $5 == "GLOBAL" && $7 != "UND" && $8 ~ /^Init_/ {print $8}'
)
if [[ ${#init_exports[@]} -ne 1 || "${init_exports[0]:-}" != Init_cparse ]]; then
  printf 'racc artifact must export only Init_cparse; got: %s\n' "${init_exports[*]:-none}" >&2
  exit 70
fi

dynamic="$(readelf -d "$artifact")"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then
  printf 'racc artifact must not contain RPATH or RUNPATH\n' >&2
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
    printf 'racc requires GLIBC_%s, above the declared 2.17 ceiling\n' "$glibc_max" >&2
    exit 70
  }
fi

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
[[ -s "$receipt_file" ]] || {
  printf 'racc build produced no Zig wrapper receipts: %s\n' "$receipt_file" >&2
  exit 70
}
grep -Eq $'\ttool=cc\t.*\toperation=compile\t' "$receipt_file" || {
  printf 'racc build has no Zig C compilation receipt\n' >&2
  exit 70
}
grep -Eq $'\ttool=shared\t.*\toperation=link\t' "$receipt_file" || {
  printf 'racc build has no Zig shared-link receipt\n' >&2
  exit 70
}

ruby --disable-gems "$adapter_root/runtime-test.rb" "$artifact" "$source_root/lib"

actual_sha="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_sha" == "$RZ_SOURCE_REF" ]] || {
  printf 'racc source HEAD changed during the build\n' >&2
  exit 70
}
git -C "$source_root" diff --quiet --ignore-submodules -- || {
  printf 'racc build modified tracked source files\n' >&2
  exit 70
}
git -C "$source_root" diff --cached --quiet --ignore-submodules -- || {
  printf 'racc build modified the source index\n' >&2
  exit 70
}

printf 'racc GNU artifact loaded and passed native parser smoke; glibc_max=%s\n' "${glibc_max:-none}"
sha256sum "$artifact"
