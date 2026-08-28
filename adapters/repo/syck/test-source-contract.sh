#!/usr/bin/env bash

set -euo pipefail

readonly candidate_source_ref='1111111111111111111111111111111111111111'
readonly mismatched_source_ref='2111111111111111111111111111111111111111'

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

source_root="$work/source"
fake_bin="$work/bin"
mkdir -p "$source_root" "$fake_bin"

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == -C && "${2:-}" == "${FAKE_GIT_ROOT:?}" ]] || exit 64
shift 2
case "$*" in
  'rev-parse --is-inside-work-tree') printf 'true\n' ;;
  'rev-parse --show-toplevel') printf '%s\n' "$FAKE_GIT_TOPLEVEL" ;;
  'rev-parse --verify HEAD') printf '%s\n' "$FAKE_GIT_SHA" ;;
  'status --porcelain=v1 --untracked-files=all') printf '%s' "${FAKE_GIT_STATUS:-}" ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$fake_bin/git"

run_contract() {
  PATH="$fake_bin:$PATH" \
    FAKE_GIT_ROOT="$source_root" \
    FAKE_GIT_TOPLEVEL="${FAKE_GIT_TOPLEVEL:-$source_root}" \
    FAKE_GIT_SHA="${FAKE_GIT_SHA:-$candidate_source_ref}" \
    FAKE_GIT_STATUS="${FAKE_GIT_STATUS:-}" \
    RZ_SOURCE_REF="${RZ_SOURCE_REF:-$candidate_source_ref}" \
    RZ_SOURCE_REF_NAME="${RZ_SOURCE_REF_NAME:-master}" \
    bash "$root/source-contract.sh" "$source_root"
}

run_contract >/dev/null

if RZ_SOURCE_REF="$mismatched_source_ref" run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a mismatched SHA\n' >&2
  exit 1
fi
if RZ_SOURCE_REF=master run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a symbolic ref\n' >&2
  exit 1
fi
if RZ_SOURCE_REF_NAME=main run_contract >/dev/null 2>&1; then
  printf 'source contract accepted an untracked branch\n' >&2
  exit 1
fi
if FAKE_GIT_SHA="$mismatched_source_ref" run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a mismatched checkout\n' >&2
  exit 1
fi
if FAKE_GIT_STATUS='?? untracked.txt' run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a dirty worktree\n' >&2
  exit 1
fi
if FAKE_GIT_TOPLEVEL="$work" run_contract >/dev/null 2>&1; then
  printf 'source contract accepted a source subdirectory\n' >&2
  exit 1
fi

printf 'Syck source contract tests passed\n'
