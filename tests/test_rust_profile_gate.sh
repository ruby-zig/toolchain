#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/zig" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then
  printf '0.16.0\n'
  exit 0
fi
exit 64
EOF
chmod +x "$tmp/zig"

if (
  export RZ_ZIG="$tmp/zig"
  export RZ_ENABLE_RUST=true
  export RZ_RECEIPT_DIR="$tmp/rust-receipts"
  source "$root/scripts/export-toolchain.sh" riscv64-linux-musl
) >"$tmp/unverified.out" 2>&1; then
  printf 'unverified Rust profile unexpectedly passed the toolchain gate\n' >&2
  exit 1
fi
grep -F 'only smoke-verified profiles may enable Rust' "$tmp/unverified.out" >/dev/null

(
  export RZ_ZIG="$tmp/zig"
  export RZ_ENABLE_RUST=false
  export RZ_RECEIPT_DIR="$tmp/c-only-receipts"
  source "$root/scripts/export-toolchain.sh" riscv64-linux-musl
  [[ "$CC" == "$root/toolchain/bin/rz-cc" ]]
) >/dev/null

grep -F '[[ "$RZ_RUST_INPUT" == true && "$rust_status" != smoke-verified ]]' \
  "$root/action.yml" >/dev/null

printf 'Rust profile gate passed\n'
