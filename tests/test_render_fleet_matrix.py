from __future__ import annotations

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


class FleetMatrixTests(unittest.TestCase):
    def test_current_workload_uses_three_capacity_shards(self) -> None:
        plan = renderer.plan_fleet(ROOT)
        self.assertEqual(plan.native_repositories, 42)
        self.assertEqual(plan.host_repositories, 148)
        self.assertEqual(plan.desired_jobs, 42 * 9 + 148)
        self.assertEqual(plan.active_shards, 3)
        self.assertEqual(
            [len(renderer.shard_lanes(plan, shard)) for shard in range(1, 8)],
            [252, 252, 22, 0, 0, 0, 0],
        )

    def test_ready_sources_expand_with_exact_fork_and_sha(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            builds = {
                "count": 2,
                "profile_count": 2,
                "builds": [
                    {
                        "name": "native",
                        "classification": "direct-native",
                        "adapter_id": "repo/native",
                        "adapter_status": "ready",
                        "profile_policy": "zig-build-only",
                    },
                    {
                        "name": "pure",
                        "classification": "no-committed-native",
                        "adapter_id": "host/pure",
                        "adapter_status": "ready",
                        "profile_policy": "zig-host-build-test",
                    },
                ],
            }
            targets = {
                "profiles": [
                    {"id": "x86_64-linux-gnu.2.17", "runner": "ubuntu-24.04"},
                    {
                        "id": "aarch64-linux-musl",
                        "runner": "ubuntu-24.04",
                        "rust_link_status": "blocked",
                    },
                ]
            }
            sha_a = "a" * 40
            sha_b = "b" * 40
            lock = {
                "schema": 1,
                "destination_owner": "ruby-zig",
                "host_profile": "x86_64-linux-gnu.2.17",
                "sources": [
                    {
                        "name": "native",
                        "adapter_id": "repo/native",
                        "repository": "ruby-zig/native",
                        "source_ref": sha_a,
                        "build_script": ".ruby-zig/build.sh",
                        "rust": True,
                    },
                    {
                        "name": "pure",
                        "adapter_id": "host/pure",
                        "repository": "ruby-zig/pure",
                        "source_ref": sha_b,
                        "build_script": ".ruby-zig/build.sh",
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

            plan = renderer.plan_fleet(root)
            _, outputs = renderer.shard_summary(plan, 1)
            matrix = json.loads(outputs["matrix"])
            self.assertEqual(len(matrix["include"]), 2)
            self.assertEqual(matrix["include"][0]["repository"], "ruby-zig/native")
            self.assertEqual(matrix["include"][0]["source_ref"], sha_a)
            self.assertFalse(matrix["include"][1]["rust"])
            self.assertTrue(matrix["include"][1]["allow_no_native"])
            self.assertEqual(outputs["pending_jobs"], "1")


if __name__ == "__main__":
    unittest.main()
