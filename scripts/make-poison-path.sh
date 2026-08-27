#!/usr/bin/env bash

set -euo pipefail

destination="${1:?usage: make-poison-path.sh DIRECTORY}"
mkdir -p "$destination"

tools=(
  cc c89 c99 gcc gcc-14 g++ cpp clang clang-18 clang++ clang-cl cl
  link ld ld.bfd ld.gold lld ld.lld lld-link rust-lld wasm-ld gold mold
  ar ranlib llvm-ar llvm-ranlib as nasm yasm llvm-mc collect2
  objcopy llvm-objcopy strip llvm-strip
  ccache sccache distcc
)
for tool in "${tools[@]}"; do
  path="$destination/$tool"
  printf '%s\n' '#!/usr/bin/env sh' \
    "printf 'forbidden tool invoked: $tool\\n' >&2" \
    'exit 97' >"$path"
  chmod +x "$path"
done

printf '%s\n' "$destination"
