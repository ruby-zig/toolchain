#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$root/scripts/validate-ref-name.sh"

for ref_name in master ruby_4_0 release/3.3 feature.v1; do
  bash "$validator" "$ref_name"
done

for ref_name in   '.hidden'   'trailing/'   'trailing.'   'name.lock'   'bad@{ref'   'double..dot'   'double//slash'   'dot/./component'   'dot/../component'; do
  if bash "$validator" "$ref_name" >/dev/null 2>&1; then
    printf 'ref validator accepted invalid name: %s\n' "$ref_name" >&2
    exit 1
  fi
done

printf 'tracked ref-name contract passed\n'
