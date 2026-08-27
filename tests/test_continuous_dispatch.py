from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "render_continuous_matrix", ROOT / "scripts" / "render-continuous-matrix.py"
)
assert SPEC and SPEC.loader
planner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = planner
SPEC.loader.exec_module(planner)


class ContinuousDispatchTests(unittest.TestCase):
    def test_bigdecimal_derives_its_locked_gnu_lane(self) -> None:
        candidate = "c" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/bigdecimal", "master", candidate
        )

        self.assertEqual(plan.result_id, "bigdecimal-master")
        self.assertEqual(plan.upstream_repository, "ruby/bigdecimal")
        self.assertEqual(
            plan.baseline_sha, "9099c24e6af42c91109475217f47b77d7e830c81"
        )
        self.assertEqual(plan.adapter_id, "repo/bigdecimal")
        self.assertEqual(plan.build_script, "adapters/repo/bigdecimal/build.sh")
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertFalse(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)

        entries = plan.matrix["include"]
        self.assertEqual([entry["profile_id"] for entry in entries], ["x86_64-linux-gnu.2.17"])
        self.assertTrue(all(entry["source_ref"] == candidate for entry in entries))
        self.assertTrue(
            all(entry["repository"] == "ruby-zig/bigdecimal" for entry in entries)
        )
        self.assertTrue(all(entry["source_ref_name"] == "master" for entry in entries))

    def test_prism_derives_rust_boundary_from_lock(self) -> None:
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/prism", "main", "d" * 40
        )
        self.assertTrue(plan.rust)
        self.assertEqual(plan.adapter_id, "repo/prism")
        self.assertEqual(plan.ready_jobs, 2)
        self.assertTrue(all(entry["rust"] for entry in plan.matrix["include"]))

    def test_cruby_master_uses_dynamic_candidate_with_locked_gnu_contract(self) -> None:
        candidate = "e" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/ruby", "master", candidate
        )

        self.assertEqual(plan.result_id, "ruby-master")
        self.assertEqual(plan.upstream_repository, "ruby/ruby")
        self.assertEqual(
            plan.baseline_sha, "89d3b11eace35b8e279b970b4ff5125f171d0d4b"
        )
        self.assertEqual(plan.adapter_id, "repo/ruby")
        self.assertEqual(plan.build_script, "adapters/repo/ruby/build.sh")
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertTrue(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)
        entry = plan.matrix["include"][0]
        self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
        self.assertEqual(entry["source_ref"], candidate)
        self.assertEqual(entry["source_ref_name"], "master")
        self.assertTrue(entry["rust"])

    def test_cruby_4_0_uses_dynamic_candidate_with_locked_gnu_contract(self) -> None:
        candidate = "f" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/ruby", "ruby_4_0", candidate
        )

        self.assertEqual(plan.result_id, "ruby-ruby_4_0")
        self.assertEqual(plan.upstream_repository, "ruby/ruby")
        self.assertEqual(
            plan.baseline_sha, "f3a72fe0a6d35583e215422e8887d3df0a1670b8"
        )
        self.assertEqual(plan.adapter_id, "repo/ruby")
        self.assertEqual(plan.build_script, "adapters/repo/ruby/build.sh")
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertTrue(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)
        entry = plan.matrix["include"][0]
        self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
        self.assertEqual(entry["source_ref"], candidate)
        self.assertEqual(entry["source_ref_name"], "ruby_4_0")
        self.assertTrue(entry["rust"])

    def test_repository_branch_and_sha_are_exactly_allowlisted(self) -> None:
        cases = (
            (
                "ruby-zig/not-in-lock",
                "master",
                "a" * 40,
                "repository is not allowlisted",
            ),
            (
                "ruby-zig/bigdecimal",
                "main",
                "a" * 40,
                "branch is not allowlisted",
            ),
            (
                "ruby-zig/bigdecimal",
                "master",
                "A" * 40,
                "lowercase 40-character",
            ),
            (
                "ruby-zig/bigdecimal",
                "master",
                "a" * 64,
                "lowercase 40-character",
            ),
        )
        for repository, branch, sha, message in cases:
            with self.subTest(repository=repository, branch=branch, sha=sha):
                with self.assertRaisesRegex(planner.renderer.PlanError, message):
                    planner.plan_continuous(ROOT, repository, branch, sha)


if __name__ == "__main__":
    unittest.main()
