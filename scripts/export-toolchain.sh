#!/usr/bin/env bash
# shellcheck disable=SC2317

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: source scripts/export-toolchain.sh PROFILE\n' >&2
  return 64 2>/dev/null || exit 64
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$1"
profile_json="$(jq -cer --arg id "$profile" '.profiles[] | select(.id == $id)' "$root/config/targets.json")" || {
  printf 'unknown target profile: %s\n' "$profile" >&2
  return 65 2>/dev/null || exit 65
}

: "${RZ_ZIG:?RZ_ZIG must name the pinned Zig executable}"
case "$RZ_ZIG" in
  /*) ;;
  *) printf 'RZ_ZIG must be an absolute path: %s\n' "$RZ_ZIG" >&2; return 64 2>/dev/null || exit 64 ;;
esac
if [[ ! -x "$RZ_ZIG" ]]; then
  printf 'Pinned Zig executable is not executable: %s\n' "$RZ_ZIG" >&2
  return 66 2>/dev/null || exit 66
fi
expected_zig="$(jq -r .version "$root/config/zig.json")"
reported_zig="$("$RZ_ZIG" version)"
if [[ "$reported_zig" != "$expected_zig" ]]; then
  printf 'Expected Zig %s, got %s\n' "$expected_zig" "$reported_zig" >&2
  return 65 2>/dev/null || exit 65
fi

RZ_ZIG_TARGET="$(jq -r .zig_target <<<"$profile_json")"
RZ_RUST_TARGET="$(jq -r .rust_target <<<"$profile_json")"
RZ_RUST_LINK_STATUS="$(jq -r .rust_link_status <<<"$profile_json")"
RZ_RUST_LINK_BLOCKER="$(jq -r '.rust_link_blocker // ""' <<<"$profile_json")"
RZ_AUTOCONF_HOST="$(jq -r .autoconf_host <<<"$profile_json")"
RZ_VERIFICATION="$(jq -r .verification <<<"$profile_json")"
export RZ_ZIG_TARGET RZ_RUST_TARGET RZ_RUST_LINK_STATUS RZ_RUST_LINK_BLOCKER
export RZ_AUTOCONF_HOST RZ_VERIFICATION
export RZ_RECEIPT_DIR="${RZ_RECEIPT_DIR:-$root/receipts/$profile}"

bin="$root/toolchain/bin"
export RZ_TOOLCHAIN_BIN="$bin"
export CC="$bin/rz-cc"
export CXX="$bin/rz-cxx"
export OBJC="$bin/rz-cc"
export OBJCXX="$bin/rz-cxx"
export AR="$bin/rz-ar"
export RANLIB="$bin/rz-ranlib"
export LD="$bin/rz-cc"
export LDSHARED="$bin/rz-shared"
export BUILD_CC="$bin/rz-host-cc"
export BUILD_CXX="$bin/rz-host-cxx"
export CC_FOR_BUILD="$bin/rz-host-cc"
export CXX_FOR_BUILD="$bin/rz-host-cxx"
export AR_FOR_BUILD="$bin/rz-host-ar"
export RANLIB_FOR_BUILD="$bin/rz-host-ranlib"
export HOST_CC="$bin/rz-host-cc"
export HOST_CXX="$bin/rz-host-cxx"
export HOST_AR="$bin/rz-host-ar"
export HOST_RANLIB="$bin/rz-host-ranlib"

rust_key="$(tr '[:lower:].-' '[:upper:]__' <<<"$RZ_RUST_TARGET")"
cc_key="$(tr '[:upper:].-' '[:lower:]__' <<<"$RZ_RUST_TARGET")"
printf -v "CC_${cc_key}" '%s' "$bin/rz-cc"
printf -v "CXX_${cc_key}" '%s' "$bin/rz-cxx"
printf -v "AR_${cc_key}" '%s' "$bin/rz-ar"
export "CC_${cc_key}" "CXX_${cc_key}" "AR_${cc_key}"

case "${RZ_ENABLE_RUST:-false}" in
  1|true)
    if [[ "$RZ_RUST_LINK_STATUS" == blocked ]]; then
      printf 'Rust final linking is blocked for profile %s: %s\n' \
        "$profile" "$RZ_RUST_LINK_BLOCKER" >&2
      return 78 2>/dev/null || exit 78
    fi
    expected_rust="$(jq -r .toolchain "$root/config/rust.json")"
    export RZ_RUST_TOOLCHAIN="${RZ_RUST_TOOLCHAIN:-$expected_rust}"
    if [[ "$RZ_RUST_TOOLCHAIN" != "$expected_rust" ]]; then
      printf 'Expected Rust %s, got requested toolchain %s\n' "$expected_rust" "$RZ_RUST_TOOLCHAIN" >&2
      return 65 2>/dev/null || exit 65
    fi
    export RUSTUP_TOOLCHAIN="$RZ_RUST_TOOLCHAIN"
    if [[ -z "${RZ_RUSTC:-}" ]]; then
      RZ_RUSTC="$(rustup which --toolchain "$RZ_RUST_TOOLCHAIN" rustc)"
    fi
    export RZ_RUSTC
    case "$RZ_RUSTC" in
      /*) ;;
      *) printf 'RZ_RUSTC must be an absolute path: %s\n' "$RZ_RUSTC" >&2; return 64 2>/dev/null || exit 64 ;;
    esac
    if [[ ! -x "$RZ_RUSTC" ]]; then
      printf 'Pinned rustc executable is not executable: %s\n' "$RZ_RUSTC" >&2
      return 66 2>/dev/null || exit 66
    fi
    reported_rust="$("$RZ_RUSTC" --version)"
    if [[ "$reported_rust" != "rustc $expected_rust "* ]]; then
      printf 'Expected rustc %s, got %s\n' "$expected_rust" "$reported_rust" >&2
      return 65 2>/dev/null || exit 65
    fi
    RZ_RUST_HOST_TARGET="$("$RZ_RUSTC" -vV | sed -n 's/^host: //p')"
    export RZ_RUST_HOST_TARGET
    if [[ -z "$RZ_RUST_HOST_TARGET" ]]; then
      printf 'Could not determine the pinned rustc host target\n' >&2
      return 65 2>/dev/null || exit 65
    fi
    export RUSTC="$bin/rz-rustc"
    export CARGO_BUILD_TARGET="$RZ_RUST_TARGET"

    host_rust_key="$(tr '[:lower:].-' '[:upper:]__' <<<"$RZ_RUST_HOST_TARGET")"
    printf -v "CARGO_TARGET_${rust_key}_LINKER" '%s' "$bin/rz-rust-linker"
    export "CARGO_TARGET_${rust_key}_LINKER"
    if [[ "$host_rust_key" != "$rust_key" ]]; then
      printf -v "CARGO_TARGET_${host_rust_key}_LINKER" '%s' "$bin/rz-rust-host-linker"
      export "CARGO_TARGET_${host_rust_key}_LINKER"
    fi

    host_cc_key="$(tr '[:upper:].-' '[:lower:]__' <<<"$RZ_RUST_HOST_TARGET")"
    if [[ "$host_cc_key" != "$cc_key" ]]; then
      printf -v "CC_${host_cc_key}" '%s' "$bin/rz-host-cc"
      printf -v "CXX_${host_cc_key}" '%s' "$bin/rz-host-cxx"
      printf -v "AR_${host_cc_key}" '%s' "$bin/rz-host-ar"
      export "CC_${host_cc_key}" "CXX_${host_cc_key}" "AR_${host_cc_key}"
    fi
    ;;
  0|false|'') ;;
  *)
    printf 'RZ_ENABLE_RUST must be true or false\n' >&2
    return 64 2>/dev/null || exit 64
    ;;
esac

mkdir -p "$RZ_RECEIPT_DIR"
printf 'profile=%s zig_target=%s rust_target=%s rust_link=%s verification=%s\n' \
  "$profile" "$RZ_ZIG_TARGET" "$RZ_RUST_TARGET" "$RZ_RUST_LINK_STATUS" "$RZ_VERIFICATION"
