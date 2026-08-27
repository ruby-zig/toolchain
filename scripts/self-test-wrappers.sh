#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

fake_zig="$work/fake-zig"
cat >"$fake_zig" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == version ]]; then printf '0.16.0\n'; fi
exit 0
EOF
chmod +x "$fake_zig"

fake_rustc="$work/fake-rustc"
cat >"$fake_rustc" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'rustc 1.98.0 (test 2026-08-20)\n' ;;
  -vV) printf 'rustc 1.98.0 (test 2026-08-20)\nhost: x86_64-unknown-linux-gnu\n' ;;
esac
exit 0
EOF
chmod +x "$fake_rustc"

export RZ_ZIG="$fake_zig"
export RZ_RUSTC="$fake_rustc"
export RZ_RUST_TOOLCHAIN=1.98.0
export RZ_ENABLE_RUST=true
export RZ_RECEIPT_DIR="$work/receipts"
# shellcheck source=export-toolchain.sh
source "$root/scripts/export-toolchain.sh" x86_64-linux-gnu.2.17 >/dev/null

target_cc_name=CC_x86_64_unknown_linux_gnu
target_cxx_name=CXX_x86_64_unknown_linux_gnu
target_ar_name=AR_x86_64_unknown_linux_gnu
test "${!target_cc_name}" = "$root/toolchain/bin/rz-cc"
test "${!target_cxx_name}" = "$root/toolchain/bin/rz-cxx"
test "${!target_ar_name}" = "$root/toolchain/bin/rz-ar"
test "$HOST_CC" = "$root/toolchain/bin/rz-host-cc"
test "$HOST_CXX" = "$root/toolchain/bin/rz-host-cxx"
test "$HOST_AR" = "$root/toolchain/bin/rz-host-ar"

"$CC" -c sample.c -o sample.o
"$CXX" -c sample.cc -o sample-cxx.o
"$AR" rcs sample.a sample.o
"$RANLIB" sample.a
"$LDSHARED" sample.o -o sample.so
"$HOST_CC" -c generator.c -o generator.o
"$HOST_CXX" -c generator.cc -o generator-cxx.o
"$HOST_AR" rcs generator.a generator.o
"$HOST_RANLIB" generator.a
"$RUSTC" --target "$RZ_RUST_TARGET" --crate-name target sample.rs
"$RUSTC" --crate-name host build.rs
"$root/toolchain/bin/rz-rust-linker" sample.o -o sample
"$root/toolchain/bin/rz-rust-host-linker" generator.o -o generator

for index in $(seq 1 40); do
  "$CC" -c "parallel-$index.c" -o "parallel-$index.o" &
done
wait

if "$CC" --target=not-certified -c bad.c 2>/dev/null; then
  printf 'C wrapper accepted a target override\n' >&2
  exit 1
fi
if "$RUSTC" --target aarch64-unknown-linux-gnu bad.rs 2>/dev/null; then
  printf 'rustc wrapper accepted an undeclared target\n' >&2
  exit 1
fi

receipt_file="$RZ_RECEIPT_DIR/invocations.tsv"
test "$(wc -l <"$receipt_file")" -eq 53
for kind in cc cxx ar ranlib shared host-cc host-cxx host-ar host-ranlib rust-link rust-host-link rustc-target rustc-host; do
  grep -F "tool=$kind" "$receipt_file" >/dev/null
done

trace="$work/trace"
: >"$trace"
while IFS=$'\t' read -r _ pid_field tool_field _; do
  pid="${pid_field#pid=}"
  tool="${tool_field#tool=}"
  case "$tool" in
    rustc-target|rustc-host) executable="$fake_rustc" ;;
    *) executable="$fake_zig" ;;
  esac
  printf '%s execve("%s", ["%s"], 0x0) = 0\n' "$pid" "$executable" "$tool" >>"$trace"
done <"$receipt_file"
"$root/scripts/check-trace.sh" "$trace" "$RZ_RECEIPT_DIR" >/dev/null

printf 'wrapper self-test passed\n'
