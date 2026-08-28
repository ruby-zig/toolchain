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
CERTIFIED_MASTER_SHA = "12e5584ddc3d05988390016e14556ab543765939"
CURRENT_MASTER_SHA = "7dec7a2aa38cf5458fe43cd036eda373b12b423d"
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

        self.assertEqual(adapter["upstream_sha"], CERTIFIED_MASTER_SHA)
        master = next(
            ref for ref in adapter["source_refs"] if ref["name"] == "master"
        )
        self.assertEqual(master["sha"], CURRENT_MASTER_SHA)
        self.assertEqual(master["status"], "run-verified-current")
        self.assertTrue(
            any(
                baseline["sha"] == CERTIFIED_MASTER_SHA
                and baseline["status"] == "run-verified-public-native"
                and baseline["workflow_run_id"] == 33095974872
                for baseline in master["validated_baselines"]
            )
        )
        self.assertTrue(
            any(
                baseline["sha"] == CERTIFIED_MASTER_SHA
                and baseline["status"] == "run-verified-cross-admitted"
                and baseline["rust"] is False
                for baseline in master["validated_baselines"]
            )
        )
        self.assertEqual(
            {
                candidate["profile"]
                for candidate in master["validated_candidates"]
                if candidate["sha"] == CURRENT_MASTER_SHA
                and candidate["status"] == "run-verified-continuous-candidate"
            },
            {"x86_64-linux-gnu.2.17", "x86_64-linux-musl"},
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
        self.assertEqual(musl["source_sha"], CERTIFIED_MASTER_SHA)
        self.assertEqual(musl["status"], "run-verified-admitted")
        self.assertEqual(
            adapter["cross_status"],
            "x86_64-linux-musl-run-verified-admitted",
        )
        self.assertIs(musl["rust"], False)

        cross = adapter["cross_validation"]
        self.assertEqual(cross["source_sha"], CERTIFIED_MASTER_SHA)
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

    def test_current_cruby_candidates_bind_public_evidence(self) -> None:
        adapter = json.loads(ADAPTER_METADATA.read_text(encoding="utf-8"))
        expected = {
            ("master", "x86_64-linux-gnu.2.17"): {
                "sha": CURRENT_MASTER_SHA,
                "run": 33138563961,
                "job": 98744080547,
                "artifact": 9673232343,
                "digest": "sha256:4177d19f19731c993dcdbbc704cb55c1c42ea455a767b32e276d38c966029edc",
                "provenance": "65386e35fb7211e4bdc236c4eb62e88bfad95d85fb70fb6887377e4d0d230304",
                "trace": "462199382c4132d10c781f5abab34b1bd5f2394bda56195813a9b74135e9b812",
                "receipts": "cd19e1dfef6babf331c2c9f491e93df455182f4578cedf3b0aa1570b718d017a",
                "receipt_count": 1585,
                "bootstrap": 2066,
            },
            ("master", "x86_64-linux-musl"): {
                "sha": CURRENT_MASTER_SHA,
                "run": 33138563961,
                "job": 98744081193,
                "artifact": 9673217819,
                "digest": "sha256:584d1afad004a00b16c72574f4f4177e993e807fa27a288beae0ff10ddd50ddf",
                "provenance": "5c55c0bd6ecd13dcedd12a45ec4e04f1e981e4effe9b93f584ea1a0c17a6ea07",
                "trace": "ddb5c5e5de37737ed9c6775ea23fd5602f683ff6353354a2aab64c8ea15dbf5a",
                "receipts": "0c6e5aeee99d87ed7b16394b90caa7d8e49790370340bb794d8dc7da17657a01",
                "receipt_count": 1508,
                "bootstrap": 2066,
            },
            ("ruby_3_4", "x86_64-linux-gnu.2.17"): {
                "sha": "8f3d12f70b2b775c1f228ca136361d18ec3f1e36",
                "run": 33138564818,
                "job": 98744078586,
                "artifact": 9673274182,
                "digest": "sha256:83c1e00d9558fb2ca0305d1235bfdb8108c6a521646db64c5454b9ebcfd299d0",
                "provenance": "76a95302e0028507b5c75f49cc9cdbfa596be55f759b936671a2351e531ef1df",
                "trace": "ddaf46c30a2adaf96b2664cfe94fed7bd4047f7d3de2f5d79d50ded546665b42",
                "receipts": "384291a1d07455448df077caeca5ee452d71ca3417d987f799af7e7ec608bdc0",
                "receipt_count": 1519,
                "bootstrap": 2022,
            },
            ("ruby_3_3", "x86_64-linux-gnu.2.17"): {
                "sha": "e675ccc096757021d6641ab3f10209a3df8b57a2",
                "run": 33138564979,
                "job": 98744076643,
                "artifact": 9673246062,
                "digest": "sha256:f53ec131b3be0c1336798b5fa92a62480553cbe5dd6b76ed72925966389d9729",
                "provenance": "3118fe91a5e975a0f475754821523e0c8527d0ead395c13dc45de473112c3209",
                "trace": "7ee066c5c99e779dc5742ba28368690c2a59acba2dfb618064d15a464613031d",
                "receipts": "d08d798aad7d03d1cd4c5aaaf95c913578c43809e9787c4de51961d436a6fe30",
                "receipt_count": 1539,
                "bootstrap": 1889,
            },
        }

        for (ref_name, profile), evidence in expected.items():
            with self.subTest(ref=ref_name, profile=profile):
                ref = next(item for item in adapter["source_refs"] if item["name"] == ref_name)
                self.assertEqual(ref["sha"], evidence["sha"])
                candidates = [
                    item
                    for item in ref["validated_candidates"]
                    if item["sha"] == evidence["sha"] and item["profile"] == profile
                ]
                self.assertEqual(len(candidates), 1)
                candidate = candidates[0]
                self.assertEqual(candidate["status"], "run-verified-continuous-candidate")
                self.assertEqual(
                    candidate["controller"]["commit"],
                    "d84bd12b565aa1c4c9b139e12e01774b4aaf8142",
                )
                self.assertEqual(candidate["workflow_run_id"], evidence["run"])
                self.assertEqual(candidate["workflow_job_id"], evidence["job"])
                self.assertEqual(candidate["artifact_id"], evidence["artifact"])
                self.assertEqual(candidate["artifact_digest"], evidence["digest"])
                self.assertEqual(candidate["provenance_sha256"], evidence["provenance"])
                self.assertEqual(candidate["trace_sha256"], evidence["trace"])
                self.assertEqual(candidate["receipts_sha256"], evidence["receipts"])
                self.assertEqual(candidate["receipt_count"], evidence["receipt_count"])
                self.assertEqual(candidate["tests"]["bootstrap"], evidence["bootstrap"])
                self.assertEqual(candidate["process_audit"], "passed")
                self.assertEqual(candidate["forbidden_processes"], 0)
                self.assertEqual(candidate["invalid_receipts"], 0)

if __name__ == "__main__":
    unittest.main()
