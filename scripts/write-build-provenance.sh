#!/usr/bin/env bash

set -euo pipefail

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'sha256sum or shasum is required\n' >&2
    return 69
  fi
}

: "${GITHUB_EVENT_NAME:?}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_RUN_ATTEMPT:?}"
: "${GITHUB_RUN_ID:?}"
: "${GITHUB_SERVER_URL:?}"
: "${GITHUB_WORKFLOW:?}"
: "${GITHUB_WORKSPACE:?}"
: "${RZ_BUILD_SCRIPT:?}"
: "${RZ_CONTROLLER_SHA:?}"
: "${RZ_PROFILE_ID:?}"
: "${RZ_RUBY_VERSION:?}"
: "${RZ_RUST_ENABLED:?}"
: "${RZ_SOURCE_REF:?}"
: "${RZ_SOURCE_REF_NAME:?}"
: "${RZ_SOURCE_REPOSITORY:?}"
: "${RZ_ZIG:?}"

controller_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$GITHUB_WORKSPACE/source"
controller_head="$(git -C "$controller_root" rev-parse HEAD)"
source_head="$(git -C "$source_root" rev-parse HEAD)"
[[ "$controller_head" == "$RZ_CONTROLLER_SHA" ]] || {
  printf 'Controller checkout differs from declared SHA\n' >&2
  exit 78
}
[[ "$source_head" == "$RZ_SOURCE_REF" ]] || {
  printf 'Source checkout differs from declared SHA\n' >&2
  exit 78
}

adapter_script="$controller_root/$RZ_BUILD_SCRIPT"
adapter_manifest="$(dirname "$adapter_script")/adapter.json"
[[ -f "$adapter_script" && -f "$adapter_manifest" ]] || {
  printf 'Adapter script or manifest is missing for %s\n' "$RZ_BUILD_SCRIPT" >&2
  exit 66
}
adapter_id="$(jq -er '.adapter_id | strings' "$adapter_manifest")"
adapter_schema="$(jq -er '.schema | numbers' "$adapter_manifest")"
adapter_manifest_sha256="$(sha256_file "$adapter_manifest")"
adapter_script_sha256="$(sha256_file "$adapter_script")"
fleet_lock_sha256="$(sha256_file "$controller_root/config/fleet-lock.json")"
profile_json="$(jq -ce --arg id "$RZ_PROFILE_ID" '.profiles[] | select(.id == $id)' "$controller_root/config/targets.json")"
zig_config="$(jq -ce . "$controller_root/config/zig.json")"
rust_config="$(jq -ce . "$controller_root/config/rust.json")"
zig_actual="$("$RZ_ZIG" version)"
ruby_actual="$(ruby --version)"
rust_actual=''
if [[ "$RZ_RUST_ENABLED" == true ]]; then
  : "${RZ_RUST_TOOLCHAIN:?}"
  rust_actual="$(rustc +"$RZ_RUST_TOOLCHAIN" --version --verbose)"
fi

mkdir -p "$controller_root/provenance"
jq -n \
  --arg adapter_id "$adapter_id" \
  --argjson adapter_schema "$adapter_schema" \
  --arg adapter_manifest_sha256 "$adapter_manifest_sha256" \
  --arg adapter_script "$RZ_BUILD_SCRIPT" \
  --arg adapter_script_sha256 "$adapter_script_sha256" \
  --arg caller_repository "$GITHUB_REPOSITORY" \
  --arg controller_sha "$RZ_CONTROLLER_SHA" \
  --arg event_name "$GITHUB_EVENT_NAME" \
  --arg fleet_lock_sha256 "$fleet_lock_sha256" \
  --argjson profile "$profile_json" \
  --arg ruby_actual "$ruby_actual" \
  --arg ruby_declared "$RZ_RUBY_VERSION" \
  --arg run_attempt "$GITHUB_RUN_ATTEMPT" \
  --arg run_id "$GITHUB_RUN_ID" \
  --arg rust_actual "$rust_actual" \
  --arg rust_enabled "$RZ_RUST_ENABLED" \
  --argjson rust_config "$rust_config" \
  --arg server_url "$GITHUB_SERVER_URL" \
  --arg source_ref_name "$RZ_SOURCE_REF_NAME" \
  --arg source_repository "$RZ_SOURCE_REPOSITORY" \
  --arg source_sha "$RZ_SOURCE_REF" \
  --arg workflow "$GITHUB_WORKFLOW" \
  --arg zig_actual "$zig_actual" \
  --argjson zig_config "$zig_config" \
  '{
    schema: 1,
    source: {
      repository: $source_repository,
      branch: $source_ref_name,
      sha: $source_sha
    },
    controller: {
      repository: "ruby-zig/toolchain",
      sha: $controller_sha,
      fleet_lock_sha256: $fleet_lock_sha256
    },
    adapter: {
      id: $adapter_id,
      schema: $adapter_schema,
      manifest_sha256: $adapter_manifest_sha256,
      build_script: $adapter_script,
      build_script_sha256: $adapter_script_sha256
    },
    profile: $profile,
    tools: {
      zig: {actual_version: $zig_actual, config: $zig_config},
      ruby: {declared_version: $ruby_declared, actual_version: $ruby_actual},
      rust: (if $rust_enabled == "true" then
        {enabled: true, actual_version: $rust_actual, config: $rust_config}
      else
        {enabled: false, actual_version: null, config: $rust_config}
      end)
    },
    dispatch: {
      caller_repository: $caller_repository,
      event: $event_name,
      workflow: $workflow,
      run_id: $run_id,
      run_attempt: $run_attempt,
      url: ($server_url + "/" + $caller_repository + "/actions/runs/" + $run_id)
    }
  }' > "$controller_root/provenance/provenance.json"
jq -e . "$controller_root/provenance/provenance.json" >/dev/null
