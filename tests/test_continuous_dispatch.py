from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
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

    def test_date_derives_its_locked_gnu_lane(self) -> None:
        candidate = "f" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/date", "master", candidate
        )

        self.assertEqual(plan.result_id, "date-master")
        self.assertEqual(plan.upstream_repository, "ruby/date")
        self.assertEqual(
            plan.baseline_sha, "afb25b87590fd5b2f23f07fd851f06a31fa19288"
        )
        self.assertEqual(plan.adapter_id, "repo/date")
        self.assertEqual(plan.build_script, "adapters/repo/date/build.sh")
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertFalse(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)
        entry = plan.matrix["include"][0]
        self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
        self.assertEqual(entry["source_ref"], candidate)
        self.assertEqual(entry["source_ref_name"], "master")

    def test_io_console_derives_locked_gnu_pty_lane(self) -> None:
        candidate = "b" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/io-console", "master", candidate
        )

        self.assertEqual(plan.result_id, "io-console-master")
        self.assertEqual(plan.upstream_repository, "ruby/io-console")
        self.assertEqual(
            plan.baseline_sha, "deb5c1ffc4e22bb7e9c28f5534e0d81e5cdc2015"
        )
        self.assertEqual(plan.adapter_id, "repo/io-console")
        self.assertEqual(
            plan.build_script, "adapters/repo/io-console/build.sh"
        )
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertFalse(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)
        entry = plan.matrix["include"][0]
        self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
        self.assertEqual(entry["source_ref"], candidate)
        self.assertEqual(entry["source_ref_name"], "master")
        self.assertFalse(entry["rust"])

    def test_io_family_derives_locked_gnu_lanes(self) -> None:
        candidate = "7" * 40
        cases = {
            "fcntl": "43347f8b6b0f5ef13997182bb9a703e0c072d101",
            "io-nonblock": "04ae796039e3c90b4e09af61128fc27e44120c86",
            "io-wait": "2a8d689fdaeae482cf97d18722a5c8fb8b5c1aeb",
        }

        for name, baseline in cases.items():
            with self.subTest(name=name):
                plan = planner.plan_continuous(
                    ROOT, f"ruby-zig/{name}", "master", candidate
                )

                self.assertEqual(plan.result_id, f"{name}-master")
                self.assertEqual(plan.upstream_repository, f"ruby/{name}")
                self.assertEqual(plan.baseline_sha, baseline)
                self.assertEqual(plan.adapter_id, f"repo/{name}")
                self.assertEqual(
                    plan.build_script, f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(plan.ruby_version, "3.2.3")
                self.assertFalse(plan.rust)
                self.assertEqual(plan.ready_jobs, 1)
                entry = plan.matrix["include"][0]
                self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(entry["repository"], f"ruby-zig/{name}")
                self.assertEqual(entry["source_ref"], candidate)
                self.assertEqual(entry["source_ref_name"], "master")
                self.assertFalse(entry["rust"])

    def test_six_lane_admission_derives_locked_gnu_lanes(self) -> None:
        candidate = "6" * 40
        baselines = {
            "cgi": "7f08c896d3fb726584e50172ebe8ddb6f3379b75",
            "erb": "9907393a1f1dfc027e8e7f2a9f5fcc7c60632762",
            "pathname": "f0217bbd486b2f7d5c7de1ff3951c7422d42c761",
            "racc": "4d858d91239b5c26b0308d362a9e96d43190674a",
            "sdbm": "7b0c143d6dc970b3e5d897e36876be5ec9e15889",
            "syslog": "6d3616575bc81a09182144c17c303e46f4d2ef9f",
        }

        for name, baseline in baselines.items():
            with self.subTest(name=name):
                plan = planner.plan_continuous(
                    ROOT, f"ruby-zig/{name}", "master", candidate
                )

                self.assertEqual(plan.result_id, f"{name}-master")
                self.assertEqual(plan.upstream_repository, f"ruby/{name}")
                self.assertEqual(plan.baseline_sha, baseline)
                self.assertEqual(plan.adapter_id, f"repo/{name}")
                self.assertEqual(
                    plan.build_script, f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(plan.ruby_version, "3.2.3")
                self.assertFalse(plan.rust)
                self.assertEqual(plan.ready_jobs, 1)

                self.assertEqual(len(plan.matrix["include"]), 1)
                entry = plan.matrix["include"][0]
                self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(entry["repository"], f"ruby-zig/{name}")
                self.assertEqual(entry["source_ref"], candidate)
                self.assertEqual(entry["source_ref_name"], "master")
                self.assertEqual(entry["ruby_version"], "3.2.3")
                self.assertFalse(entry["rust"])

    def test_four_lane_admission_derives_locked_gnu_lanes(self) -> None:
        candidate = "5" * 40
        baselines = {
            "etc": "9ad32f8c8e199f34ae01e38bd647ab7e30a72406",
            "iconv": "07cceadf29439d5070b2be62ea644ca01fa7f940",
            "nkf": "0cbafd2db231e331ac8f10e77ef406c71e3b9fbe",
            "syck": "0b76192bc3b8cd5dfe814e1166265ab38d82e41b",
        }

        for name, baseline in baselines.items():
            with self.subTest(name=name):
                plan = planner.plan_continuous(
                    ROOT, f"ruby-zig/{name}", "master", candidate
                )

                self.assertEqual(plan.result_id, f"{name}-master")
                self.assertEqual(plan.upstream_repository, f"ruby/{name}")
                self.assertEqual(plan.baseline_sha, baseline)
                self.assertEqual(plan.adapter_id, f"repo/{name}")
                self.assertEqual(
                    plan.build_script, f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(plan.ruby_version, "3.2.3")
                self.assertFalse(plan.rust)
                self.assertEqual(plan.ready_jobs, 1)

                self.assertEqual(len(plan.matrix["include"]), 1)
                entry = plan.matrix["include"][0]
                self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(entry["repository"], f"ruby-zig/{name}")
                self.assertEqual(entry["source_ref"], candidate)
                self.assertEqual(entry["source_ref_name"], "master")
                self.assertEqual(entry["ruby_version"], "3.2.3")
                self.assertFalse(entry["rust"])

    def test_debug_fiddle_and_zlib_admission_derives_locked_gnu_lanes(self) -> None:
        candidate = "6" * 40
        baselines = {
            "debug": "6510cfbc7496c55ebbefa437a25c17ca58f7c5eb",
            "fiddle": "195c8d133bb8e225f27ba54f1bc476b8d488e217",
            "zlib": "c87e5ed1403144010b00ff1787e860e5d084511b",
        }

        for name, baseline in baselines.items():
            with self.subTest(name=name):
                plan = planner.plan_continuous(
                    ROOT, f"ruby-zig/{name}", "master", candidate
                )
                self.assertEqual(plan.result_id, f"{name}-master")
                self.assertEqual(plan.upstream_repository, f"ruby/{name}")
                self.assertEqual(plan.baseline_sha, baseline)
                self.assertEqual(plan.adapter_id, f"repo/{name}")
                self.assertEqual(
                    plan.build_script, f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(plan.ruby_version, "3.2.3")
                self.assertFalse(plan.rust)
                self.assertEqual(plan.ready_jobs, 1)

                self.assertEqual(len(plan.matrix["include"]), 1)
                entry = plan.matrix["include"][0]
                self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(entry["repository"], f"ruby-zig/{name}")
                self.assertEqual(entry["source_ref"], candidate)
                self.assertEqual(entry["source_ref_name"], "master")
                self.assertEqual(entry["ruby_version"], "3.2.3")
                self.assertFalse(entry["rust"])

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
        self.assertEqual(plan.ready_jobs, 2)
        entries = {
            entry["profile_id"]: entry for entry in plan.matrix["include"]
        }

        gnu = entries["x86_64-linux-gnu.2.17"]
        self.assertEqual(gnu["build_script"], "adapters/repo/ruby/build.sh")
        self.assertEqual(gnu["source_ref"], candidate)
        self.assertEqual(gnu["source_ref_name"], "master")
        self.assertTrue(gnu["rust"])

        musl = entries["x86_64-linux-musl"]
        self.assertEqual(
            musl["build_script"], "adapters/repo/ruby/build-musl.sh"
        )
        self.assertEqual(musl["source_ref"], candidate)
        self.assertEqual(musl["source_ref_name"], "master")
        self.assertFalse(musl["rust"])

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

    def test_cruby_3_4_uses_dynamic_candidate_with_locked_gnu_contract(self) -> None:
        candidate = "1" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/ruby", "ruby_3_4", candidate
        )

        self.assertEqual(plan.result_id, "ruby-ruby_3_4")
        self.assertEqual(
            plan.baseline_sha, "aac3e36dd4bee40fc89893209553903706fa5666"
        )
        self.assertEqual(plan.adapter_id, "repo/ruby")
        self.assertEqual(plan.build_script, "adapters/repo/ruby/build.sh")
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertTrue(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)
        entry = plan.matrix["include"][0]
        self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
        self.assertEqual(entry["source_ref"], candidate)
        self.assertEqual(entry["source_ref_name"], "ruby_3_4")

    def test_cruby_3_3_uses_dynamic_candidate_with_locked_gnu_contract(self) -> None:
        candidate = "2" * 40
        plan = planner.plan_continuous(
            ROOT, "ruby-zig/ruby", "ruby_3_3", candidate
        )

        self.assertEqual(plan.result_id, "ruby-ruby_3_3")
        self.assertEqual(
            plan.baseline_sha, "0581089df9f0af0fe6b64cb8167987c211100947"
        )
        self.assertEqual(plan.adapter_id, "repo/ruby")
        self.assertEqual(plan.build_script, "adapters/repo/ruby/build.sh")
        self.assertEqual(plan.ruby_version, "3.2.3")
        self.assertTrue(plan.rust)
        self.assertEqual(plan.ready_jobs, 1)
        entry = plan.matrix["include"][0]
        self.assertEqual(entry["profile_id"], "x86_64-linux-gnu.2.17")
        self.assertEqual(entry["source_ref"], candidate)
        self.assertEqual(entry["source_ref_name"], "ruby_3_3")

    def test_profile_overrides_reach_continuous_matrix_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config").mkdir()
            adapter = root / "adapters" / "repo" / "native"
            adapter.mkdir(parents=True)
            for script in ("build.sh", "build-musl.sh"):
                (adapter / script).write_text("#!/usr/bin/env bash\n", encoding="utf-8")

            builds = {
                "count": 1,
                "profile_count": 2,
                "builds": [
                    {
                        "name": "native",
                        "upstream": "ruby/native",
                        "default_branch": "master",
                        "classification": "direct-native",
                        "adapter_id": "repo/native",
                        "adapter_status": "ready",
                        "profile_policy": "zig-build-only",
                    }
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
                        "rust_link_status": "smoke-verified",
                    },
                ]
            }
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
                    }
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
                            "x86_64-linux-musl",
                        ],
                        "ruby_version": "3.3.6",
                        "rust": True,
                        "profile_overrides": {
                            "x86_64-linux-musl": {
                                "build_script": "adapters/repo/native/build-musl.sh",
                                "rust": False,
                            }
                        },
                    }
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

            plan = planner.plan_continuous(
                root, "ruby-zig/native", "master", "b" * 40
            )
            self.assertEqual(plan.build_script, "adapters/repo/native/build.sh")
            self.assertTrue(plan.rust)
            entries = {
                entry["profile_id"]: entry for entry in plan.matrix["include"]
            }
            self.assertEqual(
                entries["x86_64-linux-gnu.2.17"]["build_script"],
                "adapters/repo/native/build.sh",
            )
            self.assertTrue(entries["x86_64-linux-gnu.2.17"]["rust"])
            self.assertEqual(
                entries["x86_64-linux-musl"]["build_script"],
                "adapters/repo/native/build-musl.sh",
            )
            self.assertFalse(entries["x86_64-linux-musl"]["rust"])
            summary = plan.summary()
            self.assertIn("Default Rust boundary | `enabled`", summary)
            self.assertIn("`x86_64-linux-musl`", summary)
            self.assertIn(
                "`adapters/repo/native/build-musl.sh` | `disabled`",
                summary,
            )

            targets["profiles"][1]["rust_link_status"] = "unverified"
            lock["sources"][0]["profile_overrides"][
                "x86_64-linux-musl"
            ]["rust"] = True
            (root / "config" / "targets.json").write_text(
                json.dumps(targets), encoding="utf-8"
            )
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(lock), encoding="utf-8"
            )
            with self.assertRaisesRegex(
                planner.renderer.PlanError,
                "only smoke-verified profiles may enable Rust",
            ):
                planner.plan_continuous(
                    root, "ruby-zig/native", "master", "c" * 40
                )

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
