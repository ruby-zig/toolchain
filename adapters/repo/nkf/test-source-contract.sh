#!/usr/bin/env bash

set -euo pipefail

readonly candidate_source_ref='1111111111111111111111111111111111111111'
readonly mismatched_source_ref='2111111111111111111111111111111111111111'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/source"

cat >"$work/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == -C && $# -ge 3 ]] || exit 2
shift 2
case "$*" in
  'rev-parse --is-inside-work-tree') printf 'true\n' ;;
  'rev-parse HEAD') printf '%s\n' "${FAKE_GIT_SHA:?}" ;;
  'status --porcelain=v1 --untracked-files=all') printf '%s' "${FAKE_GIT_STATUS:-}" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$work/bin/git"

run_contract() {
  PATH="$work/bin:$PATH" \
  FAKE_GIT_SHA="${FAKE_GIT_SHA:-$candidate_source_ref}" \
  FAKE_GIT_STATUS="${FAKE_GIT_STATUS:-}" \
  RZ_SOURCE_REF="${RZ_SOURCE_REF:-$candidate_source_ref}" \
  RZ_SOURCE_REF_NAME="${RZ_SOURCE_REF_NAME:-master}" \
    bash "$root/source-contract.sh" "$work/source"
}

run_contract >/dev/null

if RZ_SOURCE_REF="$mismatched_source_ref" \
  run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a mismatched SHA\n' >&2
  exit 1
fi
if RZ_SOURCE_REF_NAME=main run_contract >/dev/null 2>&1; then
  printf 'source contract accepted an untracked branch\n' >&2
  exit 1
fi
if RZ_SOURCE_REF=master run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a symbolic ref\n' >&2
  exit 1
fi
if FAKE_GIT_SHA="$mismatched_source_ref" \
  run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a checkout at a different SHA\n' >&2
  exit 1
fi
if FAKE_GIT_STATUS='?? generated.txt' run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a dirty worktree\n' >&2
  exit 1
fi

printf 'nkf source contract tests passed\n'
