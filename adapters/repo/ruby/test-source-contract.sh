#!/usr/bin/env bash

set -euo pipefail

adapter_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
jit_options=()
# shellcheck source=adapters/repo/ruby/source-contract.sh
source "$adapter_root/source-contract.sh"

sha=0123456789abcdef0123456789abcdef01234567

expect_failure() {
  local expected_status=$1
  shift
  set +e
  ( "$@" ) >/dev/null 2>&1
  local actual_status=$?
  set -e
  if [[ $actual_status -ne $expected_status ]]; then
    printf 'expected status %s, got %s: %s\n' \
      "$expected_status" "$actual_status" "$*" >&2
    exit 1
  fi
}

for ref in master ruby_4_0; do
  RZ_SOURCE_REF_NAME=$ref RZ_SOURCE_REF=$sha \
    rz_ruby_source_contract "$sha"
  [[ ${jit_options[*]} == '--enable-yjit --enable-zjit' ]]
done

for ref in ruby_3_4 ruby_3_3 ruby_3_2; do
  RZ_SOURCE_REF_NAME=$ref RZ_SOURCE_REF=$sha \
    rz_ruby_source_contract "$sha"
  [[ ${jit_options[*]} == '--enable-yjit' ]]
done

expect_failure 65 env \
  RZ_SOURCE_REF_NAME=master \
  RZ_SOURCE_REF=ffffffffffffffffffffffffffffffffffffffff \
  bash -c "source \"\$1\"; rz_ruby_source_contract \"\$2\"" \
  contract-test "$adapter_root/source-contract.sh" "$sha"

expect_failure 78 env \
  RZ_SOURCE_REF_NAME=ruby_3_1 \
  RZ_SOURCE_REF=$sha \
  bash -c "source \"\$1\"; rz_ruby_source_contract \"\$2\"" \
  contract-test "$adapter_root/source-contract.sh" "$sha"

expect_failure 64 env -u RZ_SOURCE_REF_NAME \
  RZ_SOURCE_REF=$sha \
  bash -c "source \"\$1\"; rz_ruby_source_contract \"\$2\"" \
  contract-test "$adapter_root/source-contract.sh" "$sha"

expect_failure 64 env -u RZ_SOURCE_REF \
  RZ_SOURCE_REF_NAME=master \
  bash -c "source \"\$1\"; rz_ruby_source_contract \"\$2\"" \
  contract-test "$adapter_root/source-contract.sh" "$sha"

printf 'CRuby source contract tests passed\n'
