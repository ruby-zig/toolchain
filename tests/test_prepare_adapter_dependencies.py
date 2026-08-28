from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "prepare_adapter_dependencies",
    ROOT / "scripts" / "prepare-adapter-dependencies.py",
)
assert SPEC and SPEC.loader
preparer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preparer
SPEC.loader.exec_module(preparer)


class AdapterDependencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "controller"
        self.adapter = self.root / "adapters" / "repo" / "example"
        self.adapter.mkdir(parents=True)
        (self.adapter / "build.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        self.payload = b"immutable adapter dependency\n"
        self.digest = hashlib.sha256(self.payload).hexdigest()
        self.pin = {
            "schema": 1,
            "name": "example-dependency",
            "version": "1.2.3",
            "archive_url": "https://example.invalid/example-1.2.3.tar.gz",
            "archive_name": "example-1.2.3.tar.gz",
            "archive_size": len(self.payload),
            "sha256": self.digest,
        }
        (self.adapter / "dependency.json").write_text(
            json.dumps(self.pin), encoding="utf-8"
        )
        self.manifest = {
            "schema": 1,
            "adapter_id": "repo/example",
            "dependencies": [
                {
                    "name": "example-dependency",
                    "version": "1.2.3",
                    "source": "dependency.json",
                    "archive_environment": "RZ_DEP_EXAMPLE_ARCHIVE",
                }
            ],
        }
        self.write_manifest()
        self.destination = Path(self.temporary.name) / "cache"

    def write_manifest(self) -> None:
        (self.adapter / "adapter.json").write_text(
            json.dumps(self.manifest), encoding="utf-8"
        )

    def cached_archive(self) -> Path:
        return preparer.cache_path(
            self.destination.resolve(), self.digest, self.pin["archive_name"]
        )

    def prepare_offline(self):
        return preparer.prepare_dependencies(
            self.root,
            "adapters/repo/example/build.sh",
            self.destination,
            offline=True,
        )

    def test_verified_cache_writes_environment_and_provenance(self) -> None:
        archive = self.cached_archive()
        archive.parent.mkdir(parents=True)
        archive.write_bytes(self.payload)

        prepared = self.prepare_offline()
        self.assertEqual(len(prepared), 1)
        self.assertEqual(prepared[0]["archive_path"], str(archive))
        self.assertEqual(prepared[0]["archive_sha256"], self.digest)

        github_env = Path(self.temporary.name) / "github-env"
        record = Path(self.temporary.name) / "dependencies.json"
        preparer.write_github_environment(github_env, prepared)
        preparer.write_record(
            record, "adapters/repo/example/build.sh", prepared
        )
        self.assertEqual(
            github_env.read_text(encoding="utf-8"),
            f"RZ_DEP_EXAMPLE_ARCHIVE={archive}\n",
        )
        parsed = json.loads(record.read_text(encoding="utf-8"))
        self.assertEqual(parsed["schema"], 1)
        self.assertNotIn("archive_path", parsed["dependencies"][0])
        self.assertEqual(
            parsed["dependencies"],
            [
                {
                    key: value
                    for key, value in prepared[0].items()
                    if key != "archive_path"
                }
            ],
        )
        preparer.verify_dependency_record(
            record, self.root, "adapters/repo/example/build.sh"
        )

    def test_mismatched_cached_archive_fails_closed(self) -> None:
        archive = self.cached_archive()
        archive.parent.mkdir(parents=True)
        archive.write_bytes(b"x" * len(self.payload))
        with self.assertRaisesRegex(preparer.DependencyError, "SHA-256 mismatch"):
            self.prepare_offline()

    def test_missing_offline_archive_fails_closed(self) -> None:
        with self.assertRaisesRegex(preparer.DependencyError, "offline.*missing"):
            self.prepare_offline()

    def test_build_script_must_stay_under_adapters(self) -> None:
        with self.assertRaisesRegex(preparer.DependencyError, "under adapters"):
            preparer.prepare_dependencies(
                self.root,
                "../outside/build.sh",
                self.destination,
                offline=True,
            )

    def test_unscoped_environment_is_rejected(self) -> None:
        self.manifest["dependencies"][0]["archive_environment"] = "HOME"
        self.write_manifest()
        with self.assertRaisesRegex(preparer.DependencyError, "scoped RZ_"):
            self.prepare_offline()

    def test_controller_environment_name_is_rejected(self) -> None:
        self.manifest["dependencies"][0]["archive_environment"] = "RZ_ZIG"
        self.write_manifest()
        with self.assertRaisesRegex(preparer.DependencyError, "scoped RZ_DEP_"):
            self.prepare_offline()

    def test_duplicate_dependency_environment_is_rejected(self) -> None:
        self.manifest["dependencies"].append(
            dict(self.manifest["dependencies"][0])
        )
        self.write_manifest()
        with self.assertRaisesRegex(preparer.DependencyError, "duplicate.*environment"):
            self.prepare_offline()

    def test_archive_name_rejects_windows_path_separators(self) -> None:
        self.pin["archive_name"] = r"..\outside.tar.gz"
        (self.adapter / "dependency.json").write_text(
            json.dumps(self.pin), encoding="utf-8"
        )
        with self.assertRaisesRegex(preparer.DependencyError, "plain file name"):
            self.prepare_offline()

    def test_download_stops_after_pinned_byte_count(self) -> None:
        class Response(io.BytesIO):
            def geturl(self) -> str:
                return "https://example.invalid/example.tar.gz"

        class Opener:
            def open(self, request, timeout):
                return Response(self.payload)

            def __init__(self, payload: bytes) -> None:
                self.payload = payload

        archive = self.destination / "example.tar.gz"
        with self.assertRaisesRegex(
            preparer.DependencyError, "exceeded its pinned byte count"
        ):
            preparer.download_archive(
                "https://example.invalid/example.tar.gz",
                archive,
                len(self.payload) - 1,
                self.digest,
                opener=Opener(self.payload),
            )
        self.assertFalse(archive.exists())

    def test_online_path_writes_only_a_verified_archive(self) -> None:
        class Response(io.BytesIO):
            def geturl(self) -> str:
                return "https://cdn.example.invalid/example.tar.gz"

        class Opener:
            def open(self, request, timeout):
                return Response(self.payload)

            def __init__(self, payload: bytes) -> None:
                self.payload = payload

        archive = self.destination / "example.tar.gz"
        preparer.download_archive(
            self.pin["archive_url"],
            archive,
            len(self.payload),
            self.digest,
            opener=Opener(self.payload),
        )
        self.assertEqual(archive.read_bytes(), self.payload)

    def test_redirect_handler_rejects_downgrade_before_following(self) -> None:
        handler = preparer.HttpsOnlyRedirectHandler()
        with self.assertRaisesRegex(preparer.DependencyError, "HTTPS"):
            handler.redirect_request(
                None,
                None,
                302,
                "Found",
                {},
                "http://example.invalid/archive.tar.gz",
            )

    def test_record_tampering_is_rejected_for_fiddle(self) -> None:
        build_script = "adapters/repo/fiddle/build.sh"
        record = preparer.expected_record(ROOT, build_script)
        record["dependencies"][0]["archive_sha256"] = "0" * 64
        path = Path(self.temporary.name) / "tampered-fiddle-record.json"
        path.write_text(json.dumps(record), encoding="utf-8")
        with self.assertRaisesRegex(preparer.DependencyError, "does not exactly match"):
            preparer.verify_dependency_record(path, ROOT, build_script)

    def test_adapter_without_dependencies_is_a_noop(self) -> None:
        self.manifest.pop("dependencies")
        self.write_manifest()
        self.assertEqual(self.prepare_offline(), [])

    def test_fiddle_declares_the_exact_libffi_archive_input(self) -> None:
        adapter = json.loads(
            (ROOT / "adapters" / "repo" / "fiddle" / "adapter.json").read_text()
        )
        dependency = adapter["dependencies"][0]
        self.assertEqual(dependency["name"], "libffi")
        self.assertEqual(dependency["version"], "3.4.6")
        self.assertEqual(dependency["source"], "libffi.json")
        self.assertEqual(
            dependency["archive_environment"], "RZ_DEP_LIBFFI_ARCHIVE"
        )
        pin = json.loads(
            (ROOT / "adapters" / "repo" / "fiddle" / "libffi.json").read_text()
        )
        self.assertEqual(pin["archive_size"], 1_391_684)
        self.assertEqual(
            pin["sha256"],
            "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e",
        )


if __name__ == "__main__":
    unittest.main()
