#!/usr/bin/env python3
"""Render immutable, size-bounded matrices for the affected native fleet."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MATRIX_LIMIT = 256
SHARD_SIZE = 252
SHARD_COUNT = 2
FLEET_CLASSIFICATIONS = {
    "direct-native",
    "native-test",
}
DISCOVERY_CLASSIFICATIONS = FLEET_CLASSIFICATIONS | {
    "fixture-template-or-example",
    "no-committed-native",
}
STANDARD_RUNNERS = {
    "ubuntu-24.04",
    "ubuntu-24.04-arm",
    "macos-15",
    "macos-15-intel",
}
LOCK_KEYS = {
    "schema",
    "destination_owner",
    "source_refs",
    "sources",
}
SOURCE_REF_KEYS = {
    "result_id",
    "name",
    "repository",
    "ref_name",
    "source_ref",
    "rust",
}
SOURCE_KEYS = {
    "result_id",
    "name",
    "ref_name",
    "adapter_id",
    "repository",
    "source_ref",
    "build_script",
    "profiles",
    "ruby_version",
    "rust",
}
SOURCE_OPTIONAL_KEYS = {
    "profile_overrides",
}
PROFILE_OVERRIDE_KEYS = {
    "build_script",
    "rust",
}
SAFE_PATH = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]*$")
SAFE_REF_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
SAFE_RESULT_ID = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
FULL_SHA = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SAFE_REPOSITORY_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
RUBY_VERSION = re.compile(
    r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$"
)


class DuplicateKeyError(ValueError):
    pass


class PlanError(ValueError):
    pass


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKeyError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=unique_object)
    except (OSError, json.JSONDecodeError, DuplicateKeyError) as exc:
        raise PlanError(f"{path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PlanError(f"{path}: top-level JSON value must be an object")
    return value


def compact(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)


def safe_evidence_id(result_id: str, profile_id: str, source_ref: str) -> str:
    raw = f"{result_id}-{profile_id}-{source_ref[:12]}".lower()
    return re.sub(r"[^a-z0-9._-]+", "-", raw).strip("-.")


def validate_ref_name(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not SAFE_REF_NAME.fullmatch(value)
        or value.endswith("/")
        or value.endswith(".")
        or "//" in value
        or ".." in value
        or "@{" in value
        or value.endswith(".lock")
        or any(part in {".", ".."} for part in value.split("/"))
    ):
        raise PlanError(f"{label}: invalid ref_name")
    return value


def validate_build_script(root: Path, path: Any, label: str) -> str:
    if not isinstance(path, str) or not SAFE_PATH.fullmatch(path):
        raise PlanError(f"{label}: invalid build_script")
    if path.startswith("/") or "//" in path or ".." in path.split("/"):
        raise PlanError(f"{label}: build_script must stay within adapters/")
    if not path.startswith("adapters/"):
        raise PlanError(f"{label}: build_script must be controller-relative under adapters/")

    adapters_root = (root / "adapters").resolve()
    candidate = (root / path).resolve()
    if adapters_root not in candidate.parents or not candidate.is_file():
        raise PlanError(f"{label}: build_script must name an existing file under adapters/")
    return path


def validate_profile_overrides(
    root: Path,
    source: dict[str, Any],
    requested_profiles: list[str],
    profile_by_id: dict[str, dict[str, Any]],
    result_id: str,
) -> dict[str, dict[str, Any]]:
    if "profile_overrides" not in source:
        return {}

    raw_overrides = source["profile_overrides"]
    if not isinstance(raw_overrides, dict) or not raw_overrides:
        raise PlanError(
            f"{result_id}: profile_overrides must be a nonempty object keyed by "
            "selected profile ids"
        )

    selected = set(requested_profiles)
    overrides: dict[str, dict[str, Any]] = {}
    for profile_id, raw_contract in raw_overrides.items():
        label = f"{result_id}: profile override {profile_id!r}"
        if profile_id not in profile_by_id:
            raise PlanError(f"{label} names an unknown profile")
        if profile_id not in selected:
            raise PlanError(f"{label} must also appear in profiles")
        if not isinstance(raw_contract, dict) or not raw_contract:
            raise PlanError(f"{label} must be a nonempty object")

        extra = sorted(raw_contract.keys() - PROFILE_OVERRIDE_KEYS)
        if extra:
            raise PlanError(f"{label} has unexpected fields: {', '.join(extra)}")

        contract: dict[str, Any] = {}
        if "build_script" in raw_contract:
            contract["build_script"] = validate_build_script(
                root,
                raw_contract["build_script"],
                f"{label} build_script",
            )
        if "rust" in raw_contract:
            if not isinstance(raw_contract["rust"], bool):
                raise PlanError(f"{label} rust must be boolean")
            contract["rust"] = raw_contract["rust"]
        overrides[profile_id] = contract
    return overrides


def profile_contract(source: dict[str, Any], profile_id: str) -> dict[str, Any]:
    """Return the effective build contract for one selected source profile."""

    override = source.get("profile_overrides", {}).get(profile_id, {})
    return {
        "build_script": override.get("build_script", source["build_script"]),
        "rust": override.get("rust", source["rust"]),
    }


def load_source_refs(
    lock: dict[str, Any],
    builds_by_name: dict[str, dict[str, Any]],
) -> dict[tuple[str, str], dict[str, Any]]:
    if lock.get("schema") != 2:
        raise PlanError("config/fleet-lock.json: schema must be 2")
    missing = sorted(LOCK_KEYS - lock.keys())
    extra = sorted(lock.keys() - LOCK_KEYS)
    if missing or extra:
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if extra:
            details.append(f"unexpected {', '.join(extra)}")
        raise PlanError(f"config/fleet-lock.json: {'; '.join(details)}")

    owner = lock.get("destination_owner")
    if owner != "ruby-zig":
        raise PlanError(
            "config/fleet-lock.json: destination_owner must be exactly ruby-zig"
        )
    entries = lock.get("source_refs")
    if not isinstance(entries, list):
        raise PlanError("config/fleet-lock.json: source_refs must be an array")

    result: dict[tuple[str, str], dict[str, Any]] = {}
    result_ids: set[str] = set()
    for index, entry in enumerate(entries):
        label = f"fleet-lock source_ref {index}"
        if not isinstance(entry, dict):
            raise PlanError(f"{label}: entry must be an object")
        missing = sorted(SOURCE_REF_KEYS - entry.keys())
        extra = sorted(entry.keys() - SOURCE_REF_KEYS)
        if missing or extra:
            details = []
            if missing:
                details.append(f"missing {', '.join(missing)}")
            if extra:
                details.append(f"unexpected {', '.join(extra)}")
            raise PlanError(f"{label}: {'; '.join(details)}")

        name = entry.get("name")
        if not isinstance(name, str) or name not in builds_by_name:
            raise PlanError(f"{label}: unknown repository {name!r}")
        build = builds_by_name[name]
        if build.get("classification") not in FLEET_CLASSIFICATIONS:
            raise PlanError(f"{name}: source_ref is outside the affected native fleet")
        if entry["repository"] != build.get("upstream"):
            raise PlanError(
                f"{name}: source_ref repository must be {build.get('upstream')}"
            )

        ref_name = validate_ref_name(entry.get("ref_name"), label)
        key = (name, ref_name)
        if key in result:
            raise PlanError(f"{name}: duplicate tracked ref {ref_name}")

        result_id = entry.get("result_id")
        if not isinstance(result_id, str) or not SAFE_RESULT_ID.fullmatch(result_id):
            raise PlanError(f"{label}: invalid result_id")
        if result_id in result_ids:
            raise PlanError(f"config/fleet-lock.json: duplicate result_id {result_id}")

        source_ref = entry.get("source_ref")
        if not isinstance(source_ref, str) or not FULL_SHA.fullmatch(source_ref):
            raise PlanError(f"{result_id}: source_ref must be a lowercase full commit SHA")
        if not isinstance(entry.get("rust"), bool):
            raise PlanError(f"{result_id}: rust must be boolean")

        result[key] = entry
        result_ids.add(result_id)

    for name, build in builds_by_name.items():
        if build.get("classification") not in FLEET_CLASSIFICATIONS:
            continue
        if name == "ruby":
            expected = {"master", "ruby_4_0", "ruby_3_4", "ruby_3_3", "ruby_3_2"}
        else:
            expected = {build.get("default_branch")}
        actual = {
            ref_name
            for (repository_name, ref_name) in result
            if repository_name == name
        }
        if actual != expected:
            raise PlanError(
                f"{name}: tracked refs {sorted(actual)!r} must be exactly "
                f"{sorted(expected)!r}"
            )
    return result


def load_sources(
    root: Path,
    lock: dict[str, Any],
    builds_by_name: dict[str, dict[str, Any]],
    profile_by_id: dict[str, dict[str, Any]],
    source_refs: dict[tuple[str, str], dict[str, Any]],
) -> dict[tuple[str, str], dict[str, Any]]:
    owner = lock["destination_owner"]
    sources = lock.get("sources")
    if not isinstance(sources, list):
        raise PlanError("config/fleet-lock.json: sources must be an array")

    result: dict[tuple[str, str], dict[str, Any]] = {}
    for index, source in enumerate(sources):
        label = f"fleet-lock source {index}"
        if not isinstance(source, dict):
            raise PlanError(f"{label}: entry must be an object")
        missing = sorted(SOURCE_KEYS - source.keys())
        extra = sorted(source.keys() - SOURCE_KEYS - SOURCE_OPTIONAL_KEYS)
        if missing or extra:
            details = []
            if missing:
                details.append(f"missing {', '.join(missing)}")
            if extra:
                details.append(f"unexpected {', '.join(extra)}")
            raise PlanError(f"{label}: {'; '.join(details)}")

        name = source.get("name")
        if not isinstance(name, str) or name not in builds_by_name:
            raise PlanError(f"{label}: unknown repository {name!r}")
        ref_name = validate_ref_name(source.get("ref_name"), label)
        key = (name, ref_name)
        if key in result:
            raise PlanError(f"{name}: duplicate executable source for {ref_name}")

        build = builds_by_name[name]
        if build.get("classification") not in FLEET_CLASSIFICATIONS:
            raise PlanError(f"{name}: source lock is outside the affected native fleet")
        tracked = source_refs.get(key)
        if tracked is None:
            raise PlanError(f"{name}@{ref_name}: executable source has no tracked source_ref")
        for field in ("result_id", "source_ref", "rust"):
            if source[field] != tracked[field]:
                raise PlanError(
                    f"{name}@{ref_name}: source {field} differs from tracked source_ref"
                )

        result_id = source["result_id"]
        if source["adapter_id"] != build.get("adapter_id"):
            raise PlanError(f"{result_id}: lock adapter_id differs from config/builds.json")
        repository = source["repository"]
        owner_prefix = f"{owner}/"
        repository_name = (
            repository[len(owner_prefix) :]
            if isinstance(repository, str) and repository.startswith(owner_prefix)
            else ""
        )
        if not SAFE_REPOSITORY_NAME.fullmatch(repository_name):
            raise PlanError(
                f"{result_id}: repository must be an exact {owner}/NAME fork"
            )
        validate_build_script(root, source["build_script"], result_id)

        requested_profiles = source["profiles"]
        if (
            not isinstance(requested_profiles, list)
            or not requested_profiles
            or not all(isinstance(profile, str) and profile for profile in requested_profiles)
        ):
            raise PlanError(f"{result_id}: profiles must be a nonempty array of target ids")
        if len(requested_profiles) != len(set(requested_profiles)):
            raise PlanError(f"{result_id}: profiles must not contain duplicates")
        unknown_profiles = sorted(set(requested_profiles) - profile_by_id.keys())
        if unknown_profiles:
            raise PlanError(
                f"{result_id}: unknown requested profiles: {', '.join(unknown_profiles)}"
            )

        profile_overrides = validate_profile_overrides(
            root,
            source,
            requested_profiles,
            profile_by_id,
            result_id,
        )

        ruby_version = source["ruby_version"]
        if not isinstance(ruby_version, str) or not RUBY_VERSION.fullmatch(ruby_version):
            raise PlanError(f"{result_id}: ruby_version must be an exact numeric x.y.z")
        normalized = dict(source)
        if profile_overrides:
            normalized["profile_overrides"] = profile_overrides
        result[key] = normalized
    return result

@dataclass(frozen=True)
class Lane:
    name: str
    result_id: str
    ref_name: str | None
    profile: dict[str, Any]
    classification: str
    ready: bool
    reason: str | None
    source: dict[str, Any] | None


@dataclass(frozen=True)
class FleetPlan:
    lanes: tuple[Lane, ...]
    shard_count: int
    active_shards: int
    discovery_repositories: int
    fleet_repositories: int
    source_identities: int
    maximum_jobs: int

    @property
    def desired_jobs(self) -> int:
        return len(self.lanes)


def plan_fleet(root: Path) -> FleetPlan:
    builds_document = read_json(root / "config" / "builds.json")
    targets_document = read_json(root / "config" / "targets.json")
    lock = read_json(root / "config" / "fleet-lock.json")

    builds = builds_document.get("builds")
    profiles = targets_document.get("profiles")
    if not isinstance(builds, list) or not all(isinstance(item, dict) for item in builds):
        raise PlanError("config/builds.json: builds must be an array of objects")
    if not isinstance(profiles, list) or not all(isinstance(item, dict) for item in profiles):
        raise PlanError("config/targets.json: profiles must be an array of objects")
    if builds_document.get("count") != len(builds):
        raise PlanError("config/builds.json: count does not match builds")

    builds_by_name: dict[str, dict[str, Any]] = {}
    for build in builds:
        name = build.get("name")
        if not isinstance(name, str) or not name:
            raise PlanError("config/builds.json: every build needs a name")
        if name in builds_by_name:
            raise PlanError(f"config/builds.json: duplicate build {name}")
        classification = build.get("classification")
        if classification not in DISCOVERY_CLASSIFICATIONS:
            raise PlanError(f"{name}: unknown classification {classification!r}")
        builds_by_name[name] = build

    profile_by_id: dict[str, dict[str, Any]] = {}
    matrix_profiles: list[dict[str, Any]] = []
    for profile in profiles:
        profile_id = profile.get("id")
        runner = profile.get("runner")
        if not isinstance(profile_id, str) or not profile_id:
            raise PlanError("config/targets.json: every profile needs an id")
        if profile_id in profile_by_id:
            raise PlanError(f"config/targets.json: duplicate profile {profile_id}")
        if runner not in STANDARD_RUNNERS:
            raise PlanError(f"{profile_id}: unsupported public runner {runner!r}")
        rust_link_status = profile.get("rust_link_status", "unverified")
        if rust_link_status not in {"smoke-verified", "unverified", "blocked"}:
            raise PlanError(
                f"{profile_id}: invalid Rust link status {rust_link_status!r}"
            )
        matrix_profile = {
            "id": profile_id,
            "runner": runner,
            "rust_link_status": rust_link_status,
        }
        profile_by_id[profile_id] = matrix_profile
        matrix_profiles.append(matrix_profile)

    if len(matrix_profiles) != builds_document.get("profile_count"):
        raise PlanError("config/builds.json: profile_count differs from targets")

    source_refs = load_source_refs(lock, builds_by_name)
    sources = load_sources(root, lock, builds_by_name, profile_by_id, source_refs)
    refs_by_name: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for (name, _), source_ref in source_refs.items():
        refs_by_name[name].append(source_ref)

    lanes: list[Lane] = []
    fleet_repositories = 0
    source_identities = 0

    for build in builds:
        name = build["name"]
        classification = build["classification"]
        if classification not in FLEET_CLASSIFICATIONS:
            continue

        fleet_repositories += 1
        adapter_status = build.get("adapter_status")
        variants: list[dict[str, Any] | None] = refs_by_name.get(name) or [None]
        source_identities += len(variants)

        for tracked in variants:
            result_id = tracked["result_id"] if tracked is not None else name
            ref_name = tracked["ref_name"] if tracked is not None else None
            source = sources.get((name, ref_name)) if ref_name is not None else None
            selected_profiles = set(source["profiles"]) if source is not None else set()

            if adapter_status == "ready" and source is not None:
                ready, reason = True, None
            elif adapter_status == "ready" and tracked is not None:
                ready, reason = False, "tracked source ref lacks a certified adapter lock"
            elif adapter_status == "ready":
                ready, reason = False, "ready adapter lacks an immutable source lock"
            elif adapter_status == "planned":
                ready, reason = False, "native adapter is planned"
            else:
                ready, reason = False, f"native adapter status is {adapter_status!r}"
            if source is not None and adapter_status != "ready":
                reason = f"{reason}; source lock is present before adapter is ready"

            for profile in matrix_profiles:
                lane_ready = ready
                lane_reason = reason
                contract = (
                    profile_contract(source, profile["id"])
                    if source is not None and profile["id"] in selected_profiles
                    else None
                )
                if lane_ready and contract is None:
                    lane_ready = False
                    lane_reason = (
                        f"target profile {profile['id']} is not yet certified "
                        "for this adapter"
                    )
                if (
                    lane_ready
                    and contract is not None
                    and contract["rust"]
                    and profile["rust_link_status"] != "smoke-verified"
                ):
                    lane_ready = False
                    lane_reason = (
                        f"Rust final linking status for profile {profile['id']} is "
                        f"{profile['rust_link_status']}; only smoke-verified "
                        "profiles may enable Rust"
                    )
                lanes.append(
                    Lane(
                        name=name,
                        result_id=result_id,
                        ref_name=ref_name,
                        profile=profile,
                        classification=classification,
                        ready=lane_ready,
                        reason=lane_reason,
                        source=source if lane_ready else None,
                    )
                )

    maximum_jobs = source_identities * len(matrix_profiles)
    active_shards = math.ceil(len(lanes) / SHARD_SIZE)
    if SHARD_SIZE >= MATRIX_LIMIT:
        raise PlanError("internal shard size must stay below GitHub's matrix limit")
    if active_shards > SHARD_COUNT:
        raise PlanError(
            f"fleet requires {active_shards} shards, but only {SHARD_COUNT} are declared"
        )
    if maximum_jobs > SHARD_COUNT * SHARD_SIZE:
        raise PlanError("two shards do not cover the affected native target envelope")

    return FleetPlan(
        lanes=tuple(lanes),
        shard_count=SHARD_COUNT,
        active_shards=active_shards,
        discovery_repositories=len(builds),
        fleet_repositories=fleet_repositories,
        source_identities=source_identities,
        maximum_jobs=maximum_jobs,
    )

def shard_lanes(plan: FleetPlan, shard: int) -> tuple[Lane, ...]:
    if shard < 1 or shard > plan.shard_count:
        raise PlanError(f"shard must be between 1 and {plan.shard_count}")
    start = (shard - 1) * SHARD_SIZE
    return plan.lanes[start : start + SHARD_SIZE]


def matrix_entry(lane: Lane) -> dict[str, Any]:
    if lane.source is None:
        raise PlanError(f"{lane.name}: cannot render an unlocked lane")
    profile_id = lane.profile["id"]
    source_ref = lane.source["source_ref"]
    contract = profile_contract(lane.source, profile_id)
    return {
        "allow_no_native": False,
        "build_script": contract["build_script"],
        "evidence_id": safe_evidence_id(lane.result_id, profile_id, source_ref),
        "profile_id": profile_id,
        "result_id": lane.result_id,
        "profiles": compact(
            [{"id": profile_id, "runner": lane.profile["runner"]}]
        ),
        "repository": lane.source["repository"],
        "ruby_version": lane.source["ruby_version"],
        "runner": lane.profile["runner"],
        "rust": contract["rust"],
        "source_ref": source_ref,
        "source_ref_name": lane.ref_name,
    }


def shard_summary(plan: FleetPlan, shard: int) -> tuple[str, dict[str, str]]:
    lanes = shard_lanes(plan, shard)
    ready = [lane for lane in lanes if lane.ready]
    pending = [lane for lane in lanes if not lane.ready]
    pending_by_reason: dict[str, set[str]] = defaultdict(set)
    for lane in pending:
        pending_by_reason[lane.reason or "adapter is not ready"].add(lane.result_id)

    matrix = {"include": [matrix_entry(lane) for lane in ready]}
    pending_ids = sorted({lane.result_id for lane in pending}, key=str.casefold)
    pending_repositories = sorted({lane.name for lane in pending}, key=str.casefold)
    lines = [
        f"### Fleet shard {shard}",
        "",
        "| Measure | Count |",
        "| --- | ---: |",
        f"| Desired lanes | {len(lanes)} |",
        f"| Ready lanes | {len(ready)} |",
        f"| Pending lanes | {len(pending)} |",
        f"| Pending source identities | {len(pending_ids)} |",
        f"| Pending repositories | {len(pending_repositories)} |",
        "",
        (
            f"Current plan: {plan.fleet_repositories} affected native repositories "
            f"and {plan.source_identities} source identities from a "
            f"{plan.discovery_repositories}-repository discovery inventory. "
            f"The plan tracks all {plan.desired_jobs} target lanes in the "
            f"{plan.maximum_jobs}-lane coverage envelope across "
            f"{plan.active_shards} active shards. "
            "Pure-host and fixture-only repositories do not create build lanes."
        ),
    ]
    if pending_by_reason:
        lines.extend(["", "Pending coverage:"])
        for reason in sorted(pending_by_reason, key=str.casefold):
            names = sorted(pending_by_reason[reason], key=str.casefold)
            lines.append(f"- {reason} ({len(names)}): `{', '.join(names)}`")
    if not lanes:
        lines.extend(["", "This capacity shard has no lanes in the current plan."])

    outputs = {
        "active_shards": str(plan.active_shards),
        "desired_jobs": str(len(lanes)),
        "matrix": compact(matrix),
        "pending_jobs": str(len(pending)),
        "pending_repositories": str(len(pending_repositories)),
        "ready_jobs": str(len(ready)),
    }
    return "\n".join(lines) + "\n", outputs


def append_outputs(path: Path, outputs: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        for key in sorted(outputs):
            handle.write(f"{key}={outputs[key]}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="controller repository root",
    )
    parser.add_argument("--shard", type=int, choices=range(1, SHARD_COUNT + 1))
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    try:
        plan = plan_fleet(args.root.resolve())
        if args.check:
            print(
                f"fleet plan valid: desired={plan.desired_jobs}; "
                f"maximum={plan.maximum_jobs}; active-shards={plan.active_shards}; "
                f"capacity-shards={plan.shard_count}; "
                f"affected={plan.fleet_repositories}; "
                f"source-identities={plan.source_identities}; "
                f"discovery={plan.discovery_repositories}"
            )
            return 0
        if args.shard is None:
            parser.error("--shard is required unless --check is used")

        summary, outputs = shard_summary(plan, args.shard)
        if args.github_output:
            append_outputs(args.github_output, outputs)
        if args.summary:
            with args.summary.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(summary)
        if not args.github_output:
            print(outputs["matrix"])
        return 0
    except PlanError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
