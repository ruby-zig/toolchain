#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any


ENVIRONMENT_RE = re.compile(r"RZ_DEP_[A-Z0-9_]+\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
CONTRACT_FIELDS = (
    "name",
    "version",
    "source",
    "source_sha256",
    "archive_url",
    "archive_name",
    "archive_size",
    "archive_sha256",
    "archive_environment",
    "cache_key",
)


class DependencyError(RuntimeError):
    pass


def checked_https_url(url: str, label: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
    ):
        raise DependencyError(f"{label} must be an unauthenticated HTTPS URL: {url}")
    return parsed


class HttpsOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: Any,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> Any:
        checked_https_url(newurl, "dependency archive redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DependencyError(f"{label} is not readable JSON: {path}: {error}") from error
    if not isinstance(value, dict):
        raise DependencyError(f"{label} must be a JSON object: {path}")
    return value


def resolve_adapter(controller_root: Path, build_script: str) -> tuple[Path, dict[str, Any]]:
    relative = PurePosixPath(build_script)
    if (
        relative.is_absolute()
        or not relative.parts
        or relative.parts[0] != "adapters"
        or any(part in ("", ".", "..") for part in relative.parts)
    ):
        raise DependencyError(
            f"build script must be a controller-relative path under adapters/: {build_script}"
        )

    root = controller_root.resolve(strict=True)
    script = root.joinpath(*relative.parts).resolve(strict=True)
    try:
        script.relative_to(root)
    except ValueError as error:
        raise DependencyError(f"build script escapes the controller root: {build_script}") from error
    if not script.is_file():
        raise DependencyError(f"build script is not a file: {script}")

    manifest_path = script.parent / "adapter.json"
    manifest = load_object(manifest_path, "adapter manifest")
    return script.parent, manifest


def checked_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise DependencyError(f"{label} must be a nonempty single-line string")
    return value


def cache_path(destination: Path, sha256: str, archive_name: str) -> Path:
    return destination / sha256 / archive_name


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_archive(path: Path, expected_size: int, expected_sha256: str) -> None:
    try:
        stat = path.stat()
    except OSError as error:
        raise DependencyError(f"dependency archive is unavailable: {path}: {error}") from error
    if path.is_symlink() or not path.is_file():
        raise DependencyError(f"dependency archive is not a regular file: {path}")
    if stat.st_size != expected_size:
        raise DependencyError(
            f"dependency archive size mismatch for {path}: "
            f"got {stat.st_size}, expected {expected_size}"
        )

    actual = sha256_file(path)
    if actual != expected_sha256:
        raise DependencyError(
            f"dependency archive SHA-256 mismatch for {path}: "
            f"got {actual}, expected {expected_sha256}"
        )


def download_archive(
    url: str,
    destination: Path,
    expected_size: int,
    expected_sha256: str,
    *,
    opener: Any | None = None,
) -> None:
    checked_https_url(url, "dependency archive URL")

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.part-{os.getpid()}")
    if temporary.exists():
        raise DependencyError(f"refusing to reuse dependency download temporary file: {temporary}")

    request = urllib.request.Request(url, headers={"User-Agent": "ruby.zig dependency fetcher"})
    if opener is None:
        opener = urllib.request.build_opener(HttpsOnlyRedirectHandler())
    digest = hashlib.sha256()
    size = 0
    try:
        with opener.open(request, timeout=60) as response, temporary.open("xb") as output:
            checked_https_url(response.geturl(), "dependency archive final URL")
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > expected_size:
                    raise DependencyError(
                        "dependency archive exceeded its pinned byte count: "
                        f"{size}/{expected_size}"
                    )
                output.write(chunk)
                digest.update(chunk)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        temporary.unlink(missing_ok=True)
        raise

    actual_sha256 = digest.hexdigest()
    if size != expected_size or actual_sha256 != expected_sha256:
        temporary.unlink(missing_ok=True)
        raise DependencyError(
            "downloaded dependency archive does not match its immutable contract: "
            f"size={size}/{expected_size} sha256={actual_sha256}/{expected_sha256}"
        )
    os.replace(temporary, destination)


def dependency_contracts(
    adapter_dir: Path, manifest: dict[str, Any]
) -> list[dict[str, Any]]:
    raw_dependencies = manifest.get("dependencies", [])
    if not isinstance(raw_dependencies, list):
        raise DependencyError("adapter dependencies must be an array")

    contracts: list[dict[str, Any]] = []
    used_environments: set[str] = set()
    for index, raw_dependency in enumerate(raw_dependencies):
        label = f"dependency {index + 1}"
        if not isinstance(raw_dependency, dict):
            raise DependencyError(f"{label} must be an object")
        name = checked_string(raw_dependency.get("name"), f"{label} name")
        version = checked_string(raw_dependency.get("version"), f"{label} version")
        source_name = checked_string(raw_dependency.get("source"), f"{label} source")
        archive_environment = checked_string(
            raw_dependency.get("archive_environment"),
            f"{label} archive_environment",
        )
        if not ENVIRONMENT_RE.fullmatch(archive_environment):
            raise DependencyError(
                f"{label} archive_environment is not a scoped RZ_DEP_ variable: "
                f"{archive_environment}"
            )
        if archive_environment in used_environments:
            raise DependencyError(f"duplicate dependency environment: {archive_environment}")
        used_environments.add(archive_environment)

        source_relative = PurePosixPath(source_name)
        if (
            source_relative.is_absolute()
            or len(source_relative.parts) != 1
            or source_relative.suffix != ".json"
        ):
            raise DependencyError(f"{label} source must be one JSON file beside adapter.json")
        source_path = (adapter_dir / source_name).resolve(strict=True)
        if source_path.parent != adapter_dir.resolve():
            raise DependencyError(f"{label} source escapes its adapter directory")
        pin = load_object(source_path, f"{label} source pin")
        if pin.get("name") != name or pin.get("version") != version:
            raise DependencyError(f"{label} manifest and source pin identities differ")
        source_sha256 = sha256_file(source_path)

        archive_url = checked_string(pin.get("archive_url"), f"{label} archive_url")
        checked_https_url(archive_url, f"{label} archive_url")
        archive_name = checked_string(pin.get("archive_name"), f"{label} archive_name")
        if (
            PurePosixPath(archive_name).name != archive_name
            or "\\" in archive_name
            or archive_name in (".", "..")
        ):
            raise DependencyError(f"{label} archive_name must be a plain file name")
        archive_size = pin.get("archive_size")
        if not isinstance(archive_size, int) or isinstance(archive_size, bool) or archive_size < 1:
            raise DependencyError(f"{label} archive_size must be a positive integer")
        archive_sha256 = checked_string(pin.get("sha256"), f"{label} sha256")
        if not SHA256_RE.fullmatch(archive_sha256):
            raise DependencyError(f"{label} sha256 must be a lowercase full SHA-256")

        contracts.append(
            {
                "name": name,
                "version": version,
                "source": source_name,
                "source_sha256": source_sha256,
                "archive_url": archive_url,
                "archive_name": archive_name,
                "archive_size": archive_size,
                "archive_sha256": archive_sha256,
                "archive_environment": archive_environment,
                "cache_key": f"{archive_sha256}/{archive_name}",
            }
        )
    return contracts


def expected_record(controller_root: Path, build_script: str) -> dict[str, Any]:
    adapter_dir, manifest = resolve_adapter(controller_root, build_script)
    return {
        "schema": 1,
        "build_script": build_script,
        "dependencies": dependency_contracts(adapter_dir, manifest),
    }


def verify_dependency_record(
    path: Path, controller_root: Path, build_script: str
) -> None:
    actual = load_object(path, "adapter dependency record")
    expected = expected_record(controller_root, build_script)
    if actual != expected:
        raise DependencyError(
            "adapter dependency record does not exactly match its manifest and source pins"
        )


def prepare_dependencies(
    controller_root: Path,
    build_script: str,
    destination: Path,
    *,
    offline: bool,
) -> list[dict[str, Any]]:
    adapter_dir, manifest = resolve_adapter(controller_root, build_script)
    contracts = dependency_contracts(adapter_dir, manifest)
    prepared: list[dict[str, Any]] = []
    for contract in contracts:
        archive = cache_path(
            destination.resolve(),
            contract["archive_sha256"],
            contract["archive_name"],
        )
        if archive.exists():
            verify_archive(
                archive, contract["archive_size"], contract["archive_sha256"]
            )
        elif offline:
            raise DependencyError(f"offline dependency archive is missing: {archive}")
        else:
            download_archive(
                contract["archive_url"],
                archive,
                contract["archive_size"],
                contract["archive_sha256"],
            )
            verify_archive(
                archive, contract["archive_size"], contract["archive_sha256"]
            )

        prepared.append(
            {
                **contract,
                "archive_path": str(archive),
            }
        )
    return prepared


def write_github_environment(path: Path, prepared: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        for dependency in prepared:
            handle.write(
                f"{dependency['archive_environment']}={dependency['archive_path']}\n"
            )


def write_record(path: Path, build_script: str, prepared: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    dependencies = []
    for dependency in prepared:
        dependencies.append(
            {key: dependency[key] for key in CONTRACT_FIELDS}
        )
    record = {
        "schema": 1,
        "build_script": build_script,
        "dependencies": dependencies,
    }
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    if temporary.exists():
        raise DependencyError(f"refusing to reuse dependency record temporary file: {temporary}")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Fetch checksum-pinned external inputs declared by one adapter"
    )
    result.add_argument("--controller-root", type=Path, required=True)
    result.add_argument("--build-script", required=True)
    result.add_argument("--destination", type=Path)
    result.add_argument("--github-env", type=Path)
    result.add_argument("--record", type=Path)
    result.add_argument("--offline", action="store_true")
    result.add_argument("--verify-record", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.verify_record:
            if args.destination or args.github_env or args.record or args.offline:
                raise DependencyError(
                    "--verify-record cannot be combined with preparation outputs"
                )
            verify_dependency_record(
                args.verify_record, args.controller_root, args.build_script
            )
            print("adapter dependency record matches its immutable contracts")
            return 0
        if args.destination is None:
            raise DependencyError("--destination is required when preparing dependencies")
        prepared = prepare_dependencies(
            args.controller_root,
            args.build_script,
            args.destination,
            offline=args.offline,
        )
        if args.github_env:
            write_github_environment(args.github_env, prepared)
        if args.record:
            write_record(args.record, args.build_script, prepared)
    except (DependencyError, OSError, urllib.error.URLError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if prepared:
        for dependency in prepared:
            print(
                f"prepared {dependency['name']} {dependency['version']} "
                f"sha256={dependency['archive_sha256']}"
            )
    else:
        print("adapter declares no external archives")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
