#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${RZ_SMOKE_OUT:?RZ_SMOKE_OUT is required}"
mkdir -p "$out"

"$CC" -c "$root/tests/smoke/hello.c" -o "$out/hello.o"
"$CXX" -c "$root/tests/smoke/hello.cc" -o "$out/hello-cxx.o"
"$AR" rcs "$out/libhello.a" "$out/hello.o" "$out/hello-cxx.o"
"$RANLIB" "$out/libhello.a"
"$CC" "$out/hello.o" -o "$out/hello-c"

if [[ "${RZ_ENABLE_RUST:-false}" == 'true' ]]; then
  "$RUSTC" --target "$RZ_RUST_TARGET" "$root/tests/smoke/hello.rs" -o "$out/hello-rust"
fi

if [[ "${RZ_RUN_ARTIFACT:-false}" == 'true' ]]; then
  "$out/hello-c"
  if [[ "${RZ_ENABLE_RUST:-false}" == 'true' ]]; then
    "$out/hello-rust"
  fi
fi
