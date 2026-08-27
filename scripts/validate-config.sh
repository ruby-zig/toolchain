#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

jq -e '.version and (.archives | length == 6)' config/zig.json >/dev/null
jq -e '.toolchain == "1.98.0" and .profile == "minimal"' config/rust.json >/dev/null
jq -e '.profiles | length >= 9' config/targets.json >/dev/null
jq -e '[.profiles[].runner | select(. != "ubuntu-24.04" and . != "ubuntu-24.04-arm" and . != "macos-15" and . != "macos-15-intel")] | length == 0' config/targets.json >/dev/null
jq -e '[.profiles[].id] | length == (unique | length)' config/targets.json >/dev/null
jq -e '[.profiles[].verification | select(. != "build-only")] | length == 0' config/targets.json >/dev/null
jq -e '[.profiles[].rust_link_status | select(. != "smoke-verified" and . != "unverified" and . != "blocked")] | length == 0' config/targets.json >/dev/null
jq -e '[.profiles[] | select(.rust_link_status == "blocked" and ((.rust_link_blocker // "") | length == 0))] | length == 0' config/targets.json >/dev/null
jq -e '[.profiles[] | select((.id == "aarch64-linux-gnu.2.17" or .id == "aarch64-linux-musl") and .rust_link_status != "blocked")] | length == 0' config/targets.json >/dev/null
jq -e '.count == (.repositories | length) and .count == 190' config/repositories.json >/dev/null
jq -e '[.repositories[] | select(.native_scope == "direct-native")] | length == 38' config/repositories.json >/dev/null
jq -e '[.repositories[] | select(.native_scope == "native-test")] | length == 1' config/repositories.json >/dev/null
jq -e '[.repositories[] | select(.native_scope == "fixture-template-example")] | length == 3' config/repositories.json >/dev/null
jq -e '[.repositories[] | select(.native_scope == "none-detected")] | length == 148' config/repositories.json >/dev/null
jq -e '.summary.repositories_with_committed_native_source == 42' config/native-scope.json >/dev/null
python3 scripts/validate-build-manifest.py --root "$root"
python3 scripts/render-fleet-matrix.py --root "$root" --check
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/test_validate_ref_name.sh

printf 'configuration invariants passed\n'
