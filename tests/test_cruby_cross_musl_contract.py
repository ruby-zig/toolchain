from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUBY_ADAPTER = ROOT / "adapters" / "repo" / "ruby"
BUILD_SCRIPT = RUBY_ADAPTER / "build-musl.sh"
SOURCE_PATCH = RUBY_ADAPTER / "patches" / "cross-x86_64-linux-musl.patch"
ADAPTER_METADATA = RUBY_ADAPTER / "adapter.json"
FLEET_LOCK = ROOT / "config" / "fleet-lock.json"
MASTER_SHA = "12e5584ddc3d05988390016e14556ab543765939"
RUBY_4_0_BASELINE_SHA = "f3a72fe0a6d35583e215422e8887d3df0a1670b8"
RUBY_4_0_CURRENT_SHA = "2da9a6ef3f423fb85acfd5c41150bb22cdeb14ef"


class CrubyCrossMuslContractTests(unittest.TestCase):
    def test_build_separates_host_and_target_and_disables_rust(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('RZ_ZIG_TARGET" != x86_64-linux-musl', script)
        self.assertIn("export RZ_ZIG_HOST_TARGET=x86_64-linux-gnu.2.17", script)
        self.assertIn('"$build_tuple" != x86_64-pc-linux-gnu', script)
        self.assertIn('"$host_tuple" != x86_64-pc-linux-musl', script)
        self.assertIn('"$build_tuple" == "$host_tuple"', script)
        for variable in (
            "BUILD_CC",
            "BUILD_CXX",
            "CC_FOR_BUILD",
            "CXX_FOR_BUILD",
            "AR_FOR_BUILD",
            "RANLIB_FOR_BUILD",
        ):
            self.assertIn(variable, script)

        self.assertIn("--disable-yjit", script)
        self.assertIn("--disable-zjit", script)
        self.assertIn("RUSTC=no", script)
        self.assertIn("CRuby cross compilation does not support rustc", script)
        self.assertIn("CRuby musl lane unexpectedly invoked Rust", script)

    def test_build_is_static_and_run_verified(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn("--disable-shared", script)
        self.assertIn("--with-static-linked-ext", script)
        self.assertIn("--with-out-ext='*fiddle*,*win32ole*,openssl,psych,zlib'", script)
        self.assertIn("export JSON_DISABLE_SIMD=1", script)
        self.assertIn("statically linked", script)
        self.assertIn("unexpectedly has a program interpreter", script)
        self.assertIn("unexpectedly has dynamic dependencies", script)
        self.assertIn("unexpectedly has a glibc symbol-version dependency", script)
        self.assertIn("btest-bruby", script)
        self.assertIn("basictest/test.rb", script)
        self.assertIn("static musl extension smoke passed", script)
        self.assertIn("distinct GNU host and musl target transformations", script)

    def test_source_patch_covers_all_observed_upstream_blockers(self) -> None:
        patch = SOURCE_PATCH.read_text(encoding="utf-8")

        self.assertIn("diff --git a/tool/dump_ast.mkmf.rb", patch)
        self.assertIn("workdir = Pathname(workdir).expand_path", patch)
        self.assertIn("diff --git a/common.mk", patch)
        self.assertIn('CC="$(BUILD_CC)"', patch)
        self.assertIn('CXX="$(BUILD_CXX)"', patch)
        self.assertIn('AR="$(AR_FOR_BUILD)"', patch)
        self.assertIn("diff --git a/thread_pthread.c", patch)
        self.assertIn("rlim.rlim_cur != RLIM_INFINITY", patch)
        self.assertIn("size = (size_t)rlim.rlim_cur", patch)
        self.assertIn("diff --git a/tool/m4/ruby_prog_gnu_ld.m4", patch)
        self.assertIn('$LD -v 2>&1 | grep "GNU ld"', patch)

    def test_metadata_records_current_master_and_admitted_lane(self) -> None:
        adapter = json.loads(ADAPTER_METADATA.read_text(encoding="utf-8"))

        self.assertEqual(adapter["upstream_sha"], MASTER_SHA)
        master = next(
            ref for ref in adapter["source_refs"] if ref["name"] == "master"
        )
        self.assertEqual(master["sha"], MASTER_SHA)
        self.assertEqual(master["status"], "run-verified-current")
        self.assertTrue(
            any(
                baseline["sha"] == MASTER_SHA
                and baseline["status"] == "run-verified-public-native"
                and baseline["workflow_run_id"] == 33095974872
                for baseline in master["validated_baselines"]
            )
        )
        self.assertTrue(
            any(
                baseline["sha"] == MASTER_SHA
                and baseline["status"] == "run-verified-cross-admitted"
                and baseline["rust"] is False
                for baseline in master["validated_baselines"]
            )
        )

        ruby_4_0 = next(
            ref for ref in adapter["source_refs"] if ref["name"] == "ruby_4_0"
        )
        self.assertEqual(ruby_4_0["sha"], RUBY_4_0_BASELINE_SHA)
        self.assertEqual(ruby_4_0["status"], "run-verified-shared-native")
        self.assertTrue(
            any(
                candidate["sha"] == RUBY_4_0_CURRENT_SHA
                and candidate["status"] == "run-verified-continuous-candidate"
                for candidate in ruby_4_0["validated_candidates"]
            )
        )

        gnu = next(
            profile
            for profile in adapter["profiles"]
            if profile["id"] == "x86_64-linux-gnu.2.17"
        )
        self.assertEqual(
            gnu["source_sha"], "89d3b11eace35b8e279b970b4ff5125f171d0d4b"
        )
        musl = next(
            profile
            for profile in adapter["profiles"]
            if profile["id"] == "x86_64-linux-musl"
        )
        self.assertEqual(musl["source_sha"], MASTER_SHA)
        self.assertEqual(musl["status"], "run-verified-admitted")
        self.assertEqual(
            adapter["cross_status"],
            "x86_64-linux-musl-run-verified-admitted",
        )
        self.assertIs(musl["rust"], False)

        cross = adapter["cross_validation"]
        self.assertEqual(cross["source_sha"], MASTER_SHA)
        self.assertEqual(cross["profile"], "x86_64-linux-musl")
        self.assertEqual(cross["process_audit"], "passed")
        self.assertEqual(cross["receipt_count"], 1507)
        self.assertEqual(
            cross["trace_sha256"],
            "422393b1792bbf25440d3d6374c3297f946feaaf5ca907a8b6d6c9e936561fa8",
        )
        self.assertEqual(
            cross["receipts_sha256"],
            "b9acc6ce758bab15ef6e4c24a2b5a050110503fb81a75b45fe3e111eae89621f",
        )

        lock = json.loads(FLEET_LOCK.read_text(encoding="utf-8"))
        locked = next(
            source
            for source in lock["sources"]
            if source["result_id"] == "ruby-master"
        )
        self.assertEqual(
            locked["source_ref"],
            "89d3b11eace35b8e279b970b4ff5125f171d0d4b",
        )
        self.assertEqual(locked["build_script"], "adapters/repo/ruby/build.sh")
        self.assertTrue(locked["rust"])
        self.assertEqual(
            locked["profiles"],
            ["x86_64-linux-gnu.2.17", "x86_64-linux-musl"],
        )
        self.assertEqual(
            locked["profile_overrides"]["x86_64-linux-musl"],
            {
                "build_script": "adapters/repo/ruby/build-musl.sh",
                "rust": False,
            },
        )

if __name__ == "__main__":
    unittest.main()
