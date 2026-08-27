#!/usr/bin/env python3
"""Validate the fleet build manifest against its two source inventories."""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path
from typing import Any

ENTRY_KEYS = {
    "name",
    "upstream",
    "url",
    "default_branch",
    "archived",
    "upstream_is_fork",
    "classification",
    "adapter_id",
    "adapter_status",
    "profile_policy",
    "shard",
}

CLASSIFICATIONS = {
    "direct-native",
    "native-test",
    "fixture-template-or-example",
    "no-committed-native",
}

PROFILE_POLICIES = {
    "zig-build-only": {
        "profiles": "all-declared",
        "native_compilation": "required",
        "claim": "build-only",
        "scope": "repository-product",
    },
    "zig-test-scope-only": {
        "profiles": "all-declared",
        "native_compilation": "required",
        "claim": "build-only",
        "scope": "committed-native-tests-only",
    },
    "zig-fixture-scope-only": {
        "profiles": "all-declared",
        "native_compilation": "required",
        "claim": "build-only",
        "scope": "committed-fixtures-templates-examples-only",
    },
    "not-applicable": {
        "profiles": "none",
        "native_compilation": "not-applicable",
        "claim": "none",
        "scope": "no-committed-native-source",
    },
}

GITHUB_MATRIX_JOB_LIMIT = 256


class DuplicateKeyError(ValueError):
    pass


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=unique_object)
    except (OSError, json.JSONDecodeError, DuplicateKeyError) as exc:
        raise SystemExit(f"{path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: top-level JSON value must be an object")
    return value


def expected_route(
    name: str,
    direct_native: set[str],
    native_test: set[str],
    fixture_scope: set[str],
) -> tuple[str, str | None, str, str]:
    if name in direct_native:
        return "direct-native", f"repo/{name}", "planned", "zig-build-only"
    if name in native_test:
        return "native-test", f"test/{name}", "planned", "zig-test-scope-only"
    if name in fixture_scope:
        return (
            "fixture-template-or-example",
            f"fixture/{name}",
            "planned",
            "zig-fixture-scope-only",
        )
    return "no-committed-native", None, "not-applicable", "not-applicable"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the parent of scripts/)",
    )
    args = parser.parse_args()
    root = args.root.resolve()

    inventory = read_json(root / "config" / "repositories.json")
    native_scope = read_json(root / "config" / "native-scope.json")
    manifest = read_json(root / "config" / "builds.json")

    errors: list[str] = []

    repositories = inventory.get("repositories")
    builds = manifest.get("builds")
    if not isinstance(repositories, list):
        raise SystemExit("config/repositories.json: repositories must be an array")
    if not isinstance(builds, list):
        raise SystemExit("config/builds.json: builds must be an array")

    scope_keys = (
        "direct_native",
        "native_test_scope",
        "fixture_template_or_example_scope",
    )
    scopes: dict[str, set[str]] = {}
    for key in scope_keys:
        values = native_scope.get(key)
        if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
            errors.append(f"native-scope {key} must be an array of repository names")
            scopes[key] = set()
            continue
        if len(values) != len(set(values)):
            errors.append(f"native-scope {key} contains duplicate names")
        scopes[key] = set(values)

    direct_native = scopes["direct_native"]
    native_test = scopes["native_test_scope"]
    fixture_scope = scopes["fixture_template_or_example_scope"]
    if direct_native & native_test or direct_native & fixture_scope or native_test & fixture_scope:
        errors.append("native-scope classifications overlap")

    inventory_names = [
        repo.get("name") if isinstance(repo, dict) else None for repo in repositories
    ]
    if not all(isinstance(name, str) and name for name in inventory_names):
        errors.append("inventory entries must have non-empty string names")
    inventory_name_set = {name for name in inventory_names if isinstance(name, str)}
    scoped_names = direct_native | native_test | fixture_scope
    for name in sorted(scoped_names - inventory_name_set):
        errors.append(f"native-scope names missing from inventory: {name}")

    declared_count = inventory.get("count")
    manifest_count = manifest.get("count")
    if declared_count != len(repositories):
        errors.append(
            f"inventory count is {declared_count!r}, but contains {len(repositories)} repositories"
        )
    if manifest_count != len(builds):
        errors.append(
            f"manifest count is {manifest_count!r}, but contains {len(builds)} builds"
        )
    if len(builds) != len(repositories):
        errors.append(
            f"manifest has {len(builds)} builds for {len(repositories)} repositories"
        )

    build_names = [
        build.get("name") if isinstance(build, dict) else None for build in builds
    ]
    duplicates = sorted(
        name
        for name, count in Counter(build_names).items()
        if isinstance(name, str) and count > 1
    )
    for name in duplicates:
        errors.append(f"duplicate manifest entry: {name}")

    missing = sorted(inventory_name_set - set(build_names))
    extra = sorted(set(build_names) - inventory_name_set)
    for name in missing:
        errors.append(f"repository missing from manifest: {name}")
    for name in extra:
        errors.append(f"manifest repository missing from inventory: {name}")
    if build_names != inventory_names:
        errors.append("manifest order must exactly match inventory order")

    repository_by_name = {
        repo["name"]: repo
        for repo in repositories
        if isinstance(repo, dict) and isinstance(repo.get("name"), str)
    }

    classification_counts: Counter[str] = Counter()
    for index, build in enumerate(builds):
        if not isinstance(build, dict):
            errors.append(f"build entry {index} must be an object")
            continue

        name = build.get("name")
        label = name if isinstance(name, str) else f"entry {index}"
        absent = sorted(ENTRY_KEYS - build.keys())
        if absent:
            errors.append(f"{label}: missing keys: {', '.join(absent)}")
            continue

        classification = build["classification"]
        if classification not in CLASSIFICATIONS:
            errors.append(f"{label}: unknown classification {classification!r}")
        else:
            classification_counts[classification] += 1

        source = repository_by_name.get(name)
        if source is None:
            continue
        for key in (
            "upstream",
            "url",
            "default_branch",
            "archived",
            "upstream_is_fork",
        ):
            if build[key] != source.get(key):
                errors.append(
                    f"{label}: {key} differs from inventory "
                    f"({build[key]!r} != {source.get(key)!r})"
                )

        expected = expected_route(name, direct_native, native_test, fixture_scope)
        actual = (
            build["classification"],
            build["adapter_id"],
            build["adapter_status"],
            build["profile_policy"],
        )
        if actual != expected:
            errors.append(f"{label}: route {actual!r} should be {expected!r}")

        expected_shard = index // 28 + 1
        if build["shard"] != expected_shard:
            errors.append(
                f"{label}: shard {build['shard']!r} should be {expected_shard}"
            )

    if set(classification_counts) - CLASSIFICATIONS:
        errors.append("manifest contains an unrecognized classification")

    expected_counts = {
        "direct-native": len(direct_native),
        "native-test": len(native_test),
        "fixture-template-or-example": len(fixture_scope),
        "no-committed-native": len(repositories) - len(scoped_names),
    }
    if dict(classification_counts) != expected_counts:
        errors.append(
            f"classification counts {dict(classification_counts)!r} "
            f"should be {expected_counts!r}"
        )

    if manifest.get("schema") != 1:
        errors.append("manifest schema must be 1")
    if manifest.get("owner") != inventory.get("owner"):
        errors.append("manifest owner differs from inventory owner")
    if manifest.get("native_scope_scan_date") != native_scope.get("scan_date"):
        errors.append("manifest native-scope scan date differs from source")
    if manifest.get("profile_policies") != PROFILE_POLICIES:
        errors.append("profile policy definitions differ from the validated contract")

    profile_source = manifest.get("profile_source")
    if not isinstance(profile_source, str):
        errors.append("profile_source must be a repository-relative path")
        profile_count = 0
    else:
        profile_path = (root / profile_source).resolve()
        if profile_path != root and root not in profile_path.parents:
            errors.append("profile_source escapes the repository root")
            profile_count = 0
        else:
            targets = read_json(profile_path)
            profiles = targets.get("profiles")
            if not isinstance(profiles, list):
                errors.append(f"{profile_source}: profiles must be an array")
                profile_count = 0
            else:
                profile_count = len(profiles)

    if manifest.get("profile_count") != profile_count:
        errors.append(
            f"profile_count {manifest.get('profile_count')!r} should be {profile_count}"
        )

    shard_plan = manifest.get("sharding")
    if not isinstance(shard_plan, dict):
        errors.append("sharding must be an object")
        shard_plan = {}

    repositories_per_shard = shard_plan.get("repositories_per_full_shard")
    shard_count = shard_plan.get("shard_count")
    expected_shard_count = math.ceil(len(repositories) / 28)
    expected_max_jobs = 28 * profile_count
    expected_sharding = {
        "strategy": "inventory-order-contiguous",
        "shard_count": expected_shard_count,
        "repositories_per_full_shard": 28,
        "planning_profiles_per_repository": profile_count,
        "maximum_planned_jobs_per_shard": expected_max_jobs,
    }
    if shard_plan != expected_sharding:
        errors.append(f"sharding {shard_plan!r} should be {expected_sharding!r}")
    if expected_shard_count != 7:
        errors.append(f"inventory requires {expected_shard_count} shards, expected seven")
    if expected_max_jobs > GITHUB_MATRIX_JOB_LIMIT:
        errors.append(
            f"planned shard can create {expected_max_jobs} jobs; "
            f"GitHub matrix limit is {GITHUB_MATRIX_JOB_LIMIT}"
        )

    shard_counts = Counter(
        build.get("shard") for build in builds if isinstance(build, dict)
    )
    expected_shard_counts = {
        shard: min(28, len(repositories) - (shard - 1) * 28)
        for shard in range(1, expected_shard_count + 1)
    }
    if dict(sorted(shard_counts.items())) != expected_shard_counts:
        errors.append(
            f"shard counts {dict(sorted(shard_counts.items()))!r} "
            f"should be {expected_shard_counts!r}"
        )

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    counts = ", ".join(
        f"{classification}={expected_counts[classification]}"
        for classification in (
            "direct-native",
            "native-test",
            "fixture-template-or-example",
            "no-committed-native",
        )
    )
    shard_sizes = ",".join(str(expected_shard_counts[shard]) for shard in expected_shard_counts)
    print(
        f"build manifest valid: {len(builds)} repositories; {counts}; "
        f"shards={shard_sizes}; profiles={profile_count}; "
        f"max-planned-jobs={expected_max_jobs}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
