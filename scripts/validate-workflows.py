#!/usr/bin/env python3

from pathlib import Path
import sys

import yaml


SETUP_RUBY_SHA = "95ef2b042f9d7a56d8268cba8559e2842e2ad01b"


def require_text(path: Path, text: str, needle: str, errors: list[str]) -> None:
    if needle not in text:
        errors.append(f"{path}: missing required workflow contract: {needle!r}")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    workflows = sorted((root / ".github" / "workflows").glob("*.yml"))
    if not workflows:
        print("no workflow files found", file=sys.stderr)
        return 1

    errors: list[str] = []
    for path in workflows:
        with path.open(encoding="utf-8") as stream:
            document = yaml.safe_load(stream)
        if not isinstance(document, dict):
            errors.append(f"{path}: expected a mapping")
        elif "jobs" not in document or not isinstance(document["jobs"], dict):
            errors.append(f"{path}: missing jobs mapping")

    reusable = root / ".github" / "workflows" / "reusable-zig.yml"
    reusable_text = reusable.read_text(encoding="utf-8")
    for needle in (
        "ruby-version:\n        description: Exact numeric x.y.z Ruby runtime",
        f"uses: ruby/setup-ruby@{SETUP_RUBY_SHA}",
        "ruby-version: ${{ inputs.ruby-version }}",
        "source-ref-name:",
        "RZ_SOURCE_REF_NAME: ${{ inputs.source-ref-name }}",
        "bash toolchain/scripts/validate-ref-name.sh",
        "bundler-cache: 'false'",
        '"toolchain/$RZ_BUILD_SCRIPT"',
        'adapter="$GITHUB_WORKSPACE/toolchain/$RZ_BUILD_SCRIPT"',
        "must be controller-relative under adapters/",
    ):
        require_text(reusable, reusable_text, needle, errors)
    if reusable_text.count(
        "RZ_SOURCE_REF_NAME: ${{ inputs.source-ref-name }}"
    ) != 3:
        errors.append(
            f"{reusable}: validated source ref name must reach both adapter steps"
        )
    if '"source/$RZ_BUILD_SCRIPT"' in reusable_text:
        errors.append(f"{reusable}: adapter must not be loaded from the source fork")

    shard = root / ".github" / "workflows" / "fleet-shard.yml"
    shard_text = shard.read_text(encoding="utf-8")
    require_text(
        shard,
        shard_text,
        "ruby-version: ${{ matrix.ruby_version }}",
        errors,
    )
    require_text(
        shard,
        shard_text,
        "source-ref-name: ${{ matrix.source_ref_name }}",
        errors,
    )
    required_options = "        options:\n          - '1'\n          - '2'\n"
    require_text(shard, shard_text, required_options, errors)
    for old_option in ("          - '3'\n", "          - '7'\n"):
        if old_option in shard_text:
            errors.append(f"{shard}: capacity shard options must stop at 2")

    fleet = root / ".github" / "workflows" / "fleet.yml"
    fleet_text = fleet.read_text(encoding="utf-8")
    require_text(fleet, fleet_text, "      max-parallel: 2", errors)
    require_text(fleet, fleet_text, "        shard: [1, 2]", errors)

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
        f"workflow YAML parsed: {len(workflows)}; composite action parsed; "
        "two-shard Ruby runtime contract verified"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
