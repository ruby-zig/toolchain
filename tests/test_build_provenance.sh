#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/ruby-zig-provenance-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
workspace="$fixture/workspace"
controller="$workspace/toolchain"
source_root="$workspace/source"

mkdir -p \
  "$controller/scripts" \
  "$controller/config" \
  "$controller/adapters/repo/bigdecimal" \
  "$source_root" \
  "$fixture/bin"
cp "$root/scripts/write-build-provenance.sh" "$controller/scripts/"
cp "$root/config/fleet-lock.json" "$controller/config/"
cp "$root/config/targets.json" "$controller/config/"
cp "$root/config/zig.json" "$controller/config/"
cp "$root/config/rust.json" "$controller/config/"
cp "$root/adapters/repo/bigdecimal/adapter.json" \
  "$controller/adapters/repo/bigdecimal/"
cp "$root/adapters/repo/bigdecimal/build.sh" \
  "$controller/adapters/repo/bigdecimal/"

git init --quiet "$controller"
git -C "$controller" config user.name "Ruby Zig Test"
git -C "$controller" config user.email "ruby-zig-test@example.invalid"
git -C "$controller" add .
git -C "$controller" commit --quiet -m controller
controller_sha="$(git -C "$controller" rev-parse HEAD)"

git init --quiet "$source_root"
git -C "$source_root" config user.name "Ruby Zig Test"
git -C "$source_root" config user.email "ruby-zig-test@example.invalid"
printf 'source\n' > "$source_root/README"
git -C "$source_root" add README
git -C "$source_root" commit --quiet -m source
source_sha="$(git -C "$source_root" rev-parse HEAD)"

printf '#!/usr/bin/env bash\nprintf "0.16.0-test\\n"\n' > "$fixture/bin/zig"
printf '#!/usr/bin/env bash\nprintf "ruby 3.2.3-test\\n"\n' > "$fixture/bin/ruby"
chmod +x "$fixture/bin/zig" "$fixture/bin/ruby"

PATH="$fixture/bin:$PATH" \
GITHUB_EVENT_NAME=workflow_dispatch \
GITHUB_REPOSITORY=ruby-zig/toolchain \
GITHUB_RUN_ATTEMPT=2 \
GITHUB_RUN_ID=123456 \
GITHUB_SERVER_URL=https://github.com \
GITHUB_WORKFLOW='continuous Zig build' \
GITHUB_WORKSPACE="$workspace" \
RZ_BUILD_SCRIPT=adapters/repo/bigdecimal/build.sh \
RZ_CONTROLLER_SHA="$controller_sha" \
RZ_PROFILE_ID=x86_64-linux-gnu.2.17 \
RZ_RUBY_VERSION=3.2.3 \
RZ_RUST_ENABLED=false \
RZ_SOURCE_REF="$source_sha" \
RZ_SOURCE_REF_NAME=master \
RZ_SOURCE_REPOSITORY=ruby-zig/bigdecimal \
RZ_ZIG="$fixture/bin/zig" \
  bash "$controller/scripts/write-build-provenance.sh"

jq -e \
  --arg controller_sha "$controller_sha" \
  --arg source_sha "$source_sha" \
  '.schema == 1
   and .source.repository == "ruby-zig/bigdecimal"
   and .source.branch == "master"
   and .source.sha == $source_sha
   and .controller.repository == "ruby-zig/toolchain"
   and .controller.sha == $controller_sha
   and (.controller.fleet_lock_sha256 | test("^[0-9a-f]{64}$"))
   and .adapter.id == "repo/bigdecimal"
   and (.adapter.manifest_sha256 | test("^[0-9a-f]{64}$"))
   and (.adapter.build_script_sha256 | test("^[0-9a-f]{64}$"))
   and .adapter.dependencies.schema == 1
   and .adapter.dependencies.build_script == "adapters/repo/bigdecimal/build.sh"
   and .adapter.dependencies.dependencies == []
   and .adapter.dependencies_record_sha256 == null
   and .profile.id == "x86_64-linux-gnu.2.17"
   and .tools.zig.actual_version == "0.16.0-test"
   and .tools.ruby.declared_version == "3.2.3"
   and .tools.ruby.actual_version == "ruby 3.2.3-test"
   and .tools.rust.enabled == false
   and .dispatch.run_id == "123456"
   and .dispatch.run_attempt == "2"
   and .dispatch.url == "https://github.com/ruby-zig/toolchain/actions/runs/123456"' \
  "$controller/provenance/provenance.json" >/dev/null

printf 'build provenance contract passed\n'
