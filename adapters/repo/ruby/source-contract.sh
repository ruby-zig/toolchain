#!/usr/bin/env bash

rz_ruby_source_contract() {
  if [[ $# -ne 1 ]]; then
    printf 'usage: rz_ruby_source_contract SOURCE_SHA\n' >&2
    return 64
  fi
  if [[ -z "${RZ_SOURCE_REF_NAME:-}" ]]; then
    printf 'the manifest must bind the source ref name\n' >&2
    return 64
  fi
  if [[ -z "${RZ_SOURCE_REF:-}" ]]; then
    printf 'the manifest must bind the exact source SHA\n' >&2
    return 64
  fi

  local actual_sha=$1
  if [[ ! "$actual_sha" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'source SHA is not a lowercase full Git object name: %s\n' "$actual_sha" >&2
    return 65
  fi
  if [[ "$RZ_SOURCE_REF" != "$actual_sha" ]]; then
    printf 'expected source SHA %s, got %s\n' \
      "$RZ_SOURCE_REF" "$actual_sha" >&2
    return 65
  fi

  source_branch=$RZ_SOURCE_REF_NAME
  case "$source_branch" in
    master|ruby_4_0)
      jit_options=(--enable-yjit --enable-zjit)
      ;;
    ruby_3_4|ruby_3_3)
      jit_options=(--enable-yjit)
      ;;
    *)
      printf 'CRuby source ref is not maintained by this adapter: %s\n' \
        "$source_branch" >&2
      return 78
      ;;
  esac
}
