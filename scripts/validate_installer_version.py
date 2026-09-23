#!/usr/bin/env python3
"""Validate Forge Platform Installer's package-time runtime-version projection.

``installer-version.json`` is intentionally independent from
``product-version.json``: the former versions the native updater while the
latter versions Forge Platform's composition/release product. A source build
does not carry a trusted runtime version in Swift. Instead the unsigned app
packager projects this one owning manifest into the code-signed
``Contents/Info.plist`` that a released app reads at runtime.

Validation is deliberately behavioural. It asks the repository's exact
packager to lay out a temporary unsigned app, then reads the resulting plist.
Checking a Swift literal or merely parsing the packager source would let the
source declaration and actual shipped runtime identity drift apart.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from forge_platform.macos_platform_contract import thin_arm64_macho_test_bytes  # noqa: E402

MANIFEST_RELATIVE_PATH = Path("installer-version.json")
PACKAGER_RELATIVE_PATH = Path("scripts/package_macos_installer_app.py")
INFO_PLIST_RELATIVE_PATH = Path("Contents") / "Info.plist"
SCHEMA = "forge-platform.installer-version/v1"
PRODUCT = "forge-platform-installer"
CHANNELS = frozenset({"stable", "candidate"})
VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
MAXIMUM_NATIVE_SIGNED_INTEGER = (1 << 63) - 1

# This is only a deterministic validation input. It is not a release identity,
# trusted bundle identifier, or a substitute for the protected installer
# release-identity policy.
PROJECTION_BUNDLE_IDENTIFIER = "com.forge-platform.installer.version-projection"
PROJECTION_EXECUTABLE_NAME = "ForgePlatformInstaller"
PROJECTION_SCHEMA = "forge-platform-installer-info-plist-version-projection/v1"
PROJECTION_EXECUTABLE_BYTES = thin_arm64_macho_test_bytes()


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("installer version manifest has duplicate or invalid keys")
        result[key] = value
    return result


def _source_root(root: Path) -> Path:
    try:
        return root.resolve(strict=True)
    except OSError as error:
        raise RuntimeError("installer version source root is unavailable") from error


def _source_file(root: Path, relative_path: Path, label: str) -> Path:
    path = root / relative_path
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"{label} is unreadable")
    return path


def load_manifest(root: Path = ROOT) -> dict[str, Any]:
    """Load the sole installer-version authority from an explicit checkout."""

    source_root = _source_root(root)
    manifest_path = _source_file(source_root, MANIFEST_RELATIVE_PATH, "installer version manifest")
    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("installer version manifest is unreadable") from error
    if not isinstance(value, dict) or set(value) != {"schema", "product", "version", "channel", "capabilities"}:
        raise RuntimeError("installer version manifest fields are invalid")
    if value["schema"] != SCHEMA or value["product"] != PRODUCT:
        raise RuntimeError("installer version manifest identity is invalid")
    version = value["version"]
    if (
        not isinstance(version, str)
        or VERSION.fullmatch(version) is None
        or any(int(component) > MAXIMUM_NATIVE_SIGNED_INTEGER for component in version.split("."))
    ):
        raise RuntimeError("installer version must be stable X.Y.Z")
    if value["channel"] not in CHANNELS:
        raise RuntimeError("installer channel is unsupported")
    capabilities = value["capabilities"]
    if not isinstance(capabilities, list) or not capabilities:
        raise RuntimeError("installer capabilities must be a non-empty list")
    if any(not isinstance(capability, str) or CAPABILITY.fullmatch(capability) is None for capability in capabilities):
        raise RuntimeError("installer capability identity is invalid")
    if len(capabilities) != len(set(capabilities)):
        raise RuntimeError("installer capabilities must be unique")
    return value


def _projection_digest(short_version: str, build_version: str) -> str:
    """Produce a stable semantic identity for the runtime plist projection.

    The raw XML encoding is intentionally not the evidence identity: Python
    and macOS release workers may format XML differently while the two
    code-signed runtime fields retain exactly the same semantics.
    """

    tokens = (
        PROJECTION_SCHEMA,
        f"path={INFO_PLIST_RELATIVE_PATH.as_posix()}",
        f"CFBundleShortVersionString={short_version}",
        f"CFBundleVersion={build_version}",
    )
    return hashlib.sha256("\0".join(tokens).encode("utf-8")).hexdigest()


def packaged_info_plist_projection(
    root: Path,
    manifest: dict[str, Any] | None = None,
) -> dict[str, str]:
    """Run the exact app packager and inspect its resulting runtime plist.

    The probe owns an empty temporary executable and output app only. It does
    not build, sign, publish, install, or retain any artifact. The normal
    packager performs its own output/path admission, so this also detects a
    changed packager interface rather than assuming one.
    """

    source_root = _source_root(root)
    selected_manifest = load_manifest(source_root) if manifest is None else manifest
    version = selected_manifest.get("version")
    if not isinstance(version, str) or VERSION.fullmatch(version) is None:
        raise RuntimeError("installer version manifest returned an invalid version")
    packager = _source_file(source_root, PACKAGER_RELATIVE_PATH, "installer app packager")

    with tempfile.TemporaryDirectory(prefix="forge-platform-installer-version-projection-") as temporary:
        workspace = Path(temporary)
        executable = workspace / PROJECTION_EXECUTABLE_NAME
        cli_executable = workspace / "forge-platform-installer"
        output = workspace / f"{PROJECTION_EXECUTABLE_NAME}.app"
        # The real packager admits only the platform's thin arm64 Mach-O
        # executable shape.  This is a non-runnable header fixture: validation
        # still performs no executable or installer operation.
        executable.write_bytes(PROJECTION_EXECUTABLE_BYTES)
        executable.chmod(0o700)
        cli_executable.write_bytes(PROJECTION_EXECUTABLE_BYTES)
        cli_executable.chmod(0o700)
        environment = dict(os.environ)
        # The probe must be observational with respect to the candidate
        # checkout. In particular, importing the packager must not leave a
        # Python bytecode file that changes version-preparation candidate
        # paths or turns an otherwise clean qualification worktree dirty.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    str(packager),
                    "--executable",
                    str(executable),
                    "--cli-executable",
                    str(cli_executable),
                    "--output",
                    str(output),
                    "--bundle-identifier",
                    PROJECTION_BUNDLE_IDENTIFIER,
                ],
                cwd=source_root,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                env=environment,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise RuntimeError("installer app packager cannot produce a bounded version projection") from error
        if result.returncode != 0:
            # The package helper does not consume credentials and this probe
            # provides no secret input. Keep only bounded diagnostics so a
            # malformed local helper cannot turn version validation into an
            # unbounded log sink.
            diagnostic = (result.stderr or result.stdout).strip().replace("\n", " ")[:512]
            suffix = f": {diagnostic}" if diagnostic else ""
            raise RuntimeError(f"installer app packager failed its version projection probe{suffix}")
        info_plist = output / INFO_PLIST_RELATIVE_PATH
        try:
            with info_plist.open("rb") as stream:
                metadata = plistlib.load(stream)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            raise RuntimeError("installer app packager did not produce a readable Info.plist") from error

    if not isinstance(metadata, dict):
        raise RuntimeError("installer app packager produced an invalid Info.plist")
    short_version = metadata.get("CFBundleShortVersionString")
    build_version = metadata.get("CFBundleVersion")
    if not isinstance(short_version, str) or not isinstance(build_version, str):
        raise RuntimeError("installer app packager omitted runtime version fields from Info.plist")
    if short_version != version or build_version != version:
        raise RuntimeError("installer app packager does not project installer-version.json into Info.plist")
    if metadata.get("CFBundleIdentifier") != PROJECTION_BUNDLE_IDENTIFIER:
        raise RuntimeError("installer app packager changed the checked bundle identifier projection")
    if metadata.get("CFBundleExecutable") != PROJECTION_EXECUTABLE_NAME:
        raise RuntimeError("installer app packager changed the checked executable projection")
    return {
        "schema": PROJECTION_SCHEMA,
        "info_plist_path": INFO_PLIST_RELATIVE_PATH.as_posix(),
        "short_version": short_version,
        "build_version": build_version,
        "sha256": _projection_digest(short_version, build_version),
    }


def validate(root: Path = ROOT, *, expected_version: str | None = None) -> dict[str, str]:
    """Validate the owned manifest and its real package-time projection."""

    manifest = load_manifest(root)
    version = manifest["version"]
    if expected_version is not None:
        if VERSION.fullmatch(expected_version) is None:
            raise RuntimeError("expected installer version must be stable X.Y.Z")
        if version != expected_version:
            raise RuntimeError("installer version manifest does not match the expected version")
    return packaged_info_plist_projection(root, manifest)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--expected-version")
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest(args.source_root)
        projection = validate(args.source_root, expected_version=args.expected_version)
    except RuntimeError as error:
        print(f"INSTALLER_VERSION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "INSTALLER_VERSION=PASS"
        f" version={manifest['version']}"
        f" channel={manifest['channel']}"
        f" capabilities={','.join(manifest['capabilities'])}"
        f" info_plist_projection={projection['schema']}"
        f" info_plist_projection_sha256={projection['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
