#!/usr/bin/env bash

set -euo pipefail

root="$(pwd -P)"

for path in \
  "$root/Makefile" \
  "$root/config.yml" \
  "$root/templates/template.rb" \
  "$root/rust/Cargo.toml" \
  "$root/rust/Cargo.lock"; do
  if [[ ! -f "$path" ]]; then
    printf 'Prism source file is missing: %s\n' "$path" >&2
    exit 66
  fi
done

for command in ruby make cargo awk; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Prism adapter requires %s\n' "$command" >&2
    exit 69
  fi
done

: "${CC:?CC must be the Zig C wrapper}"
: "${CXX:?CXX must be the Zig C++ wrapper}"
: "${RZ_TOOLCHAIN_BIN:?source export-toolchain.sh before running the adapter}"
: "${RZ_ZIG_TARGET:?source export-toolchain.sh before running the adapter}"
: "${RZ_RUST_TARGET:?source export-toolchain.sh before running the adapter}"

case "$RZ_ZIG_TARGET" in
  x86_64-linux-gnu.2.17|x86_64-linux-musl) ;;
  *)
    printf 'Prism adapter has not been validated for Zig target %s\n' "$RZ_ZIG_TARGET" >&2
    exit 78
    ;;
esac

case "${RZ_ENABLE_RUST:-false}" in
  1|true) ;;
  *)
    printf 'Prism adapter requires the pinned Rust lane\n' >&2
    exit 78
    ;;
esac

if [[ "${RZ_RUST_HOST_TARGET:-}" != x86_64-unknown-linux-gnu ]]; then
  printf 'Prism adapter requires an x86_64 GNU/Linux Rust host, got %s\n' \
    "${RZ_RUST_HOST_TARGET:-unset}" >&2
  exit 78
fi

# Keep Cargo build scripts on a declared Zig host target. In particular, this
# prevents native compiler discovery while the Rust target is musl.
export RZ_ZIG_HOST_TARGET=x86_64-linux-gnu.2.17

if [[ -n "${RZ_BUILD_JOBS:-}" ]]; then
  jobs="$RZ_BUILD_JOBS"
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

if [[ -e "$root/build" ]]; then
  printf 'Prism adapter requires a clean checkout without build/\n' >&2
  exit 73
fi

ruby "$root/templates/template.rb"
make -j"$jobs" V=1 SOEXT=so all

artifact_root="$root/build/ruby-zig/$RZ_ZIG_TARGET"
mkdir -p "$artifact_root"
"$CXX" -std=c++17 -Wno-nullability-completeness -I"$root/include" \
  -o "$artifact_root/prism-cpp-smoke" \
  "$root/cpp/test.cpp" "$root"/build/static/*.o
"$artifact_root/prism-cpp-smoke" >"$artifact_root/prism-cpp-smoke.out"
grep -q 'ProgramNode' "$artifact_root/prism-cpp-smoke.out"

sys_version="$(awk -F'"' '/^version = / { print $2; exit }' \
  "$root/rust/ruby-prism-sys/Cargo.toml")"
prism_version="$(awk -F'"' '/^version = / { print $2; exit }' \
  "$root/rust/ruby-prism/Cargo.toml")"
if [[ -z "$sys_version" || "$sys_version" != "$prism_version" ]]; then
  printf 'Prism Rust crate versions do not match\n' >&2
  exit 65
fi

sys_vendor="$root/rust/ruby-prism-sys/vendor/prism-$sys_version"
prism_vendor="$root/rust/ruby-prism/vendor/prism-$prism_version"
for path in "${sys_vendor%/*}" "${prism_vendor%/*}"; do
  if [[ -e "$path" ]]; then
    printf 'Prism adapter requires a clean checkout without %s\n' "$path" >&2
    exit 73
  fi
done

mkdir -p "$sys_vendor" "$prism_vendor"
cp -R "$root/include" "$root/src" "$sys_vendor/"
ruby -ryaml -rjson -e \
  'File.write(ARGV.fetch(1), JSON.generate(YAML.load_file(ARGV.fetch(0))))' \
  "$root/config.yml" "$prism_vendor/config.json"

# cc-rs must not add a second --target flag; the wrapper owns target, sysroot,
# native dependency compilation, archives, and final links.
export CRATE_CC_NO_DEFAULTS=1
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="$artifact_root/cargo"

cargo test --locked --manifest-path "$root/rust/Cargo.toml" --workspace \
  --target "$RZ_RUST_TARGET" --jobs "$jobs" -- --nocapture
