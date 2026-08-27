#!/usr/bin/env python3
"""Render a lock-derived matrix for one continuous source update."""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any


FULL_SHA_40 = re.compile(r"^[0-9a-f]{40}$")
FORK_REPOSITORY = re.compile(r"^ruby-zig/[A-Za-z0-9][A-Za-z0-9._-]*$")


def load_fleet_renderer() -> Any:
    path = Path(__file__).with_name("render-fleet-matrix.py")
    spec = importlib.util.spec_from_file_location("ruby_zig_fleet_renderer", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load fleet renderer from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


renderer = load_fleet_renderer()


@dataclass(frozen=True)
class ContinuousPlan:
    adapter_id: str
    baseline_sha: str
    build_script: str
    matrix: dict[str, Any]
    profiles: tuple[str, ...]
    ready_jobs: int
    result_id: str
    ruby_version: str
    rust: bool
    source_ref_name: str
    source_repository: str
    source_sha: str
    upstream_repository: str

    def outputs(self) -> dict[str, str]:
        return {
            "baseline_sha": self.baseline_sha,
            "matrix": renderer.compact(self.matrix),
            "ready_jobs": str(self.ready_jobs),
            "result_id": self.result_id,
            "source_ref_name": self.source_ref_name,
            "source_repository": self.source_repository,
            "source_sha": self.source_sha,
            "upstream_repository": self.upstream_repository,
        }

    def summary(self) -> str:
        profile_list = ", ".join(f"`{profile}`" for profile in self.profiles)
        return "\n".join(
            (
                "### Continuous build plan",
                "",
                "| Field | Lock-derived value |",
                "| --- | --- |",
                f"| Result | `{self.result_id}` |",
                f"| Fork | `{self.source_repository}` |",
                f"| Upstream | `{self.upstream_repository}` |",
                f"| Branch | `{self.source_ref_name}` |",
                f"| Certified baseline | `{self.baseline_sha}` |",
                f"| Candidate | `{self.source_sha}` |",
                f"| Adapter | `{self.adapter_id}` (`{self.build_script}`) |",
                f"| Profiles | {profile_list} |",
                f"| Ruby runtime | `{self.ruby_version}` |",
                f"| Rust boundary | `{'enabled' if self.rust else 'disabled'}` |",
                f"| Build jobs | {self.ready_jobs} |",
                "",
                "The immutable fleet lock supplied every build-affecting value. "
                "The caller supplied only the fork, tracked branch, and candidate SHA.",
                "",
            )
        )


def plan_continuous(
    root: Path,
    source_repository: str,
    source_ref_name: str,
    source_sha: str,
) -> ContinuousPlan:
    root = root.resolve()
    if not isinstance(source_repository, str) or not FORK_REPOSITORY.fullmatch(
        source_repository
    ):
        raise renderer.PlanError(
            "source-repository must be an exact ruby-zig fork name"
        )
    source_ref_name = renderer.validate_ref_name(
        source_ref_name, "continuous source-ref-name"
    )
    if not isinstance(source_sha, str) or not FULL_SHA_40.fullmatch(source_sha):
        raise renderer.PlanError(
            "source-sha must be an exact lowercase 40-character commit SHA"
        )

    fleet = renderer.plan_fleet(root)
    lock = renderer.read_json(root / "config" / "fleet-lock.json")
    owner = lock["destination_owner"]
    repository_entries = [
        entry
        for entry in lock["source_refs"]
        if f"{owner}/{entry['name']}" == source_repository
    ]
    if not repository_entries:
        raise renderer.PlanError(
            f"{source_repository}: repository is not allowlisted by the fleet lock"
        )

    tracked_entries = [
        entry
        for entry in repository_entries
        if entry["ref_name"] == source_ref_name
    ]
    if not tracked_entries:
        allowed = ", ".join(
            sorted((entry["ref_name"] for entry in repository_entries), key=str.casefold)
        )
        raise renderer.PlanError(
            f"{source_repository}@{source_ref_name}: branch is not allowlisted; "
            f"tracked branches: {allowed}"
        )
    if len(tracked_entries) != 1:
        raise renderer.PlanError(
            f"{source_repository}@{source_ref_name}: ambiguous tracked source"
        )
    tracked = tracked_entries[0]

    executable = [
        source
        for source in lock["sources"]
        if source["name"] == tracked["name"]
        and source["ref_name"] == tracked["ref_name"]
    ]
    if not executable:
        raise renderer.PlanError(
            f"{tracked['result_id']}: tracked source is pending and has no "
            "certified executable baseline"
        )
    if len(executable) != 1:
        raise renderer.PlanError(
            f"{tracked['result_id']}: ambiguous executable baseline"
        )
    source = executable[0]

    lanes = [
        lane
        for lane in fleet.lanes
        if lane.name == tracked["name"] and lane.ref_name == tracked["ref_name"]
    ]
    if not lanes:
        raise renderer.PlanError(
            f"{tracked['result_id']}: executable baseline produced no target lanes"
        )
    pending = [lane for lane in lanes if not lane.ready or lane.source is None]
    if pending:
        reasons = sorted({lane.reason or "not ready" for lane in pending})
        raise renderer.PlanError(
            f"{tracked['result_id']}: continuous build has pending lanes: "
            f"{'; '.join(reasons)}"
        )

    selected_profiles = tuple(source["profiles"])
    actual_profiles = {lane.profile["id"] for lane in lanes}
    if actual_profiles != set(selected_profiles) or len(lanes) != len(selected_profiles):
        raise renderer.PlanError(
            f"{tracked['result_id']}: rendered profiles differ from executable lock"
        )

    candidate_source = dict(source)
    candidate_source["source_ref"] = source_sha
    entries = [
        renderer.matrix_entry(replace(lane, source=candidate_source)) for lane in lanes
    ]
    return ContinuousPlan(
        adapter_id=source["adapter_id"],
        baseline_sha=source["source_ref"],
        build_script=source["build_script"],
        matrix={"include": entries},
        profiles=selected_profiles,
        ready_jobs=len(entries),
        result_id=tracked["result_id"],
        ruby_version=source["ruby_version"],
        rust=source["rust"],
        source_ref_name=tracked["ref_name"],
        source_repository=source["repository"],
        source_sha=source_sha,
        upstream_repository=tracked["repository"],
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="controller repository root",
    )
    parser.add_argument("--source-repository", required=True)
    parser.add_argument("--source-ref-name", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    try:
        plan = plan_continuous(
            args.root,
            args.source_repository,
            args.source_ref_name,
            args.source_sha,
        )
        if args.github_output:
            renderer.append_outputs(args.github_output, plan.outputs())
        if args.summary:
            with args.summary.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(plan.summary())
        if not args.github_output:
            print(renderer.compact(plan.matrix))
        return 0
    except renderer.PlanError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
