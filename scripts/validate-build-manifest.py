#!/usr/bin/env python3
"""Validate the discovery manifest and affected native fleet metadata."""

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
}

CLASSIFICATIONS = {
    "direct-native",
    "native-test",
    "fixture-template-or-example",
    "no-committed-native",
}
FLEET_CLASSIFICATIONS = ["direct-native", "native-test"]

PROFILE_POLICIES = {
    "zig-build-only": {
        "profiles": "fleet-lock-selected",
        "native_compilation": "required",
        "claim": "build-only",
        "scope": "repository-product",
    },
    "zig-test-scope-only": {
        "profiles": "fleet-lock-selected",
        "native_compilation": "required",
        "claim": "build-only",
        "scope": "committed-native-tests-only",
    },
    "not-applicable": {
        "profiles": "none",
        "native_compilation": "not-applicable",
        "claim": "none",
        "scope": "outside-affected-native-fleet",
    },
}

GITHUB_MATRIX_JOB_LIMIT = 256
SHARD_SIZE = 252


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
) -> tuple[str, str | None, set[str], str]:
    if name in direct_native:
        return "direct-native", f"repo/{name}", {"planned", "ready"}, "zig-build-only"
    if name in native_test:
        return "native-test", f"test/{name}", {"planned", "ready"}, "zig-test-scope-only"
    if name in fixture_scope:
        return (
            "fixture-template-or-example",
            None,
            {"not-applicable"},
            "not-applicable",
        )
    return (
        "no-committed-native",
        None,
        {"not-applicable"},
        "not-applicable",
    )


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
    fleet_lock = read_json(root / "config" / "fleet-lock.json")

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
        extra_keys = sorted(build.keys() - ENTRY_KEYS)
        if absent:
            errors.append(f"{label}: missing keys: {', '.join(absent)}")
        if extra_keys:
            errors.append(f"{label}: unexpected keys: {', '.join(extra_keys)}")
        if absent or extra_keys:
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

        expected_class, expected_adapter, allowed_statuses, expected_policy = (
            expected_route(name, direct_native, native_test, fixture_scope)
        )
        if build["classification"] != expected_class:
            errors.append(
                f"{label}: classification {build['classification']!r} "
                f"should be {expected_class!r}"
            )
        if build["adapter_id"] != expected_adapter:
            errors.append(
                f"{label}: adapter_id {build['adapter_id']!r} "
                f"should be {expected_adapter!r}"
            )
        if build["adapter_status"] not in allowed_statuses:
            errors.append(
                f"{label}: adapter_status {build['adapter_status']!r} "
                f"must be one of {sorted(allowed_statuses)!r}"
            )
        if build["profile_policy"] != expected_policy:
            errors.append(
                f"{label}: profile_policy {build['profile_policy']!r} "
                f"should be {expected_policy!r}"
            )

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

    if manifest.get("schema") != 2:
        errors.append("manifest schema must be 2")
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

    fleet_names = direct_native | native_test
    fleet_repository_count = len(fleet_names)
    if fleet_lock.get("destination_owner") != "ruby-zig":
        errors.append("fleet-lock destination_owner must be exactly ruby-zig")
    source_refs = fleet_lock.get("source_refs")
    source_ref_counts: Counter[str] = Counter()
    actual_ref_names = {name: set() for name in fleet_names}
    seen_source_refs: set[tuple[str, str]] = set()
    seen_result_ids: set[str] = set()
    if not isinstance(source_refs, list):
        errors.append("fleet-lock source_refs must be an array")
    else:
        for index, source_ref in enumerate(source_refs):
            label = f"fleet-lock source_ref {index}"
            if not isinstance(source_ref, dict):
                errors.append(f"{label} must be an object")
                continue
            name = source_ref.get("name")
            ref_name = source_ref.get("ref_name")
            result_id = source_ref.get("result_id")
            if not isinstance(name, str) or name not in fleet_names:
                errors.append(f"{label} names a repository outside the affected fleet")
                continue
            if not isinstance(ref_name, str) or not ref_name:
                errors.append(f"{label} has no ref_name")
                continue
            key = (name, ref_name)
            if key in seen_source_refs:
                errors.append(f"{label} duplicates {name}@{ref_name}")
            seen_source_refs.add(key)
            actual_ref_names[name].add(ref_name)
            if not isinstance(result_id, str) or not result_id:
                errors.append(f"{label} has no result_id")
            elif result_id in seen_result_ids:
                errors.append(f"{label} duplicates result_id {result_id}")
            else:
                seen_result_ids.add(result_id)
            source_ref_counts[name] += 1

    build_default_branches = {
        build.get("name"): build.get("default_branch")
        for build in builds
        if isinstance(build, dict)
    }
    for name in sorted(fleet_names):
        if name == "ruby":
            expected_refs = {"master", "ruby_4_0", "ruby_3_4", "ruby_3_3"}
        else:
            expected_refs = {build_default_branches.get(name)}
        if actual_ref_names[name] != expected_refs:
            errors.append(
                f"{name}: tracked refs {sorted(actual_ref_names[name])!r} "
                f"must be exactly {sorted(expected_refs)!r}"
            )

    source_ref_count = sum(source_ref_counts.values())
    maximum_desired_jobs = source_ref_count * profile_count
    expected_fleet_scope = {
        "classifications": FLEET_CLASSIFICATIONS,
        "repository_count": fleet_repository_count,
        "source_ref_count": source_ref_count,
        "maximum_profiles_per_source_ref": profile_count,
        "maximum_desired_jobs": maximum_desired_jobs,
    }
    if manifest.get("fleet_scope") != expected_fleet_scope:
        errors.append(
            f"fleet_scope {manifest.get('fleet_scope')!r} "
            f"should be {expected_fleet_scope!r}"
        )

    expected_shard_count = math.ceil(maximum_desired_jobs / SHARD_SIZE)
    maximum_jobs_by_shard = [
        min(SHARD_SIZE, maximum_desired_jobs - (shard - 1) * SHARD_SIZE)
        for shard in range(1, expected_shard_count + 1)
    ]
    expected_sharding = {
        "strategy": "affected-lane-contiguous",
        "shard_count": expected_shard_count,
        "jobs_per_full_shard": SHARD_SIZE,
        "maximum_matrix_jobs": GITHUB_MATRIX_JOB_LIMIT,
        "maximum_desired_jobs": maximum_desired_jobs,
        "maximum_jobs_by_shard": maximum_jobs_by_shard,
    }
    if manifest.get("sharding") != expected_sharding:
        errors.append(
            f"sharding {manifest.get('sharding')!r} should be {expected_sharding!r}"
        )
    if SHARD_SIZE >= GITHUB_MATRIX_JOB_LIMIT:
        errors.append(
            f"shard size {SHARD_SIZE} must stay below GitHub's "
            f"{GITHUB_MATRIX_JOB_LIMIT}-job matrix limit"
        )
    if fleet_repository_count != 39:
        errors.append(
            f"affected native fleet has {fleet_repository_count} repositories, expected 39"
        )
    if source_ref_count != 42:
        errors.append(
            f"affected fleet has {source_ref_count} tracked source refs, expected 42"
        )
    if maximum_desired_jobs != 378 or maximum_jobs_by_shard != [252, 126]:
        errors.append(
            f"affected fleet envelope is {maximum_desired_jobs} lanes in "
            f"{maximum_jobs_by_shard!r}, expected 378 in [252, 126]"
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
    shard_sizes = ",".join(str(size) for size in maximum_jobs_by_shard)
    print(
        f"build manifest valid: {len(builds)} discovery repositories; {counts}; "
        f"affected={fleet_repository_count}; source-refs={source_ref_count}; "
        f"profiles={profile_count}; maximum-lanes={maximum_desired_jobs}; "
        f"shards={shard_sizes}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
