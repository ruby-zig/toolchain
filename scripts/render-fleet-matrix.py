#!/usr/bin/env python3
"""Render immutable, size-bounded matrices for the public runner fleet."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


MATRIX_LIMIT = 256
SHARD_SIZE = 252
SHARD_COUNT = 7
NATIVE_CLASSIFICATIONS = {
    "direct-native",
    "native-test",
    "fixture-template-or-example",
}
STANDARD_RUNNERS = {
    "ubuntu-24.04",
    "ubuntu-24.04-arm",
    "macos-15",
    "macos-15-intel",
}
SOURCE_KEYS = {
    "name",
    "adapter_id",
    "repository",
    "source_ref",
    "build_script",
    "rust",
}
SAFE_PATH = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]*$")
FULL_SHA = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


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


def safe_evidence_id(name: str, profile_id: str, source_ref: str) -> str:
    raw = f"{name}-{profile_id}-{source_ref[:12]}".lower()
    return re.sub(r"[^a-z0-9._-]+", "-", raw).strip("-.")


def validate_build_script(path: Any, label: str) -> str:
    if not isinstance(path, str) or not SAFE_PATH.fullmatch(path):
        raise PlanError(f"{label}: invalid build_script")
    if path.startswith("/") or "//" in path or ".." in path.split("/"):
        raise PlanError(f"{label}: build_script must stay within the fork")
    return path


def load_sources(lock: dict[str, Any], builds_by_name: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    if lock.get("schema") != 1:
        raise PlanError("config/fleet-lock.json: schema must be 1")
    owner = lock.get("destination_owner")
    if not isinstance(owner, str) or not owner:
        raise PlanError("config/fleet-lock.json: destination_owner must be a string")
    sources = lock.get("sources")
    if not isinstance(sources, list):
        raise PlanError("config/fleet-lock.json: sources must be an array")

    result: dict[str, dict[str, Any]] = {}
    for index, source in enumerate(sources):
        label = f"fleet-lock source {index}"
        if not isinstance(source, dict):
            raise PlanError(f"{label}: entry must be an object")
        missing = sorted(SOURCE_KEYS - source.keys())
        extra = sorted(source.keys() - SOURCE_KEYS)
        if missing or extra:
            parts = []
            if missing:
                parts.append(f"missing {', '.join(missing)}")
            if extra:
                parts.append(f"unexpected {', '.join(extra)}")
            raise PlanError(f"{label}: {'; '.join(parts)}")

        name = source.get("name")
        if not isinstance(name, str) or name not in builds_by_name:
            raise PlanError(f"{label}: unknown repository {name!r}")
        if name in result:
            raise PlanError(f"config/fleet-lock.json: duplicate source {name}")

        build = builds_by_name[name]
        if source["adapter_id"] != build.get("adapter_id"):
            raise PlanError(f"{name}: lock adapter_id differs from config/builds.json")
        expected_repository = f"{owner}/{name}"
        if source["repository"] != expected_repository:
            raise PlanError(
                f"{name}: repository must be the exact fork {expected_repository}"
            )
        source_ref = source["source_ref"]
        if not isinstance(source_ref, str) or not FULL_SHA.fullmatch(source_ref):
            raise PlanError(f"{name}: source_ref must be a lowercase full commit SHA")
        validate_build_script(source["build_script"], name)
        if not isinstance(source["rust"], bool):
            raise PlanError(f"{name}: rust must be boolean")
        result[name] = source
    return result


@dataclass(frozen=True)
class Lane:
    name: str
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
    native_repositories: int
    host_repositories: int

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
    host_profile_id = lock.get("host_profile")
    if host_profile_id not in profile_by_id:
        raise PlanError("config/fleet-lock.json: host_profile is not declared in targets")
    host_profile = profile_by_id[host_profile_id]
    if host_profile["runner"] != "ubuntu-24.04":
        raise PlanError("the host build/test profile must use ubuntu-24.04")

    sources = load_sources(lock, builds_by_name)
    lanes: list[Lane] = []
    native_repositories = 0
    host_repositories = 0

    for build in builds:
        name = build["name"]
        classification = build.get("classification")
        adapter_status = build.get("adapter_status")
        source = sources.get(name)

        if classification in NATIVE_CLASSIFICATIONS:
            native_repositories += 1
            desired_profiles = matrix_profiles
            if adapter_status == "ready" and source is not None:
                ready, reason = True, None
            elif adapter_status == "ready":
                ready, reason = False, "ready adapter lacks an immutable source lock"
            elif adapter_status == "planned":
                ready, reason = False, "native adapter is planned"
            else:
                ready, reason = False, f"native adapter status is {adapter_status!r}"
        elif classification == "no-committed-native":
            host_repositories += 1
            desired_profiles = [host_profile]
            if adapter_status == "ready" and build.get("profile_policy") == "zig-host-build-test" and source is not None:
                ready, reason = True, None
            elif adapter_status == "ready" and source is None:
                ready, reason = False, "ready host adapter lacks an immutable source lock"
            elif adapter_status in {"planned", "ready"}:
                ready, reason = False, "host build/test adapter is incomplete"
            elif adapter_status == "not-applicable":
                ready, reason = False, "host build/test adapter is not declared"
            else:
                ready, reason = False, f"host adapter status is {adapter_status!r}"
        else:
            raise PlanError(f"{name}: unknown classification {classification!r}")

        if source is not None and not ready and adapter_status != "ready":
            reason = f"{reason}; source lock is present before adapter is ready"

        for profile in desired_profiles:
            lane_ready = ready
            lane_reason = reason
            if (
                lane_ready
                and source is not None
                and source["rust"]
                and profile["rust_link_status"] == "blocked"
            ):
                lane_ready = False
                lane_reason = (
                    f"Rust final linking is blocked for profile {profile['id']}"
                )
            lanes.append(
                Lane(
                    name=name,
                    profile=profile,
                    classification=classification,
                    ready=lane_ready,
                    reason=lane_reason,
                    source=source if lane_ready else None,
                )
            )

    active_shards = math.ceil(len(lanes) / SHARD_SIZE)
    if SHARD_SIZE >= MATRIX_LIMIT:
        raise PlanError("internal shard size must stay below GitHub's matrix limit")
    if active_shards > SHARD_COUNT:
        raise PlanError(
            f"fleet requires {active_shards} shards, but only {SHARD_COUNT} are declared"
        )
    future_envelope = len(builds) * len(matrix_profiles)
    if future_envelope > SHARD_COUNT * SHARD_SIZE:
        raise PlanError("seven shards do not cover the all-repository target envelope")

    return FleetPlan(
        lanes=tuple(lanes),
        shard_count=SHARD_COUNT,
        active_shards=active_shards,
        native_repositories=native_repositories,
        host_repositories=host_repositories,
    )


def shard_lanes(plan: FleetPlan, shard: int) -> tuple[Lane, ...]:
    start = (shard - 1) * SHARD_SIZE
    return plan.lanes[start : start + SHARD_SIZE]


def matrix_entry(lane: Lane) -> dict[str, Any]:
    if lane.source is None:
        raise PlanError(f"{lane.name}: cannot render an unlocked lane")
    profile_id = lane.profile["id"]
    source_ref = lane.source["source_ref"]
    return {
        "allow_no_native": lane.classification == "no-committed-native",
        "build_script": lane.source["build_script"],
        "evidence_id": safe_evidence_id(lane.name, profile_id, source_ref),
        "profile_id": profile_id,
        "profiles": compact(
            [{"id": profile_id, "runner": lane.profile["runner"]}]
        ),
        "repository": lane.source["repository"],
        "runner": lane.profile["runner"],
        "rust": lane.source["rust"],
        "source_ref": source_ref,
    }


def shard_summary(plan: FleetPlan, shard: int) -> tuple[str, dict[str, str]]:
    lanes = shard_lanes(plan, shard)
    ready = [lane for lane in lanes if lane.ready]
    pending = [lane for lane in lanes if not lane.ready]
    pending_by_reason: dict[str, set[str]] = defaultdict(set)
    for lane in pending:
        pending_by_reason[lane.reason or "adapter is not ready"].add(lane.name)

    matrix = {"include": [matrix_entry(lane) for lane in ready]}
    pending_names = sorted({lane.name for lane in pending}, key=str.casefold)
    lines = [
        f"### Fleet shard {shard}",
        "",
        "| Measure | Count |",
        "| --- | ---: |",
        f"| Desired lanes | {len(lanes)} |",
        f"| Ready lanes | {len(ready)} |",
        f"| Pending lanes | {len(pending)} |",
        f"| Pending repositories | {len(pending_names)} |",
        "",
        (
            f"Current plan: {plan.native_repositories} native repositories across all "
            f"declared targets, plus one host build/test for each of "
            f"{plan.host_repositories} repositories without committed native source. "
            f"That is {plan.desired_jobs} lanes in {plan.active_shards} active shards; "
            f"seven shards reserve the full future target envelope."
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
        "pending_repositories": str(len(pending_names)),
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
                f"active-shards={plan.active_shards}; capacity-shards={plan.shard_count}; "
                f"native={plan.native_repositories}; host={plan.host_repositories}"
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
