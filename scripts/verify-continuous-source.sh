#!/usr/bin/env bash

set -euo pipefail

if (( $# != 5 )); then
  printf 'usage: %s UPSTREAM_REPOSITORY FORK_REPOSITORY REF_NAME BASELINE_SHA CANDIDATE_SHA\n' "$0" >&2
  exit 64
fi

upstream_repository="$1"
fork_repository="$2"
ref_name="$3"
baseline_sha="$4"
candidate_sha="$5"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

repository_pattern='^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$'
sha_pattern='^[0-9a-f]{40}$'

[[ "$upstream_repository" =~ $repository_pattern ]] || {
  printf 'Invalid upstream repository: %s\n' "$upstream_repository" >&2
  exit 64
}
[[ "$fork_repository" =~ ^ruby-zig/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  printf 'Invalid ruby-zig fork repository: %s\n' "$fork_repository" >&2
  exit 64
}
bash "$root/scripts/validate-ref-name.sh" "$ref_name"
[[ "$baseline_sha" =~ $sha_pattern ]] || {
  printf 'Baseline must be a lowercase 40-character commit SHA\n' >&2
  exit 64
}
[[ "$candidate_sha" =~ $sha_pattern ]] || {
  printf 'Candidate must be a lowercase 40-character commit SHA\n' >&2
  exit 64
}

protocol_policy=never
filter_args=(--filter=blob:none)
remote_url() {
  local repository="$1"
  if [[ "${RZ_TEST_ALLOW_LOCAL_GIT_ROOT:-}" == 1 ]]; then
    [[ -n "${RZ_TEST_GIT_ROOT:-}" ]] || {
      printf 'RZ_TEST_GIT_ROOT is required for the test-only local transport\n' >&2
      exit 64
    }
    printf '%s/%s.git\n' "$RZ_TEST_GIT_ROOT" "$repository"
    return
  fi
  [[ -z "${RZ_TEST_GIT_ROOT:-}" ]] || {
    printf 'Local Git root requires RZ_TEST_ALLOW_LOCAL_GIT_ROOT=1\n' >&2
    exit 64
  }
  printf 'https://github.com/%s.git\n' "$repository"
}

if [[ "${RZ_TEST_ALLOW_LOCAL_GIT_ROOT:-}" == 1 ]]; then
  protocol_policy=always
  filter_args=()
elif [[ -n "${RZ_TEST_ALLOW_LOCAL_GIT_ROOT:-}" ]]; then
  printf 'RZ_TEST_ALLOW_LOCAL_GIT_ROOT must be exactly 1 when set\n' >&2
  exit 64
fi

verify_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ruby-zig-source-proof.XXXXXX")"
trap 'rm -rf -- "$verify_root"' EXIT
git_dir="$verify_root/objects.git"

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0

git init --bare --quiet "$git_dir"
upstream_url="$(remote_url "$upstream_repository")"
fork_url="$(remote_url "$fork_repository")"

git -C "$git_dir" \
  -c credential.helper= \
  -c core.hooksPath=/dev/null \
  -c "protocol.file.allow=$protocol_policy" \
  fetch --quiet --force --no-tags "${filter_args[@]}" \
  "$upstream_url" \
  "+refs/heads/$ref_name:refs/remotes/upstream/tracked"
git -C "$git_dir" \
  -c credential.helper= \
  -c core.hooksPath=/dev/null \
  -c "protocol.file.allow=$protocol_policy" \
  fetch --quiet --force --no-tags "${filter_args[@]}" \
  "$fork_url" \
  "+refs/heads/$ref_name:refs/remotes/fork/tracked"

git -C "$git_dir" cat-file -e "$baseline_sha^{commit}" 2>/dev/null || {
  printf 'Certified baseline is not present in the fetched public histories: %s\n' "$baseline_sha" >&2
  exit 78
}
git -C "$git_dir" cat-file -e "$candidate_sha^{commit}" 2>/dev/null || {
  printf 'Candidate is not present in the fetched public histories: %s\n' "$candidate_sha" >&2
  exit 78
}
git -C "$git_dir" merge-base --is-ancestor "$baseline_sha" "$candidate_sha" || {
  printf 'Candidate does not descend from certified baseline: %s !<= %s\n' \
    "$baseline_sha" "$candidate_sha" >&2
  exit 78
}
git -C "$git_dir" merge-base --is-ancestor \
  "$candidate_sha" refs/remotes/upstream/tracked || {
  printf 'Candidate is not reachable from current upstream %s: %s\n' \
    "$ref_name" "$candidate_sha" >&2
  exit 78
}
git -C "$git_dir" merge-base --is-ancestor \
  "$candidate_sha" refs/remotes/fork/tracked || {
  printf 'Candidate is not reachable from current fork %s: %s\n' \
    "$ref_name" "$candidate_sha" >&2
  exit 78
}

upstream_tip="$(git -C "$git_dir" rev-parse refs/remotes/upstream/tracked)"
fork_tip="$(git -C "$git_dir" rev-parse refs/remotes/fork/tracked)"
printf 'Accepted %s@%s: baseline=%s candidate=%s upstream-tip=%s fork-tip=%s\n' \
  "$fork_repository" "$ref_name" "$baseline_sha" "$candidate_sha" \
  "$upstream_tip" "$fork_tip"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Public source graph proof\n\n'
    printf '| Ref | Commit |\n'
    printf '| --- | --- |\n'
    printf "| Certified baseline | \`%s\` |\n" "$baseline_sha"
    printf "| Candidate | \`%s\` |\n" "$candidate_sha"
    printf "| Current upstream \`%s\` | \`%s\` |\n" "$ref_name" "$upstream_tip"
    printf "| Current fork \`%s\` | \`%s\` |\n" "$ref_name" "$fork_tip"
    printf '\nThe candidate descends from the certified baseline and is reachable from both current public tracked refs.\n\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
