#!/usr/bin/env python3

from pathlib import Path
import re
import sys
from typing import Any

import yaml


SETUP_RUBY_SHA = "95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
PINNED_USE = re.compile(r"^(?:\./.+|[^@]+@[0-9a-f]{40}(?:[0-9a-f]{24})?)$")
USE_LINE = re.compile(r"^\s*uses:\s*([^\s#]+)", re.MULTILINE)


def require_text(path: Path, text: str, needle: str, errors: list[str]) -> None:
    if needle not in text:
        errors.append(f"{path}: missing required workflow contract: {needle!r}")


def workflow_trigger(document: dict[str, Any]) -> Any:
    # PyYAML 1.1 parses the unquoted Actions key `on` as boolean true.
    return document.get("on", document.get(True))


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    workflows = sorted((root / ".github" / "workflows").glob("*.yml"))
    if not workflows:
        print("no workflow files found", file=sys.stderr)
        return 1

    errors: list[str] = []
    documents: dict[str, dict[str, Any]] = {}
    for path in workflows:
        text = path.read_text(encoding="utf-8")
        document = yaml.safe_load(text)
        if not isinstance(document, dict):
            errors.append(f"{path}: expected a mapping")
            continue
        documents[path.name] = document
        if "jobs" not in document or not isinstance(document["jobs"], dict):
            errors.append(f"{path}: missing jobs mapping")
        for use in USE_LINE.findall(text):
            if not PINNED_USE.fullmatch(use):
                errors.append(f"{path}: action or reusable workflow is not pinned: {use}")

    reusable = root / ".github" / "workflows" / "reusable-zig.yml"
    reusable_text = reusable.read_text(encoding="utf-8")
    for needle in (
        "ruby-version:\n        description: Exact numeric x.y.z Ruby runtime",
        f"uses: ruby/setup-ruby@{SETUP_RUBY_SHA}",
        "ruby-version: ${{ inputs.ruby-version }}",
        "source-ref-name:",
        "RZ_SOURCE_REF: ${{ inputs.source-ref }}",
        "RZ_SOURCE_REF_NAME: ${{ inputs.source-ref-name }}",
        "bash toolchain/scripts/validate-ref-name.sh",
        "bundler-cache: 'false'",
        '"toolchain/$RZ_BUILD_SCRIPT"',
        'adapter="$GITHUB_WORKSPACE/toolchain/$RZ_BUILD_SCRIPT"',
        "must be controller-relative under adapters/",
        "name: Prepare pinned adapter dependencies",
        "python3 toolchain/scripts/prepare-adapter-dependencies.py",
        '--github-env "$GITHUB_ENV"',
        "adapter-dependencies.json",
        "name: Record immutable build provenance",
        "bash toolchain/scripts/write-build-provenance.sh",
        "toolchain/provenance/",
        ".ruby-zig-artifacts/**",
        "source/.ruby-zig-artifacts/**",
        "source/build/ruby-zig/**",
        "include-hidden-files: true",
        "cancel-in-progress: false",
    ):
        require_text(reusable, reusable_text, needle, errors)
    if reusable_text.count(
        "RZ_SOURCE_REF_NAME: ${{ inputs.source-ref-name }}"
    ) != 4:
        errors.append(
            f"{reusable}: validated source ref name must reach provenance and both adapter steps"
        )
    if reusable_text.count(
        "RZ_SOURCE_REF: ${{ inputs.source-ref }}"
    ) != 4:
        errors.append(
            f"{reusable}: exact source SHA must reach checkout validation, provenance, "
            "and both adapter steps"
        )
    if '"source/$RZ_BUILD_SCRIPT"' in reusable_text:
        errors.append(f"{reusable}: adapter must not be loaded from the source fork")

    shard = root / ".github" / "workflows" / "fleet-shard.yml"
    shard_text = shard.read_text(encoding="utf-8")
    for needle in (
        "build-script: ${{ matrix.build_script }}",
        "rust: ${{ matrix.rust }}",
        "ruby-version: ${{ matrix.ruby_version }}",
        "source-ref-name: ${{ matrix.source_ref_name }}",
        "        options:\n          - '1'\n          - '2'\n",
    ):
        require_text(shard, shard_text, needle, errors)
    for old_option in ("          - '3'\n", "          - '7'\n"):
        if old_option in shard_text:
            errors.append(f"{shard}: capacity shard options must stop at 2")

    fleet = root / ".github" / "workflows" / "fleet.yml"
    fleet_text = fleet.read_text(encoding="utf-8")
    require_text(fleet, fleet_text, "      max-parallel: 2", errors)
    require_text(fleet, fleet_text, "        shard: [1, 2]", errors)

    continuous = root / ".github" / "workflows" / "continuous.yml"
    continuous_text = continuous.read_text(encoding="utf-8")
    continuous_document = documents.get("continuous.yml")
    if continuous_document is None:
        errors.append(f"{continuous}: workflow did not parse")
    else:
        trigger = workflow_trigger(continuous_document)
        dispatch = trigger.get("workflow_dispatch") if isinstance(trigger, dict) else None
        dispatch_inputs = dispatch.get("inputs") if isinstance(dispatch, dict) else None
        call = trigger.get("workflow_call") if isinstance(trigger, dict) else None
        call_inputs = call.get("inputs") if isinstance(call, dict) else None
        expected_inputs = {
            "source-repository",
            "source-ref-name",
            "source-sha",
        }
        if not isinstance(dispatch_inputs, dict) or set(dispatch_inputs) != expected_inputs:
            errors.append(
                f"{continuous}: dispatch inputs must be exactly {sorted(expected_inputs)}"
            )
        if not isinstance(call_inputs, dict) or set(call_inputs) != expected_inputs:
            errors.append(
                f"{continuous}: call inputs must be exactly {sorted(expected_inputs)}"
            )
        if continuous_document.get("permissions") != {"contents": "read"}:
            errors.append(f"{continuous}: top-level permissions must be contents: read")
    for needle in (
        "group: zig-continuous-${{ inputs.source-repository }}-${{ inputs.source-ref-name }}-${{ inputs.source-sha }}",
        "cancel-in-progress: false",
        "controller-sha: ${{ steps.controller.outputs.sha }}",
        "RZ_CONTROLLER_SHA: ${{ job.workflow_sha }}",
        "repository: ruby-zig/toolchain",
        "ref: ${{ steps.controller.outputs.sha }}",
        "persist-credentials: false",
        "python3 scripts/render-continuous-matrix.py",
        "bash scripts/verify-continuous-source.sh",
        "needs: plan",
        "matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}",
        "uses: ./.github/workflows/reusable-zig.yml",
        "build-script: ${{ matrix.build_script }}",
        "ruby-version: ${{ matrix.ruby_version }}",
        "rust: ${{ matrix.rust }}",
        "source-ref: ${{ matrix.source_ref }}",
        "toolchain-ref: ${{ needs.plan.outputs.controller-sha }}",
    ):
        require_text(continuous, continuous_text, needle, errors)
    for forbidden in (
        "inputs.profiles",
        "inputs.build-script",
        "inputs.ruby-version",
        "inputs.rust",
        "inputs.allow-no-native",
        "inputs.toolchain-ref",
    ):
        if forbidden in continuous_text:
            errors.append(f"{continuous}: caller may not choose {forbidden}")
    if continuous_text.find("Prove candidate against current public refs") > continuous_text.find("  build:"):
        errors.append(f"{continuous}: public source proof must precede the build job")

    ziguanite = root / ".github" / "workflows" / "ziguanite.yml"
    ziguanite_text = ziguanite.read_text(encoding="utf-8")
    ziguanite_document = documents.get("ziguanite.yml")
    if ziguanite_document is None:
        errors.append(f"{ziguanite}: workflow did not parse")
    else:
        trigger = workflow_trigger(ziguanite_document)
        call = trigger.get("workflow_call") if isinstance(trigger, dict) else None
        if call not in (None, {}):
            errors.append(f"{ziguanite}: workflow_call must expose no inputs")
        if ziguanite_document.get("permissions") != {"contents": "read"}:
            errors.append(f"{ziguanite}: top-level permissions must be contents: read")
    for needle in (
        "uses: ./.github/workflows/continuous.yml",
        "needs: resolve",
        "source-repository: ruby-zig/ziguanite",
        "source-ref-name: ${{ github.ref_name }}",
        "source-sha: ${{ needs.resolve.outputs.source-sha }}",
        "master|ruby_4_0|ruby_3_4|ruby_3_3",
        "https://github.com/ruby/ruby.git",
        "https://github.com/ruby-zig/ziguanite.git",
        "refs/remotes/upstream/tracked refs/remotes/fork/tracked",
    ):
        require_text(ziguanite, ziguanite_text, needle, errors)
    if "inputs." in ziguanite_text:
        errors.append(f"{ziguanite}: caller must not override the locked ziguanite identity")
    if "source-sha: ${{ github.sha }}" in ziguanite_text:
        errors.append(f"{ziguanite}: workflow-only fork commits must not become Ruby source")

    provenance = root / "scripts" / "write-build-provenance.sh"
    provenance_text = provenance.read_text(encoding="utf-8")
    for needle in (
        "source_repository",
        "source_ref_name",
        "source_sha",
        "controller_sha",
        "fleet_lock_sha256",
        "adapter_manifest_sha256",
        "adapter_dependencies",
        "adapter_dependencies_sha256",
        "--verify-record",
        "profile_json",
        "zig_actual",
        "ruby_actual",
        "rust_actual",
        "GITHUB_RUN_ID",
    ):
        require_text(provenance, provenance_text, needle, errors)

    action = root / "action.yml"
    with action.open(encoding="utf-8") as stream:
        document = yaml.safe_load(stream)
    if not isinstance(document, dict):
        errors.append(f"{action}: expected a mapping")
    else:
        runs = document.get("runs")
        if not isinstance(runs, dict) or runs.get("using") != "composite":
            errors.append(f"{action}: expected a composite runs mapping")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(
        f"workflow YAML parsed: {len(workflows)}; all actions pinned; "
        "continuous lock, ancestry, and provenance contracts verified"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
