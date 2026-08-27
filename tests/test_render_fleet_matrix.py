from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "render_fleet_matrix", ROOT / "scripts" / "render-fleet-matrix.py"
)
assert SPEC and SPEC.loader
renderer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = renderer
SPEC.loader.exec_module(renderer)


CRUBY_REFS = {
    "master": "89d3b11eace35b8e279b970b4ff5125f171d0d4b",
    "ruby_4_0": "f3a72fe0a6d35583e215422e8887d3df0a1670b8",
    "ruby_3_4": "aac3e36dd4bee40fc89893209553903706fa5666",
    "ruby_3_3": "0581089df9f0af0fe6b64cb8167987c211100947",
}


class FleetMatrixTests(unittest.TestCase):
    def test_current_workload_is_branch_aware_affected_native_fleet(self) -> None:
        plan = renderer.plan_fleet(ROOT)

        self.assertEqual(plan.discovery_repositories, 190)
        self.assertEqual(plan.fleet_repositories, 39)
        self.assertEqual(plan.source_identities, 42)
        self.assertEqual(plan.maximum_jobs, 378)
        self.assertEqual(plan.desired_jobs, 357)
        self.assertEqual(sum(lane.ready for lane in plan.lanes), 6)
        self.assertEqual(plan.active_shards, 2)
        self.assertEqual(plan.shard_count, 2)
        self.assertEqual(
            [len(renderer.shard_lanes(plan, shard)) for shard in range(1, 3)],
            [252, 105],
        )
        self.assertEqual(
            {lane.classification for lane in plan.lanes},
            {"direct-native", "native-test"},
        )

        ruby_lanes = [lane for lane in plan.lanes if lane.name == "ruby"]
        self.assertEqual(len(ruby_lanes), 4 * 9)
        self.assertEqual(
            {lane.ref_name for lane in ruby_lanes},
            set(CRUBY_REFS),
        )
        self.assertEqual(
            {lane.result_id for lane in ruby_lanes},
            {
                "ruby-master",
                "ruby-ruby_4_0",
                "ruby-ruby_3_4",
                "ruby-ruby_3_3",
            },
        )
        self.assertTrue(all(not lane.ready for lane in ruby_lanes))

        lock = json.loads((ROOT / "config" / "fleet-lock.json").read_text())
        actual_refs = {
            entry["ref_name"]: entry["source_ref"]
            for entry in lock["source_refs"]
            if entry["name"] == "ruby"
        }
        self.assertEqual(actual_refs, CRUBY_REFS)
        self.assertNotIn("ruby_3_2", actual_refs)
        self.assertEqual(
            {source["name"] for source in lock["sources"]},
            {"bigdecimal", "json", "prism"},
        )
        self.assertTrue(
            all(
                source["profiles"]
                == ["x86_64-linux-gnu.2.17", "x86_64-linux-musl"]
                and source["ruby_version"] == "3.2.3"
                for source in lock["sources"]
            )
        )

    def _write_fixture(
        self,
        root: Path,
        *,
        lock: dict[str, object] | None = None,
    ) -> dict[str, object]:
        (root / "config").mkdir()
        (root / "adapters" / "repo" / "native").mkdir(parents=True)
        (root / "adapters" / "test" / "spec").mkdir(parents=True)
        (root / "adapters" / "repo" / "native" / "build.sh").write_text(
            "#!/usr/bin/env bash\n", encoding="utf-8"
        )
        (root / "adapters" / "test" / "spec" / "build.sh").write_text(
            "#!/usr/bin/env bash\n", encoding="utf-8"
        )

        builds = {
            "count": 4,
            "profile_count": 3,
            "builds": [
                {
                    "name": "native",
                    "upstream": "ruby/native",
                    "default_branch": "master",
                    "classification": "direct-native",
                    "adapter_id": "repo/native",
                    "adapter_status": "ready",
                    "profile_policy": "zig-build-only",
                },
                {
                    "name": "spec",
                    "upstream": "ruby/spec",
                    "default_branch": "master",
                    "classification": "native-test",
                    "adapter_id": "test/spec",
                    "adapter_status": "ready",
                    "profile_policy": "zig-test-scope-only",
                },
                {
                    "name": "fixture",
                    "upstream": "ruby/fixture",
                    "default_branch": "master",
                    "classification": "fixture-template-or-example",
                    "adapter_id": None,
                    "adapter_status": "not-applicable",
                    "profile_policy": "not-applicable",
                },
                {
                    "name": "pure",
                    "upstream": "ruby/pure",
                    "default_branch": "master",
                    "classification": "no-committed-native",
                    "adapter_id": None,
                    "adapter_status": "not-applicable",
                    "profile_policy": "not-applicable",
                },
            ],
        }
        targets = {
            "profiles": [
                {
                    "id": "x86_64-linux-gnu.2.17",
                    "runner": "ubuntu-24.04",
                    "rust_link_status": "smoke-verified",
                },
                {
                    "id": "x86_64-linux-musl",
                    "runner": "ubuntu-24.04",
                    "rust_link_status": "unverified",
                },
                {
                    "id": "aarch64-linux-musl",
                    "runner": "ubuntu-24.04-arm",
                    "rust_link_status": "blocked",
                },
            ]
        }
        if lock is None:
            lock = {
                "schema": 2,
                "destination_owner": "ruby-zig",
                "source_refs": [
                    {
                        "result_id": "native-master",
                        "name": "native",
                        "repository": "ruby/native",
                        "ref_name": "master",
                        "source_ref": "a" * 40,
                        "rust": True,
                    },
                    {
                        "result_id": "spec-master",
                        "name": "spec",
                        "repository": "ruby/spec",
                        "ref_name": "master",
                        "source_ref": "b" * 40,
                        "rust": False,
                    },
                ],
                "sources": [
                    {
                        "result_id": "native-master",
                        "name": "native",
                        "ref_name": "master",
                        "adapter_id": "repo/native",
                        "repository": "ruby-zig/native",
                        "source_ref": "a" * 40,
                        "build_script": "adapters/repo/native/build.sh",
                        "profiles": [
                            "x86_64-linux-gnu.2.17",
                            "aarch64-linux-musl",
                        ],
                        "ruby_version": "3.3.6",
                        "rust": True,
                    },
                    {
                        "result_id": "spec-master",
                        "name": "spec",
                        "ref_name": "master",
                        "adapter_id": "test/spec",
                        "repository": "ruby-zig/spec",
                        "source_ref": "b" * 40,
                        "build_script": "adapters/test/spec/build.sh",
                        "profiles": ["x86_64-linux-musl"],
                        "ruby_version": "3.2.3",
                        "rust": False,
                    },
                ],
            }

        for name, document in (
            ("builds.json", builds),
            ("targets.json", targets),
            ("fleet-lock.json", lock),
        ):
            (root / "config" / name).write_text(
                json.dumps(document), encoding="utf-8"
            )
        return lock

    def test_lock_selects_profiles_and_blocked_rust_stays_pending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)

            plan = renderer.plan_fleet(root)
            self.assertEqual(plan.discovery_repositories, 4)
            self.assertEqual(plan.fleet_repositories, 2)
            self.assertEqual(plan.source_identities, 2)
            self.assertEqual(plan.maximum_jobs, 6)
            self.assertEqual(plan.desired_jobs, 3)
            self.assertEqual(
                [(lane.result_id, lane.profile["id"]) for lane in plan.lanes],
                [
                    ("native-master", "x86_64-linux-gnu.2.17"),
                    ("native-master", "aarch64-linux-musl"),
                    ("spec-master", "x86_64-linux-musl"),
                ],
            )

            _, outputs = renderer.shard_summary(plan, 1)
            matrix = json.loads(outputs["matrix"])["include"]
            self.assertEqual(outputs["ready_jobs"], "2")
            self.assertEqual(outputs["pending_jobs"], "1")
            self.assertEqual(
                {(entry["result_id"], entry["profile_id"]) for entry in matrix},
                {
                    ("native-master", "x86_64-linux-gnu.2.17"),
                    ("spec-master", "x86_64-linux-musl"),
                },
            )
            native = next(entry for entry in matrix if entry["result_id"] == "native-master")
            spec = next(entry for entry in matrix if entry["result_id"] == "spec-master")
            self.assertEqual(native["ruby_version"], "3.3.6")
            self.assertEqual(native["source_ref_name"], "master")
            self.assertEqual(native["build_script"], "adapters/repo/native/build.sh")
            self.assertFalse(native["allow_no_native"])
            self.assertEqual(spec["ruby_version"], "3.2.3")
            self.assertFalse(spec["rust"])
            self.assertNotIn("ruby-zig/pure", {entry["repository"] for entry in matrix})

    def test_cruby_branches_can_have_distinct_executable_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            builds_path = root / "config" / "builds.json"
            builds = json.loads(builds_path.read_text())
            ruby_build = builds["builds"][0]
            ruby_build.update(name="ruby", upstream="ruby/ruby")
            builds_path.write_text(json.dumps(builds), encoding="utf-8")

            ruby_refs = [
                {
                    "result_id": "ruby-master",
                    "name": "ruby",
                    "repository": "ruby/ruby",
                    "ref_name": "master",
                    "source_ref": "a" * 40,
                    "rust": True,
                },
                {
                    "result_id": "ruby-ruby_4_0",
                    "name": "ruby",
                    "repository": "ruby/ruby",
                    "ref_name": "ruby_4_0",
                    "source_ref": "c" * 40,
                    "rust": True,
                },
                {
                    "result_id": "ruby-ruby_3_4",
                    "name": "ruby",
                    "repository": "ruby/ruby",
                    "ref_name": "ruby_3_4",
                    "source_ref": "d" * 40,
                    "rust": True,
                },
                {
                    "result_id": "ruby-ruby_3_3",
                    "name": "ruby",
                    "repository": "ruby/ruby",
                    "ref_name": "ruby_3_3",
                    "source_ref": "e" * 40,
                    "rust": True,
                },
            ]
            lock["source_refs"] = ruby_refs + [lock["source_refs"][1]]
            master = lock["sources"][0]
            master.update(
                result_id="ruby-master",
                name="ruby",
                repository="ruby-zig/ruby",
            )
            release = copy.deepcopy(master)
            release.update(
                result_id="ruby-ruby_4_0",
                ref_name="ruby_4_0",
                source_ref="c" * 40,
                profiles=["x86_64-linux-musl"],
            )
            lock["sources"] = [master, release, lock["sources"][1]]
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(lock), encoding="utf-8"
            )

            plan = renderer.plan_fleet(root)
            self.assertEqual(plan.source_identities, 5)
            self.assertEqual(plan.maximum_jobs, 15)
            self.assertEqual(plan.desired_jobs, 10)
            _, outputs = renderer.shard_summary(plan, 1)
            matrix = json.loads(outputs["matrix"])["include"]
            self.assertEqual(
                {entry["result_id"] for entry in matrix},
                {"ruby-master", "ruby-ruby_4_0", "spec-master"},
            )
            self.assertEqual(
                next(
                    entry
                    for entry in matrix
                    if entry["result_id"] == "ruby-ruby_4_0"
                )["source_ref_name"],
                "ruby_4_0",
            )

    def test_invalid_executable_lock_contracts_are_rejected(self) -> None:
        cases = {
            "empty profiles": (
                lambda source: source.update(profiles=[]),
                "profiles must be a nonempty array",
            ),
            "duplicate profiles": (
                lambda source: source.update(
                    profiles=[
                        "x86_64-linux-gnu.2.17",
                        "x86_64-linux-gnu.2.17",
                    ]
                ),
                "profiles must not contain duplicates",
            ),
            "unknown profile": (
                lambda source: source.update(profiles=["not-a-target"]),
                "unknown requested profiles",
            ),
            "short Ruby version": (
                lambda source: source.update(ruby_version="3.3"),
                "ruby_version must be an exact numeric x.y.z",
            ),
            "leading-zero Ruby version": (
                lambda source: source.update(ruby_version="03.3.6"),
                "ruby_version must be an exact numeric x.y.z",
            ),
            "script outside adapters": (
                lambda source: source.update(build_script="build.sh"),
                "controller-relative under adapters/",
            ),
            "untracked ref": (
                lambda source: source.update(ref_name="other"),
                "has no tracked source_ref",
            ),
            "changed source SHA": (
                lambda source: source.update(source_ref="d" * 40),
                "differs from tracked source_ref",
            ),
        }

        for label, (mutate, message) in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                lock = self._write_fixture(root)
                invalid = copy.deepcopy(lock)
                mutate(invalid["sources"][0])
                (root / "config" / "fleet-lock.json").write_text(
                    json.dumps(invalid), encoding="utf-8"
                )
                with self.assertRaisesRegex(renderer.PlanError, message):
                    renderer.plan_fleet(root)

    def test_default_branch_identity_is_exact_not_count_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            invalid = copy.deepcopy(lock)
            invalid["source_refs"][0]["ref_name"] = "release"
            invalid["sources"][0]["ref_name"] = "release"
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(invalid), encoding="utf-8"
            )

            with self.assertRaisesRegex(renderer.PlanError, "must be exactly"):
                renderer.plan_fleet(root)

    def test_ref_name_rules_match_git_boundaries(self) -> None:
        self.assertEqual(
            renderer.validate_ref_name("master", "test"),
            "master",
        )
        self.assertEqual(
            renderer.validate_ref_name("release/3.3", "test"),
            "release/3.3",
        )
        for value in (
            "trailing/",
            "trailing.",
            "name.lock",
            "bad@{ref",
            "double..dot",
            "double//slash",
            "dot/./component",
            "dot/../component",
        ):
            with self.subTest(value=value):
                with self.assertRaisesRegex(renderer.PlanError, "invalid ref_name"):
                    renderer.validate_ref_name(value, "test")

    def test_destination_owner_is_exact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            invalid = copy.deepcopy(lock)
            invalid["destination_owner"] = "someone-else"
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(invalid), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                renderer.PlanError, "destination_owner must be exactly ruby-zig"
            ):
                renderer.plan_fleet(root)

    def test_duplicate_result_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            invalid = copy.deepcopy(lock)
            invalid["source_refs"][1]["result_id"] = "native-master"
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(invalid), encoding="utf-8"
            )

            with self.assertRaisesRegex(renderer.PlanError, "duplicate result_id"):
                renderer.plan_fleet(root)

    def test_source_outside_affected_fleet_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            invalid = copy.deepcopy(lock)
            invalid["source_refs"][0].update(
                name="pure",
                repository="ruby/pure",
            )
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(invalid), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                renderer.PlanError, "outside the affected native fleet"
            ):
                renderer.plan_fleet(root)


if __name__ == "__main__":
    unittest.main()
