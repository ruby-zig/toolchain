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
    "ruby_3_2": "5483bfc1ae5725e871cbbddf313626fbb0f2dbb8",
}

# Refs admitted to the executable lock whose first certified run has not
# happened yet: their adapter evidence records carry candidate-* statuses
# until real receipts replace them.
CRUBY_PENDING_FIRST_RUN = {"ruby_3_2"}


class FleetMatrixTests(unittest.TestCase):
    def test_current_workload_is_branch_aware_affected_native_fleet(self) -> None:
        plan = renderer.plan_fleet(ROOT)

        self.assertEqual(plan.discovery_repositories, 190)
        self.assertEqual(plan.fleet_repositories, 39)
        self.assertEqual(plan.source_identities, 43)
        self.assertEqual(plan.maximum_jobs, 387)
        self.assertEqual(plan.desired_jobs, 387)
        self.assertEqual(sum(lane.ready for lane in plan.lanes), 31)
        self.assertEqual(sum(not lane.ready for lane in plan.lanes), 356)
        self.assertEqual(plan.active_shards, 2)
        self.assertEqual(plan.shard_count, 2)
        self.assertEqual(
            [len(renderer.shard_lanes(plan, shard)) for shard in range(1, 3)],
            [252, 135],
        )
        self.assertEqual(
            {lane.classification for lane in plan.lanes},
            {"direct-native", "native-test"},
        )

        ruby_lanes = [lane for lane in plan.lanes if lane.name == "ruby"]
        self.assertEqual(len(ruby_lanes), 45)
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
                "ruby-ruby_3_2",
            },
        )
        self.assertEqual(
            {
                ref_name: len(
                    [lane for lane in ruby_lanes if lane.ref_name == ref_name]
                )
                for ref_name in CRUBY_REFS
            },
            {
                "master": 9,
                "ruby_4_0": 9,
                "ruby_3_4": 9,
                "ruby_3_3": 9,
                "ruby_3_2": 9,
            },
        )
        ready_ruby = [lane for lane in ruby_lanes if lane.ready]
        self.assertEqual(len(ready_ruby), 6)
        self.assertEqual(
            {(lane.ref_name, lane.profile["id"]) for lane in ready_ruby},
            {
                ("master", "x86_64-linux-gnu.2.17"),
                ("master", "x86_64-linux-musl"),
                ("ruby_4_0", "x86_64-linux-gnu.2.17"),
                ("ruby_3_4", "x86_64-linux-gnu.2.17"),
                ("ruby_3_3", "x86_64-linux-gnu.2.17"),
                ("ruby_3_2", "x86_64-linux-gnu.2.17"),
            },
        )

        lock = json.loads((ROOT / "config" / "fleet-lock.json").read_text())
        actual_refs = {
            entry["ref_name"]: entry["source_ref"]
            for entry in lock["source_refs"]
            if entry["name"] == "ruby"
        }
        self.assertEqual(actual_refs, CRUBY_REFS)
        self.assertNotIn("ruby_3_1", actual_refs)
        self.assertEqual(len(lock["sources"]), 29)
        self.assertEqual(
            {source["name"] for source in lock["sources"]},
            {
                "bigdecimal",
                "cgi",
                "date",
                "debug",
                "digest",
                "etc",
                "erb",
                "fcntl",
                "fiddle",
                "iconv",
                "io-console",
                "io-nonblock",
                "io-wait",
                "json",
                "nkf",
                "pathname",
                "prism",
                "racc",
                "ruby",
                "sdbm",
                "stringio",
                "strscan",
                "syck",
                "syslog",
                "zlib",
            },
        )
        self.assertEqual(
            {source["name"]: source["profiles"] for source in lock["sources"]},
            {
                "bigdecimal": ["x86_64-linux-gnu.2.17"],
                "cgi": ["x86_64-linux-gnu.2.17"],
                "date": ["x86_64-linux-gnu.2.17"],
                "debug": ["x86_64-linux-gnu.2.17"],
                "digest": ["x86_64-linux-gnu.2.17"],
                "etc": ["x86_64-linux-gnu.2.17"],
                "erb": ["x86_64-linux-gnu.2.17"],
                "fcntl": ["x86_64-linux-gnu.2.17"],
                "fiddle": ["x86_64-linux-gnu.2.17"],
                "iconv": ["x86_64-linux-gnu.2.17"],
                "io-console": ["x86_64-linux-gnu.2.17"],
                "io-nonblock": ["x86_64-linux-gnu.2.17"],
                "io-wait": ["x86_64-linux-gnu.2.17"],
                "json": ["x86_64-linux-gnu.2.17"],
                "nkf": ["x86_64-linux-gnu.2.17"],
                "pathname": ["x86_64-linux-gnu.2.17"],
                "prism": [
                    "x86_64-linux-gnu.2.17",
                    "x86_64-linux-musl",
                ],
                "racc": ["x86_64-linux-gnu.2.17"],
                "ruby": ["x86_64-linux-gnu.2.17"],
                "sdbm": ["x86_64-linux-gnu.2.17"],
                "stringio": ["x86_64-linux-gnu.2.17"],
                "strscan": ["x86_64-linux-gnu.2.17"],
                "syck": ["x86_64-linux-gnu.2.17"],
                "syslog": ["x86_64-linux-gnu.2.17"],
                "zlib": ["x86_64-linux-gnu.2.17"],
            },
        )
        self.assertTrue(
            all(source["ruby_version"] == "3.2.3" for source in lock["sources"])
        )
        date_source = next(
            source for source in lock["sources"] if source["name"] == "date"
        )
        self.assertEqual(
            date_source["source_ref"],
            "afb25b87590fd5b2f23f07fd851f06a31fa19288",
        )
        self.assertFalse(date_source["rust"])
        ruby_source = next(
            source for source in lock["sources"] if source["name"] == "ruby"
        )
        self.assertEqual(
            ruby_source["source_ref"],
            "89d3b11eace35b8e279b970b4ff5125f171d0d4b",
        )
        self.assertTrue(ruby_source["rust"])
        ruby_release_source = next(
            source
            for source in lock["sources"]
            if source["result_id"] == "ruby-ruby_4_0"
        )
        self.assertEqual(
            ruby_release_source["source_ref"],
            "f3a72fe0a6d35583e215422e8887d3df0a1670b8",
        )
        self.assertEqual(
            ruby_release_source["profiles"], ["x86_64-linux-gnu.2.17"]
        )
        self.assertTrue(ruby_release_source["rust"])
        ruby_source_locks = {
            source["ref_name"]: source
            for source in lock["sources"]
            if source["name"] == "ruby"
        }
        self.assertEqual(
            {name: source["source_ref"] for name, source in ruby_source_locks.items()},
            CRUBY_REFS,
        )
        master_source = ruby_source_locks["master"]
        self.assertEqual(
            master_source["profiles"],
            ["x86_64-linux-gnu.2.17", "x86_64-linux-musl"],
        )
        self.assertEqual(master_source["ruby_version"], "3.2.3")
        self.assertTrue(master_source["rust"])
        self.assertEqual(
            master_source["profile_overrides"]["x86_64-linux-musl"],
            {
                "build_script": "adapters/repo/ruby/build-musl.sh",
                "rust": False,
            },
        )
        self.assertTrue(
            all(
                source["profiles"] == ["x86_64-linux-gnu.2.17"]
                and source["ruby_version"] == "3.2.3"
                and source["rust"]
                and "profile_overrides" not in source
                for name, source in ruby_source_locks.items()
                if name != "master"
            )
        )
        io_console_source = next(
            source for source in lock["sources"] if source["name"] == "io-console"
        )
        self.assertEqual(
            io_console_source["source_ref"],
            "deb5c1ffc4e22bb7e9c28f5534e0d81e5cdc2015",
        )
        self.assertFalse(io_console_source["rust"])
        io_console_adapter = json.loads(
            (ROOT / "adapters" / "repo" / "io-console" / "adapter.json").read_text()
        )
        self.assertEqual(
            [profile["id"] for profile in io_console_adapter["profiles"]],
            ["x86_64-linux-gnu.2.17"],
        )
        io_console_gnu = io_console_adapter["profiles"][0]
        self.assertEqual(io_console_gnu["status"], "run-verified")
        self.assertEqual(
            io_console_gnu["controller_sha"],
            "72fd9634e1c303ce4efd936358d429b84e6966f9",
        )
        self.assertEqual(
            io_console_gnu["trace_sha256"],
            "d7cf1a8a137b39dd7fbba14a5a6ee3ea7de6ac434f58a0afd66d697b965cdfec",
        )
        self.assertEqual(
            io_console_gnu["receipts_sha256"],
            "fd3d5d9f33c2a1d4df6f2af0a583deabd031174b3ff4875abed2ff9acb1bbff9",
        )
        self.assertEqual(io_console_gnu["native_receipts"], 22)
        self.assertEqual(io_console_gnu["receipt_operations"], {"compile": 6, "link": 16})
        self.assertEqual(
            io_console_gnu["artifact_sha256"],
            "e9342aeddba338ab96e3a44ba708742e213d6ffeda2c27572be8a9e00bc1f1b6",
        )
        self.assertEqual(
            io_console_adapter["cross_status"],
            "pending-target-native-ruby-sdks-and-runtimes",
        )
        io_family_evidence = {
            "fcntl": {
                "source_ref": "43347f8b6b0f5ef13997182bb9a703e0c072d101",
                "trace_sha256": "936a9ddf9524308a67a1f2cd94756240b5178f75825111081898ca2f342ad4a5",
                "receipts_sha256": "9a1bb4375fe212e964962d771911a6b889c7d403b3281d3b24d0c19736105b9c",
                "native_receipts": 2,
                "receipt_tools": {"cc": 1, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 1},
                "artifact_sha256": "e58edbb2b1764e6592245c6bf58b8b0a90f05ea6d6e2b9cdc44717ea37027c1a",
            },
            "io-nonblock": {
                "source_ref": "04ae796039e3c90b4e09af61128fc27e44120c86",
                "trace_sha256": "f6486211aad9d14ea7c7648ce28d08041e20fb04821a3e603a1d6333cee44809",
                "receipts_sha256": "2fb7d9203f42209bd5b9b62e74b32dcb57c433e4d02e1c6e905c3683d9762f87",
                "native_receipts": 6,
                "receipt_tools": {"cc": 5, "shared": 1},
                "receipt_operations": {"compile": 3, "link": 3},
                "artifact_sha256": "bde16205d7f812284a47aff33fb09e54b78fb30c5d8dd8c2f67ed38aaa28619f",
            },
            "io-wait": {
                "source_ref": "2a8d689fdaeae482cf97d18722a5c8fb8b5c1aeb",
                "trace_sha256": "5ed049b07e9992e0b2464cce5f7d17cf23e5cf74c1d0f5b3457b2f03bbc29c60",
                "receipts_sha256": "bf7615d69c584bc645d9be93617c9a96c84012de336b4b8fbe96e7d965707617",
                "native_receipts": 2,
                "receipt_tools": {"cc": 1, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 1},
                "artifact_sha256": "8b41ca09d682f744caa60f3924bfb3dd3d84ba04caa9de03c6ec6f8217bbb65e",
            },
        }
        for name, expected in io_family_evidence.items():
            with self.subTest(name=name):
                source = next(
                    item for item in lock["sources"] if item["name"] == name
                )
                self.assertEqual(source["result_id"], f"{name}-master")
                self.assertEqual(source["repository"], f"ruby-zig/{name}")
                self.assertEqual(source["source_ref"], expected["source_ref"])
                self.assertEqual(source["adapter_id"], f"repo/{name}")
                self.assertEqual(
                    source["build_script"], f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(source["profiles"], ["x86_64-linux-gnu.2.17"])
                self.assertFalse(source["rust"])

                adapter = json.loads(
                    (ROOT / "adapters" / "repo" / name / "adapter.json").read_text()
                )
                self.assertEqual(adapter["upstream_sha"], expected["source_ref"])
                self.assertEqual(
                    adapter["cross_status"],
                    "pending-target-native-ruby-sdks-and-runtimes",
                )
                self.assertEqual(len(adapter["profiles"]), 1)
                profile = adapter["profiles"][0]
                self.assertEqual(profile["id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(profile["status"], "run-verified")
                self.assertEqual(
                    profile["controller_sha"],
                    "5db6238471472e7cdf72c9743916eebf7cdbfbd6",
                )
                for key in (
                    "trace_sha256",
                    "receipts_sha256",
                    "native_receipts",
                    "receipt_tools",
                    "receipt_operations",
                    "artifact_sha256",
                ):
                    self.assertEqual(profile[key], expected[key])
                self.assertEqual(
                    profile["evidence_archive"],
                    "ruby-zig-io-family-cert-5db6238-r3-evidence.tar.xz",
                )
                self.assertEqual(
                    profile["evidence_sha256"],
                    "5ecf9b08ade03280548aea913c9b4134147a188b0e5800b01efd9518200fb61c",
                )
                self.assertEqual(adapter["validation"]["process_audit"], "passed")
                self.assertEqual(
                    adapter["validation"]["foreign_compiler_linker_invocations"],
                    0,
                )
                self.assertTrue(adapter["validation"]["source_clean_after_build"])

        six_lane_evidence = {
            "cgi": {
                "source_ref": "7f08c896d3fb726584e50172ebe8ddb6f3379b75",
                "trace_sha256": "0ba20f37ee536e73ec4f2c1491d3b87ad00fb4d995181a2eaeb02acb5599a1c9",
                "receipts_sha256": "90c46676ea60b915ea2dd6bd3f62138f03eb690c336f9bd5002cc51af77d5e9c",
                "native_receipts": 2,
                "receipt_tools": {"cc": 1, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 1},
                "artifact_sha256": "bc80469f655009b55545422bee32b680a6179f80ec270615d3e7df80e87fa7af",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 2,
                "exported_entrypoint": "Init_escape",
            },
            "erb": {
                "source_ref": "9907393a1f1dfc027e8e7f2a9f5fcc7c60632762",
                "trace_sha256": "5abdcf0c2cab165c46e5c6ca19ca0a35ce488aacc8ad73b03aeea53f24938969",
                "receipts_sha256": "fa316bfd4ab2017cbe43ab15f628cc9c4e27272adc664a7d6925160ace000d8c",
                "native_receipts": 4,
                "receipt_tools": {"cc": 3, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 3},
                "artifact_sha256": "be53e511993dc32786fe0f8c4995433b4db7525318fad7be4567d583f638804b",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 1,
                "exported_entrypoint": "Init_escape",
            },
            "pathname": {
                "source_ref": "f0217bbd486b2f7d5c7de1ff3951c7422d42c761",
                "trace_sha256": "a63d6d0e32c85f765cead5c5beb127b2ed399b70b213c853e79ec94e1112c307",
                "receipts_sha256": "406298f07ded64e4e8f4de7ebed6b9b498fb97939e72c486ee48f93af977dec8",
                "native_receipts": 2,
                "receipt_tools": {"cc": 1, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 1},
                "artifact_sha256": "305e27e10491a20607e9da20f91b252d4b026748a3ea5cc93641d668b5467bd1",
                "glibc_max": "none",
                "glibc_version_dependencies": 0,
                "exported_entrypoint": "Init_pathname",
            },
            "racc": {
                "source_ref": "4d858d91239b5c26b0308d362a9e96d43190674a",
                "trace_sha256": "cd16031e2120d1b22154104f972781ce561e5e8bb08df055ccb6c76e3984e694",
                "receipts_sha256": "06dbf686bd18efac1808a180311a3e379c3d50ff4da32edb8ae8dc9f0990b03e",
                "native_receipts": 2,
                "receipt_tools": {"cc": 1, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 1},
                "artifact_sha256": "43f23a180de53af61fd9d0cbe4d4f44b5a7c0c506ab05fc464fa1658dff6387d",
                "glibc_max": "none",
                "glibc_version_dependencies": 0,
                "exported_entrypoint": "Init_cparse",
            },
            "sdbm": {
                "source_ref": "7b0c143d6dc970b3e5d897e36876be5ec9e15889",
                "trace_sha256": "793da0cea24ec3662feb30af1ab9471b384486939e0bb0f4cfc87b2e311891b7",
                "receipts_sha256": "f2afc2048422ac47e683e11ce8baaa2d9dce5ca52949ea422c9f06b17f240f68",
                "native_receipts": 3,
                "receipt_tools": {"cc": 2, "shared": 1},
                "receipt_operations": {"compile": 2, "link": 1},
                "artifact_sha256": "0b0e22ba5dfbd277e08a589fc305f8edbdd51551c2ffd7aba10a43d87b95ee46",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 2,
                "exported_entrypoint": "Init_sdbm",
            },
            "syslog": {
                "source_ref": "6d3616575bc81a09182144c17c303e46f4d2ef9f",
                "trace_sha256": "0c2368da28a74ed3436fa95f46c8142fc457a0847e6f34f490f6e1cc8797267b",
                "receipts_sha256": "3a48b66413af8969f194122701109208cbdcf96c3d20ba9ff68236c52e241c22",
                "native_receipts": 9,
                "receipt_tools": {"cc": 8, "shared": 1},
                "receipt_operations": {"compile": 2, "link": 7},
                "artifact_sha256": "e4f7185a8d8a8a012b6cbb77780d7876a49372747f14b20e3d98ce7b00f08cf1",
                "glibc_max": "2.2.5",
                "glibc_version_dependencies": 1,
                "exported_entrypoint": "Init_syslog_ext",
            },
        }
        for name, expected in six_lane_evidence.items():
            with self.subTest(name=name):
                source = next(
                    item for item in lock["sources"] if item["name"] == name
                )
                self.assertEqual(source["result_id"], f"{name}-master")
                self.assertEqual(source["ref_name"], "master")
                self.assertEqual(source["repository"], f"ruby-zig/{name}")
                self.assertEqual(source["source_ref"], expected["source_ref"])
                self.assertEqual(source["adapter_id"], f"repo/{name}")
                self.assertEqual(
                    source["build_script"], f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(source["profiles"], ["x86_64-linux-gnu.2.17"])
                self.assertEqual(source["ruby_version"], "3.2.3")
                self.assertFalse(source["rust"])
                self.assertNotIn("profile_overrides", source)

                adapter = json.loads(
                    (ROOT / "adapters" / "repo" / name / "adapter.json").read_text()
                )
                self.assertEqual(adapter["repository"], f"ruby/{name}")
                self.assertEqual(adapter["upstream_sha"], expected["source_ref"])
                self.assertEqual(
                    adapter["cross_status"],
                    "pending-target-native-ruby-sdks-and-runtimes",
                )
                self.assertEqual(len(adapter["profiles"]), 1)
                profile = adapter["profiles"][0]
                self.assertEqual(profile["id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(profile["status"], "run-verified")
                self.assertEqual(
                    profile["controller_sha"],
                    "7be741277cd2f8dacc91116e5d51219593dfe9e8",
                )
                for key in (
                    "trace_sha256",
                    "receipts_sha256",
                    "native_receipts",
                    "receipt_tools",
                    "receipt_operations",
                    "artifact_sha256",
                    "glibc_max",
                    "glibc_version_dependencies",
                ):
                    self.assertEqual(profile[key], expected[key])
                self.assertEqual(
                    profile["evidence_archive"],
                    "ruby-zig-six-adapter-cert-7be7412-evidence.tar.xz",
                )
                self.assertEqual(
                    profile["evidence_sha256"],
                    "83b42a7d5fc24c86e52c028d4d8cedd95149df6c75b095c4a0205535e8f2cda8",
                )

                validation = adapter["validation"]
                self.assertEqual(validation["ruby"], "3.2.3")
                self.assertEqual(validation["process_audit"], "passed")
                self.assertEqual(
                    validation["foreign_compiler_linker_invocations"], 0
                )
                self.assertTrue(validation["source_clean_before_build"])
                self.assertTrue(validation["source_clean_after_build"])
                self.assertEqual(
                    validation["exported_entrypoint"],
                    expected["exported_entrypoint"],
                )

        next_four_evidence = {
            "etc": {
                "source_ref": "9ad32f8c8e199f34ae01e38bd647ab7e30a72406",
                "controller_sha": "5a6cec7c62723e8d96a7eb41a9fa991bde10fcae",
                "trace_sha256": "a4b7bcd631aee712c14ae496dd75315c33e0a02986f4be7867544a1ea77373d9",
                "receipts_sha256": "ef51a410b61777902bf735476473ad6bcd33bc2861d9793fe664f40a3bd13114",
                "native_receipts": 26,
                "receipt_tools": {"cc": 25, "shared": 1},
                "receipt_operations": {"compile": 11, "link": 15},
                "artifact_sha256": "5cb41577965bb8c129e8d7ee61a76a0d8de72020c1040409e0aaf1d2629fbc0b",
                "glibc_max": "2.6",
                "glibc_version_dependencies": 3,
                "evidence_archive": "ruby-zig-etc-continuous-5a6cec7-9ad32f8-evidence.tar.xz",
                "evidence_sha256": "7b5e368082027473a55d838ba9ef21376a8d471bf3435e2d06e475fb0c6bba5b",
                "exported_entrypoint": "Init_etc",
            },
            "iconv": {
                "source_ref": "07cceadf29439d5070b2be62ea644ca01fa7f940",
                "controller_sha": "34d78376e4b1afc0c68162704ff718508138d1e7",
                "trace_sha256": "84158019201c62b946425503f310c498c44fb2edb82596ed37eb11815de3208f",
                "receipts_sha256": "700349189cfb5298fa08ce93d0fc61ad5dd6b83068765c3870f05f4513a6b3d2",
                "native_receipts": 14,
                "receipt_tools": {"cc": 13, "shared": 1},
                "receipt_operations": {"compile": 3, "link": 10, "probe": 1},
                "artifact_sha256": "e41f24e1e9fbbb3a54075d8fcf550dc5b9dadce79d9084ff552ba84fe84954ab",
                "glibc_max": "2.2.5",
                "glibc_version_dependencies": 1,
                "evidence_archive": "ruby-zig-iconv-x86_64-linux-gnu.2.17-cert-34d7837-evidence.tar.xz",
                "evidence_sha256": "f832801d5c73f3178396e9cb6d2756a1ae71fb28c1b63ad11a6ceb66450582d4",
                "exported_entrypoint": "Init_iconv",
            },
            "nkf": {
                "source_ref": "0cbafd2db231e331ac8f10e77ef406c71e3b9fbe",
                "controller_sha": "5a6cec7c62723e8d96a7eb41a9fa991bde10fcae",
                "trace_sha256": "bbefb56b90302dd7617bd0dc6e42b8364f3631b2150177f0b924696e2cf9e1fd",
                "receipts_sha256": "e61afb056b7f5779fe492b49e88898c3afb75a7d80ed391f7e769e8fe69d0550",
                "native_receipts": 2,
                "receipt_tools": {"cc": 1, "shared": 1},
                "receipt_operations": {"compile": 1, "link": 1},
                "artifact_sha256": "a2bf382ba0dde5d2870fde9b20621255abf77ae3f23c91853c159089fa208ef1",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 2,
                "evidence_archive": "repo-nkf-continuous-5a6cec7-20260828T023042Z-evidence.tar.xz",
                "evidence_sha256": "47d929f7d3ed242b694a7dbabfe7e948224ae7ed1718149e118cb494007329a6",
                "exported_entrypoint": "Init_nkf",
            },
            "syck": {
                "source_ref": "0b76192bc3b8cd5dfe814e1166265ab38d82e41b",
                "controller_sha": "5a6cec7c62723e8d96a7eb41a9fa991bde10fcae",
                "trace_sha256": "630df97a902fd45711801155ca26e594ca56f3a6f5f4413701485ae9f50ceebc",
                "receipts_sha256": "f374d370a412245935fa4875720848584160016985a23671223be75bff962389",
                "native_receipts": 13,
                "receipt_tools": {"cc": 12, "shared": 1},
                "receipt_operations": {"compile": 11, "link": 2},
                "artifact_sha256": "c4ee6136d11f53b1aa59215b136da204e33f0a7ab47d273a6c5bddf6ca65a1e8",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 3,
                "evidence_archive": "syck-continuous-cert-5a6cec7-0b76192-evidence.tar.xz",
                "evidence_sha256": "dd1dc969c75c47f31b29d12a5c14d9611bfab52a2c954b0d475d6dc0764ac388",
                "exported_entrypoint": "Init_syck",
            },
        }
        for name, expected in next_four_evidence.items():
            with self.subTest(name=name):
                source = next(
                    item for item in lock["sources"] if item["name"] == name
                )
                self.assertEqual(source["result_id"], f"{name}-master")
                self.assertEqual(source["ref_name"], "master")
                self.assertEqual(source["repository"], f"ruby-zig/{name}")
                self.assertEqual(source["source_ref"], expected["source_ref"])
                self.assertEqual(source["adapter_id"], f"repo/{name}")
                self.assertEqual(
                    source["build_script"], f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(source["profiles"], ["x86_64-linux-gnu.2.17"])
                self.assertEqual(source["ruby_version"], "3.2.3")
                self.assertFalse(source["rust"])
                self.assertNotIn("profile_overrides", source)

                adapter = json.loads(
                    (ROOT / "adapters" / "repo" / name / "adapter.json").read_text()
                )
                self.assertEqual(adapter["repository"], f"ruby/{name}")
                self.assertEqual(adapter["upstream_sha"], expected["source_ref"])
                self.assertEqual(
                    adapter["cross_status"],
                    "pending-target-native-ruby-sdks-and-runtimes",
                )
                self.assertEqual(len(adapter["profiles"]), 1)
                profile = adapter["profiles"][0]
                self.assertEqual(profile["id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(profile["status"], "run-verified")
                self.assertEqual(
                    profile["controller_sha"], expected["controller_sha"]
                )
                self.assertEqual(profile["ruby"], "3.2.3")
                self.assertEqual(profile["zig"], "0.16.0")
                self.assertEqual(
                    profile["artifact_format"], "ELF64 x86-64 shared object"
                )
                self.assertEqual(profile["glibc_ceiling"], "2.17")
                for key in (
                    "trace_sha256",
                    "receipts_sha256",
                    "native_receipts",
                    "receipt_tools",
                    "receipt_operations",
                    "artifact_sha256",
                    "glibc_max",
                    "glibc_version_dependencies",
                    "evidence_archive",
                    "evidence_sha256",
                ):
                    self.assertEqual(profile[key], expected[key])

                validation = adapter["validation"]
                self.assertEqual(
                    validation["runner"], "atlas-tree Ubuntu 24.04 x86_64"
                )
                self.assertEqual(validation["ruby"], "3.2.3")
                self.assertEqual(validation["zig"], "0.16.0")
                self.assertEqual(validation["process_audit"], "passed")
                self.assertEqual(
                    validation["foreign_compiler_linker_invocations"], 0
                )
                self.assertTrue(validation["source_clean_before_build"])
                self.assertTrue(validation["source_clean_after_build"])
                self.assertEqual(
                    validation["exported_entrypoint"],
                    expected["exported_entrypoint"],
                )

        latest_three_evidence = {
            "debug": {
                "source_ref": "6510cfbc7496c55ebbefa437a25c17ca58f7c5eb",
                "controller_sha": "2b13a11b59dd0904af457df9d78929f85858a676",
                "trace_sha256": "86b93d47b64ddc489c559693f156e7db64ef6330a39d9c2bed9cdd7882574a0e",
                "receipts_sha256": "67fd9abb1cc19189fa2ff658eb6120e7234a4e6b3c7faf66c5fc2d31f1ece8d7",
                "native_receipts": 3,
                "receipt_tools": {"cc": 2, "shared": 1},
                "receipt_operations": {"compile": 2, "link": 1},
                "artifact_sha256": "c3e8791abc89c9b6dae6fb5e36f5aac15de1c30d3984dd7106550abd97dcbbab",
                "glibc_max": "2.2.5",
                "glibc_version_dependencies": 1,
                "evidence_archive": "debug-cert-2b13a11-6510cfb-evidence.tar.xz",
                "evidence_sha256": "8534e329c665c75d725bbb38bd04ef5f3203d59a9bd08b6d4e08159259eabcdd",
                "cross_status": "pending-target-native-ruby-sdks-and-runtimes",
                "exported_entrypoint": "Init_debug",
                "exported_init_symbols": [
                    "Init_debug",
                    "Init_iseq_collector",
                ],
            },
            "fiddle": {
                "source_ref": "195c8d133bb8e225f27ba54f1bc476b8d488e217",
                "controller_sha": "0bf93516c357c391725744a7d615f577c597e6be",
                "trace_sha256": "598cfae49fc83f424a6d753cf398d8cab4dd353388c6221547ac39ad85b149da",
                "receipts_sha256": "7dbcbc6230aa2d415171a352ece126f1fe989858eecc9a95fa91d9a34c09df98",
                "native_receipts": 143,
                "receipt_tools": {
                    "cc": 115,
                    "cxx": 21,
                    "ar": 4,
                    "ranlib": 2,
                    "shared": 1,
                },
                "receipt_operations": {
                    "probe": 26,
                    "compile": 78,
                    "link": 33,
                    "archive": 6,
                },
                "artifact_sha256": "9a6e593d42fc6260052bacd0a4a6f608514a11c9ebb278490e3da22f233bdb1c",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 4,
                "evidence_archive": "ruby-zig-fiddle-0bf9351-195c8d1-evidence.tar.xz",
                "evidence_sha256": "c726140d77a42944ed3053051cf680483ee6bed51b710e2990558eff780c255c",
                "cross_status": "pending-target-native-ruby-sdk-and-runtime",
                "exported_entrypoint": "Init_fiddle",
                "exported_init_symbols": [
                    "Init_fiddle",
                    "Init_fiddle_closure",
                    "Init_fiddle_function",
                    "Init_fiddle_handle",
                    "Init_fiddle_memory_view",
                    "Init_fiddle_pinned",
                    "Init_fiddle_pointer",
                ],
                "libffi_static_sha256": "a5f1b229c76e91648175fafb482bed0da1a0de4412355efc7a264775ee6aa5cd",
            },
            "zlib": {
                "source_ref": "c87e5ed1403144010b00ff1787e860e5d084511b",
                "controller_sha": "8f9d9ae4ee53b8511b11ab279cced47736ae3f17",
                "trace_sha256": "8bdf1925291b0af9c7e6726e79d78e14583bf3f7869a5515deb27cf80f07418c",
                "receipts_sha256": "c18b43e1cea1a1d649c0e3bc763bf539c49aaf89422f6c77fac53f9e96535b79",
                "native_receipts": 11,
                "receipt_tools": {"cc": 10, "shared": 1},
                "receipt_operations": {"compile": 3, "probe": 1, "link": 7},
                "artifact_sha256": "9cad13ff186a98833baa0f02297b39111312cef3671a4dab730b3c512ab37c29",
                "glibc_max": "2.14",
                "glibc_version_dependencies": 2,
                "evidence_archive": "ruby-zig-zlib-cert-8f9d9ae-c87e5ed-evidence.tar.xz",
                "evidence_sha256": "ce94d26b5efca67efead0a44b4ec3fb431eef01f0eddc660e7b4422c2b30b84d",
                "cross_status": "pending-target-native-ruby-sdk-runtime-and-zlib",
                "exported_entrypoint": "Init_zlib",
            },
        }
        for name, expected in latest_three_evidence.items():
            with self.subTest(name=name):
                source = next(
                    item for item in lock["sources"] if item["name"] == name
                )
                self.assertEqual(source["result_id"], f"{name}-master")
                self.assertEqual(source["ref_name"], "master")
                self.assertEqual(source["repository"], f"ruby-zig/{name}")
                self.assertEqual(source["source_ref"], expected["source_ref"])
                self.assertEqual(source["adapter_id"], f"repo/{name}")
                self.assertEqual(
                    source["build_script"], f"adapters/repo/{name}/build.sh"
                )
                self.assertEqual(source["profiles"], ["x86_64-linux-gnu.2.17"])
                self.assertEqual(source["ruby_version"], "3.2.3")
                self.assertFalse(source["rust"])

                adapter = json.loads(
                    (ROOT / "adapters" / "repo" / name / "adapter.json").read_text()
                )
                self.assertEqual(adapter["repository"], f"ruby/{name}")
                self.assertEqual(adapter["upstream_sha"], expected["source_ref"])
                self.assertEqual(adapter["cross_status"], expected["cross_status"])
                profile = adapter["profiles"][0]
                self.assertEqual(profile["id"], "x86_64-linux-gnu.2.17")
                self.assertEqual(profile["status"], "run-verified")
                self.assertEqual(profile["controller_sha"], expected["controller_sha"])
                self.assertEqual(profile["ruby"], "3.2.3")
                self.assertEqual(profile["zig"], "0.16.0")
                self.assertEqual(
                    profile["artifact_format"], "ELF64 x86-64 shared object"
                )
                self.assertEqual(profile["glibc_ceiling"], "2.17")
                for key in (
                    "trace_sha256",
                    "receipts_sha256",
                    "native_receipts",
                    "receipt_tools",
                    "receipt_operations",
                    "artifact_sha256",
                    "glibc_max",
                    "glibc_version_dependencies",
                    "evidence_archive",
                    "evidence_sha256",
                ):
                    self.assertEqual(profile[key], expected[key])
                if name == "fiddle":
                    self.assertEqual(
                        profile["libffi_static_sha256"],
                        expected["libffi_static_sha256"],
                    )

                validation = adapter["validation"]
                self.assertEqual(
                    validation["runner"], "atlas-tree Ubuntu 24.04 x86_64"
                )
                self.assertEqual(validation["ruby"], "3.2.3")
                self.assertEqual(validation["zig"], "0.16.0")
                self.assertEqual(validation["process_audit"], "passed")
                self.assertEqual(
                    validation["foreign_compiler_linker_invocations"], 0
                )
                self.assertTrue(validation["source_clean_before_build"])
                self.assertTrue(validation["source_clean_after_build"])
                self.assertEqual(
                    validation["exported_entrypoint"],
                    expected["exported_entrypoint"],
                )
                if name in ("debug", "fiddle"):
                    self.assertEqual(
                        validation["exported_init_symbols"],
                        expected["exported_init_symbols"],
                    )
                if name == "fiddle":
                    self.assertFalse(validation["dynamic_libffi_dependency"])

        io_nonblock = json.loads(
            (ROOT / "adapters" / "repo" / "io-nonblock" / "adapter.json").read_text()
        )
        self.assertEqual(io_nonblock["profiles"][0]["glibc_max"], "2.2.5")
        self.assertEqual(
            io_nonblock["profiles"][0]["mkmf_log_sha256"],
            "07d8cea80bf2c6ebdc8c717e8d9b8b3e81b3107abc88aa6d979ae176d65afea9",
        )
        for name in ("fcntl", "io-wait"):
            adapter = json.loads(
                (ROOT / "adapters" / "repo" / name / "adapter.json").read_text()
            )
            self.assertEqual(
                adapter["profiles"][0]["glibc_version_dependencies"], 0
            )
        io_wait = json.loads(
            (ROOT / "adapters" / "repo" / "io-wait" / "adapter.json").read_text()
        )
        self.assertEqual(
            io_wait["native_scope"], "project-extension-compatibility-stub"
        )
        ruby_adapter = json.loads(
            (ROOT / "adapters" / "repo" / "ruby" / "adapter.json").read_text()
        )
        self.assertEqual(
            ruby_adapter["artifacts"],
            ["$RZ_ARTIFACT_DIR/$RZ_ZIG_TARGET/cruby/**"],
        )
        ruby_validation = ruby_adapter["validation"]
        self.assertEqual(
            ruby_validation["trace_sha256"],
            "d8c095b023b5f370456adee882aa5cdf7caf4e165d6d89fd46abb52a524949b8",
        )
        self.assertEqual(
            ruby_validation["receipts_sha256"],
            "d3bada25a85ff089863b89a952b1b90f085edb0928239fda1eda675dabf9b8bd",
        )
        self.assertNotIn("trace", ruby_validation)
        self.assertNotIn("receipts", ruby_validation)
        source_records = {
            source["name"]: source
            for source in ruby_adapter["source_refs"]
            if source["name"] in CRUBY_REFS
        }
        evidence_by_ref = {
            name: next(
                evidence
                for evidence in source["validated_baselines"]
                if evidence["sha"] == CRUBY_REFS[name]
            )
            for name, source in source_records.items()
        }
        self.assertEqual(set(evidence_by_ref), set(CRUBY_REFS))
        for name, evidence in evidence_by_ref.items():
            if name in CRUBY_PENDING_FIRST_RUN:
                # Admitted but not yet run-verified: the candidate status is
                # the honest record until real receipts replace it.
                self.assertEqual(evidence["status"], "candidate-shared-native")
                self.assertIn("note", evidence)
            else:
                self.assertEqual(evidence["status"], "run-verified-shared-native")
        profile_sources = {
            profile["source_ref"]: profile["source_sha"]
            for profile in ruby_adapter["profiles"]
            if profile["status"]
            in {"run-verified-baseline", "candidate-baseline"}
        }
        self.assertEqual(profile_sources, CRUBY_REFS)
        candidate_profiles = {
            profile["source_ref"]
            for profile in ruby_adapter["profiles"]
            if profile["status"] == "candidate-baseline"
        }
        self.assertEqual(candidate_profiles, CRUBY_PENDING_FIRST_RUN)
        self.assertEqual(
            ruby_adapter["cross_status"],
            "x86_64-linux-musl-run-verified-admitted",
        )

        release_evidence = {
            "ruby_3_4": {
                "release": "3.4.10",
                "receipts": 1518,
                "receipts_sha256": "fd81a503f54e9126448f1cbe8168120be9acb8e836c497302e1368ecf0fed973",
                "trace_sha256": "ddae8a775037a43541d9dd2a702ad9d8d2151b72b74250e5e2b861d45d81e3c3",
                "transcript_sha256": "81c89343f7817c0f0d82d59904f2333ba87931137718f2b3e0bedb2484bfa2d4",
                "manifest_sha256": "1659e3db96e003a968f844d649637719e142b8838aadd446868d57f54f1406a9",
                "dso_list_sha256": "ec22e1646f14e3a5781830d616427d2632f161241fc1677e1ccf8469f2ffad44",
                "export_map_symbols": 3212,
            },
            "ruby_3_3": {
                "release": "3.3.12",
                "receipts": 1538,
                "receipts_sha256": "4b2a6cc08485d480bc18e4854ac134b4fdf314bf9ff6237939867f838a9b9759",
                "trace_sha256": "2dbf06dca21fa7bdf4ce2734339d1d88f1d8b628a8df1ee70c5511b49812c566",
                "transcript_sha256": "29498e70840b58cd6547c13bc3cab4f18eb38334d24136595954ae4eed69e3d4",
                "manifest_sha256": "564467a1ed8faaf240246e4783b8039b6446ac3b54610217e1ddcf2106dea732",
                "dso_list_sha256": "19d0b261835a0ec23c788128a5ba61215053398620fa207c53e110e3bdc1b5ef",
                "export_map_symbols": 3047,
            },
        }
        for name, expected in release_evidence.items():
            evidence = evidence_by_ref[name]
            self.assertEqual(evidence["release"], expected["release"])
            self.assertEqual(evidence["receipt_count"], expected["receipts"])
            self.assertEqual(evidence["receipts_sha256"], expected["receipts_sha256"])
            self.assertEqual(evidence["trace_sha256"], expected["trace_sha256"])
            self.assertEqual(evidence["transcript_sha256"], expected["transcript_sha256"])
            self.assertEqual(
                evidence["curated_manifest_sha256"], expected["manifest_sha256"]
            )
            self.assertEqual(evidence["dso_list_sha256"], expected["dso_list_sha256"])
            self.assertEqual(
                evidence["export_map_symbols"], expected["export_map_symbols"]
            )
            self.assertEqual(
                evidence["controller"],
                {
                    "commit": "6f54fe9902c60b7a5862b91868e875a7eb694f1f",
                    "tree": "9d7acb8350766f14ca4fcbff08a07a9ca3cd1b34",
                    "bundle_sha256": "e9d625a78b234078fde3f91e18692780003e52311b408e3590a41cc0d066f9ae",
                    "build_script_sha256": "21193cce4ad4efd92f17d0b1f26c5f77f41f7a1f6fdcfd9ba34fce77b2712b22",
                    "source_contract_sha256": "39a5d2e6832855b885bca44e4cb6b28255e67f0aac015961dbf9874828b5c5e4",
                },
            )
            self.assertEqual(evidence["tests"]["basic_groups"], 30)
            self.assertEqual(evidence["tests"]["assertions"], 894)
            self.assertEqual(evidence["native_extension_scope"]["built_dsos"], 155)
            self.assertEqual(evidence["native_extension_scope"]["smoke_families"], 26)
            self.assertEqual(
                evidence["native_extension_scope"]["excluded_from_certification"],
                ["fiddle", "openssl", "psych", "zlib"],
            )
            self.assertEqual(
                evidence["export_audit"],
                {
                    "rust_mangled_dynamic_exports": 0,
                    "partial_link_products": 0,
                    "forbidden_processes": 0,
                },
            )
            self.assertEqual(
                evidence["dso_links"],
                {"total": 2, "mapped": 1, "mapped_is_final": True},
            )
            self.assertEqual(evidence["gnu_abi_ceiling"]["miniruby"], "GLIBC_2.17")
            self.assertEqual(evidence["gnu_abi_ceiling"]["ruby"], "GLIBC_2.4")

        for name in ("bigdecimal", "json", "stringio", "strscan"):
            adapter = json.loads(
                (ROOT / "adapters" / "repo" / name / "adapter.json").read_text()
            )
            musl = next(
                profile
                for profile in adapter["profiles"]
                if profile["id"] == "x86_64-linux-musl"
            )
            self.assertEqual(musl["status"], "experimental-non-certifying")
            self.assertEqual(
                adapter["cross_status"],
                "blocked-missing-target-native-musl-ruby-sdk",
            )
            self.assertTrue(any("GNU Ruby SDK" in gap for gap in adapter["gaps"]))
        date_adapter = json.loads(
            (ROOT / "adapters" / "repo" / "date" / "adapter.json").read_text()
        )
        self.assertEqual(
            [profile["id"] for profile in date_adapter["profiles"]],
            ["x86_64-linux-gnu.2.17"],
        )
        self.assertEqual(
            date_adapter["cross_status"],
            "blocked-missing-target-native-ruby-sdk-and-runtime",
        )

    def test_digest_adapter_neutralizes_runner_rpath_inputs(self) -> None:
        build = (ROOT / "adapters" / "repo" / "digest" / "build.sh").read_text()

        self.assertIn('"RPATHFLAG" => ""', build)
        self.assertIn("%w[LIBRUBYARG LIBRUBYARG_SHARED]", build)
        self.assertIn(
            'value.gsub(/(?:\\A|\\s)-Wl,-rpath(?:,|=)[^\\s]+/, "").strip',
            build,
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
        (root / "adapters" / "repo" / "native" / "build-musl.sh").write_text(
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

    def test_profile_overrides_are_lane_specific_and_preserve_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            source = lock["sources"][0]
            source["profiles"] = [
                "x86_64-linux-gnu.2.17",
                "x86_64-linux-musl",
                "aarch64-linux-musl",
            ]
            source["profile_overrides"] = {
                "x86_64-linux-musl": {
                    "build_script": "adapters/repo/native/build-musl.sh",
                    "rust": False,
                }
            }
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(lock), encoding="utf-8"
            )

            plan = renderer.plan_fleet(root)
            native_lanes = [
                lane for lane in plan.lanes if lane.result_id == "native-master"
            ]
            self.assertEqual(
                [(lane.profile["id"], lane.ready) for lane in native_lanes],
                [
                    ("x86_64-linux-gnu.2.17", True),
                    ("x86_64-linux-musl", True),
                    ("aarch64-linux-musl", False),
                ],
            )

            _, outputs = renderer.shard_summary(plan, 1)
            entries = {
                entry["profile_id"]: entry
                for entry in json.loads(outputs["matrix"])["include"]
                if entry["result_id"] == "native-master"
            }
            self.assertEqual(set(entries), {
                "x86_64-linux-gnu.2.17",
                "x86_64-linux-musl",
            })
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

    def test_lock_selects_profiles_and_blocked_rust_stays_pending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._write_fixture(root)

            plan = renderer.plan_fleet(root)
            self.assertEqual(plan.discovery_repositories, 4)
            self.assertEqual(plan.fleet_repositories, 2)
            self.assertEqual(plan.source_identities, 2)
            self.assertEqual(plan.maximum_jobs, 6)
            self.assertEqual(plan.desired_jobs, 6)
            self.assertEqual(
                [(lane.result_id, lane.profile["id"]) for lane in plan.lanes],
                [
                    ("native-master", "x86_64-linux-gnu.2.17"),
                    ("native-master", "x86_64-linux-musl"),
                    ("native-master", "aarch64-linux-musl"),
                    ("spec-master", "x86_64-linux-gnu.2.17"),
                    ("spec-master", "x86_64-linux-musl"),
                    ("spec-master", "aarch64-linux-musl"),
                ],
            )

            _, outputs = renderer.shard_summary(plan, 1)
            matrix = json.loads(outputs["matrix"])["include"]
            self.assertEqual(outputs["ready_jobs"], "2")
            self.assertEqual(outputs["pending_jobs"], "4")
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

    def test_unverified_rust_profile_stays_pending(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            source = lock["sources"][0]
            source["profiles"] = ["x86_64-linux-musl"]
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(lock), encoding="utf-8"
            )

            plan = renderer.plan_fleet(root)
            lane = next(
                lane
                for lane in plan.lanes
                if lane.result_id == "native-master"
                and lane.profile["id"] == "x86_64-linux-musl"
            )
            self.assertFalse(lane.ready)
            self.assertIn("only smoke-verified profiles may enable Rust", lane.reason)

            _, outputs = renderer.shard_summary(plan, 1)
            matrix = json.loads(outputs["matrix"])["include"]
            self.assertNotIn(
                ("native-master", "x86_64-linux-musl"),
                {(entry["result_id"], entry["profile_id"]) for entry in matrix},
            )

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
                {
                    "result_id": "ruby-ruby_3_2",
                    "name": "ruby",
                    "repository": "ruby/ruby",
                    "ref_name": "ruby_3_2",
                    "source_ref": "f" * 40,
                    "rust": True,
                },
            ]
            lock["source_refs"] = ruby_refs + [lock["source_refs"][1]]
            master = lock["sources"][0]
            master.update(
                result_id="ruby-master",
                name="ruby",
                repository="ruby-zig/ziguanite",
            )
            release = copy.deepcopy(master)
            release.update(
                result_id="ruby-ruby_4_0",
                ref_name="ruby_4_0",
                source_ref="c" * 40,
                profiles=["x86_64-linux-musl"],
                profile_overrides={
                    "x86_64-linux-musl": {"rust": False}
                },
            )
            lock["sources"] = [master, release, lock["sources"][1]]
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(lock), encoding="utf-8"
            )

            plan = renderer.plan_fleet(root)
            self.assertEqual(plan.source_identities, 6)
            self.assertEqual(plan.maximum_jobs, 18)
            self.assertEqual(plan.desired_jobs, 18)
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

    def test_locked_fork_name_may_differ_from_upstream_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = self._write_fixture(root)
            lock["sources"][0]["repository"] = "ruby-zig/renamed-native"
            (root / "config" / "fleet-lock.json").write_text(
                json.dumps(lock), encoding="utf-8"
            )

            plan = renderer.plan_fleet(root)
            _, outputs = renderer.shard_summary(plan, 1)
            matrix = json.loads(outputs["matrix"])["include"]
            entry = next(
                item for item in matrix if item["result_id"] == "native-master"
            )
            self.assertEqual(entry["repository"], "ruby-zig/renamed-native")

    def test_invalid_executable_lock_contracts_are_rejected(self) -> None:
        cases = {
            "foreign repository owner": (
                lambda source: source.update(repository="someone-else/native"),
                "repository must be an exact ruby-zig/NAME fork",
            ),
            "unsafe repository name": (
                lambda source: source.update(repository="ruby-zig/../native"),
                "repository must be an exact ruby-zig/NAME fork",
            ),
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
            "profile overrides must be an object": (
                lambda source: source.update(profile_overrides=[]),
                "profile_overrides must be a nonempty object",
            ),
            "profile overrides must not be empty": (
                lambda source: source.update(profile_overrides={}),
                "profile_overrides must be a nonempty object",
            ),
            "override profile must be selected": (
                lambda source: source.update(
                    profile_overrides={"x86_64-linux-musl": {"rust": False}}
                ),
                "must also appear in profiles",
            ),
            "override profile must be known": (
                lambda source: source.update(
                    profile_overrides={"not-a-target": {"rust": False}}
                ),
                "names an unknown profile",
            ),
            "override contract must not be empty": (
                lambda source: source.update(
                    profile_overrides={"aarch64-linux-musl": {}}
                ),
                "must be a nonempty object",
            ),
            "override fields are closed": (
                lambda source: source.update(
                    profile_overrides={
                        "aarch64-linux-musl": {"allow_no_native": True}
                    }
                ),
                "has unexpected fields",
            ),
            "override rust must be boolean": (
                lambda source: source.update(
                    profile_overrides={"aarch64-linux-musl": {"rust": 0}}
                ),
                "rust must be boolean",
            ),
            "override script stays under adapters": (
                lambda source: source.update(
                    profile_overrides={
                        "aarch64-linux-musl": {"build_script": "build-musl.sh"}
                    }
                ),
                "controller-relative under adapters/",
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
