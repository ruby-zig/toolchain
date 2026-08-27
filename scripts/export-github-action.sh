#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: export-github-action.sh PROFILE\n' >&2
  exit 64
fi

: "${RZ_ACTION_ROOT:?RZ_ACTION_ROOT must name the checked-out action directory}"
: "${GITHUB_ENV:?GITHUB_ENV must name the GitHub Actions environment file}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must name the GitHub Actions output file}"
: "${GITHUB_PATH:?GITHUB_PATH must name the GitHub Actions path file}"
: "${RZ_ZIG:?RZ_ZIG must name the pinned Zig executable}"

case "$RZ_ACTION_ROOT" in
  /*) ;;
  *)
    printf 'RZ_ACTION_ROOT must be an absolute path: %s\n' "$RZ_ACTION_ROOT" >&2
    exit 64
    ;;
esac

profile="$1"
# shellcheck source=export-toolchain.sh
source "$RZ_ACTION_ROOT/scripts/export-toolchain.sh" "$profile"

append_value() {
  local destination="$1"
  local name="$2"
  local value="$3"

  if [[ "$name" == *$'\n'* || "$name" == *$'\r'* ||
        "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf 'refusing to export a multiline value for %s\n' "$name" >&2
    exit 65
  fi
  printf '%s=%s\n' "$name" "$value" >>"$destination"
}

export_name() {
  local name="$1"
  if [[ -z "${!name+x}" ]]; then
    printf 'expected toolchain variable is unset: %s\n' "$name" >&2
    exit 65
  fi
  append_value "$GITHUB_ENV" "$name" "${!name}"
}

fixed_names=(
  RZ_ZIG RZ_ENABLE_RUST RZ_ZIG_TARGET RZ_RUST_TARGET
  RZ_RUST_LINK_STATUS RZ_RUST_LINK_BLOCKER RZ_AUTOCONF_HOST
  RZ_VERIFICATION RZ_RECEIPT_DIR RZ_TOOLCHAIN_BIN
  CC CXX OBJC OBJCXX AR RANLIB LD LDSHARED
  BUILD_CC BUILD_CXX CC_FOR_BUILD CXX_FOR_BUILD
  AR_FOR_BUILD RANLIB_FOR_BUILD
  HOST_CC HOST_CXX HOST_AR HOST_RANLIB
)
for name in "${fixed_names[@]}"; do
  export_name "$name"
done

cc_key="$(tr '[:upper:].-' '[:lower:]__' <<<"$RZ_RUST_TARGET")"
for prefix in CC CXX AR; do
  export_name "${prefix}_${cc_key}"
done

case "$RZ_ENABLE_RUST" in
  true|1)
    rust_names=(
      RZ_RUST_TOOLCHAIN RUSTUP_TOOLCHAIN RZ_RUSTC RZ_RUST_HOST_TARGET
      RUSTC CARGO_BUILD_TARGET
    )
    for name in "${rust_names[@]}"; do
      export_name "$name"
    done

    rust_key="$(tr '[:lower:].-' '[:upper:]__' <<<"$RZ_RUST_TARGET")"
    export_name "CARGO_TARGET_${rust_key}_LINKER"
    host_rust_key="$(tr '[:lower:].-' '[:upper:]__' <<<"$RZ_RUST_HOST_TARGET")"
    if [[ "$host_rust_key" != "$rust_key" ]]; then
      export_name "CARGO_TARGET_${host_rust_key}_LINKER"
    fi

    host_cc_key="$(tr '[:upper:].-' '[:lower:]__' <<<"$RZ_RUST_HOST_TARGET")"
    if [[ "$host_cc_key" != "$cc_key" ]]; then
      for prefix in CC CXX AR; do
        export_name "${prefix}_${host_cc_key}"
      done
    fi
    ;;
  false|0|'') ;;
  *)
    printf 'RZ_ENABLE_RUST must be true or false\n' >&2
    exit 64
    ;;
esac

printf '%s\n' "$RZ_TOOLCHAIN_BIN" >>"$GITHUB_PATH"

append_value "$GITHUB_OUTPUT" zig-target "$RZ_ZIG_TARGET"
append_value "$GITHUB_OUTPUT" rust-enabled "$RZ_ENABLE_RUST"
append_value "$GITHUB_OUTPUT" rust-target "$RZ_RUST_TARGET"
append_value "$GITHUB_OUTPUT" rust-link-status "$RZ_RUST_LINK_STATUS"
append_value "$GITHUB_OUTPUT" autoconf-host "$RZ_AUTOCONF_HOST"
append_value "$GITHUB_OUTPUT" verification "$RZ_VERIFICATION"
append_value "$GITHUB_OUTPUT" toolchain-bin "$RZ_TOOLCHAIN_BIN"
