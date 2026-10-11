#!/usr/bin/env python3
"""Build an unsigned, nondeployable helper-package candidate from a verified app.

This producer never installs, registers, starts, stops, signs, notarizes or
publishes a helper. The package deliberately has no installation scripts.
Production package admission and lifecycle support remain separate gates.
"""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
from package_macos_installer_archive import _scan_bundle, _source_bundle, _same_snapshot
from forge_platform.installer_release_provenance import (
    INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME,
    parse_installer_release_provenance_bytes,
)

TEAM = "ZEML4LPXH4"
BUNDLE_ID = "com.autonomous-engineering-system.forge-platform-installer"
LABEL = BUNDLE_ID + ".helper"
APP_RELATIVE = "Library/Application Support/ForgePlatformInstallerHelper/ForgePlatformInstaller.app"
HELPER_PROGRAM = "/" + APP_RELATIVE + "/Contents/Resources/forge-platform-installer-helper"
PLIST_RELATIVE = "Library/LaunchDaemons/" + LABEL + ".plist"
MAXIMUM_PACKAGE_BYTES = 512 * 1024 * 1024


def package_launchdaemon() -> dict:
    return {
        "Label": LABEL,
        "ProgramArguments": [HELPER_PROGRAM],
        "AssociatedBundleIdentifiers": BUNDLE_ID,
        "MachServices": {name: True for name in (
            LABEL, LABEL + ".product-operations", LABEL + ".released-route"
        )},
    }


def package_components() -> list[dict]:
    # A same-identifier app already exists in Applications/self-update staging.
    # Relocation must never redirect this machine-owned helper payload there.
    return [{
        "RootRelativeBundlePath": APP_RELATIVE,
        "BundleIsRelocatable": False,
        "BundleHasStrictIdentifier": True,
        "BundleIsVersionChecked": True,
        "BundleOverwriteAction": "upgrade",
    }]


def run_checked(arguments: list[str]) -> None:
    result = subprocess.run(arguments, capture_output=True, timeout=120)
    if result.returncode != 0:
        # Only fixed executable names enter diagnostics; no captured contents.
        raise ValueError("helper package prerequisite failed: " + Path(arguments[0]).name)


def verify_app(app: Path, *, version: str, source_revision: str) -> str:
    _scan_bundle(app)  # Existing strict arm64 layout, bounds and no-link profile.
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    provenance = parse_installer_release_provenance_bytes(
        (app / "Contents/Resources" / INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME).read_bytes()
    )
    if (info.get("CFBundleIdentifier") != BUNDLE_ID
            or info.get("CFBundleShortVersionString") != version
            or provenance.installer_version != version
            or provenance.source_revision != source_revision):
        raise ValueError("helper package app differs from exact reviewed release")
    run_checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    for code, identifier in (
        (app, BUNDLE_ID),
        (app / "Contents/Resources/forge-platform-installer-helper", LABEL),
    ):
        requirement = ('anchor apple generic and certificate leaf[subject.OU] = "'
                       + TEAM + '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
                       + ' and identifier "' + identifier + '"')
        run_checked(["/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, str(code)])
    run_checked(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    run_checked(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
    return provenance.provenance_sha256




def copy_public_app_without_local_attributes(source: Path, destination: Path) -> None:
    """Copy exact public app bytes/modes, without importing local xattrs/ACLs."""
    entries = _scan_bundle(source)
    destination.mkdir(mode=0o755)
    for entry in entries:
        parts = entry.archive_path.split("/", 1)
        if len(parts) == 1:
            destination.chmod(entry.permissions)
            continue
        target = destination / parts[1]
        if entry.kind == "directory":
            target.mkdir(mode=entry.permissions)
            target.chmod(entry.permissions)
            continue
        descriptor = os.open(entry.source, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            if not _same_snapshot(os.fstat(descriptor), entry):
                raise ValueError("helper source app changed before copy")
            remaining = entry.size
            with target.open("xb") as output:
                while remaining:
                    data = os.read(descriptor, min(remaining, 65536))
                    if not data:
                        raise ValueError("helper source app truncated during copy")
                    output.write(data)
                    remaining -= len(data)
            if os.read(descriptor, 1) or not _same_snapshot(os.fstat(descriptor), entry):
                raise ValueError("helper source app changed during copy")
            target.chmod(entry.permissions)
        finally:
            os.close(descriptor)


def strip_staged_metadata(payload: Path) -> None:
    """Drop removable local attributes only from this private payload copy.

    macOS may retain its protected provenance attribute. This prototype does
    not claim a metadata-free production package or change security controls.
    """
    for current, directories, files in os.walk(payload, followlinks=False):
        for path in [Path(current), *(Path(current) / name for name in files)]:
            details = os.lstat(path)
            if not (stat.S_ISREG(details.st_mode) or stat.S_ISDIR(details.st_mode)):
                raise ValueError("helper package payload contains a nonregular entry")
            run_checked(["/usr/bin/xattr", "-c", str(path)])
            observed = subprocess.run(["/usr/bin/xattr", str(path)], capture_output=True, timeout=10)
            if observed.returncode != 0 or set(observed.stdout.decode("utf-8").splitlines()) - {"com.apple.provenance"}:
                raise ValueError("helper package local metadata could not be removed")
        for name in directories:
            if (Path(current) / name).is_symlink():
                raise ValueError("helper package payload contains a symlink")


def publish_candidate(candidate: Path, destination: Path) -> tuple[str, int]:
    """Publish complete bytes exclusively; never expose a partial package."""
    descriptor = os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or not 0 < before.st_size <= MAXIMUM_PACKAGE_BYTES):
            raise ValueError("helper package candidate is not a bounded regular file")
        os.fchmod(descriptor, 0o600)
        digest = sha256()
        total = 0
        for block in iter(lambda: os.read(descriptor, 1024 * 1024), b""):
            total += len(block)
            if total > before.st_size:
                raise ValueError("helper package changed during publication")
            digest.update(block)
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        leaf = os.lstat(candidate)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_size,
                                  value.st_mtime_ns)
        if (total != before.st_size or identity(before) != identity(after)
                or identity(after) != identity(leaf) or after.st_nlink != 1
                or stat.S_IMODE(after.st_mode) != 0o600):
            raise ValueError("helper package changed during publication")
        # The staged file is inside a private workspace on the same filesystem.
        # link is atomic and exclusive even when a competing destination appears.
        os.link(candidate, destination, follow_symlinks=False)
        final = os.lstat(destination)
        if (identity(final) != identity(after) or final.st_nlink != 2
                or stat.S_IMODE(final.st_mode) != 0o600):
            raise ValueError("helper package publication identity changed")
        parent = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
        return digest.hexdigest(), total
    # A failure after exclusive publication leaves complete but unacknowledged
    # output. Never unlink a shared pathname: another writer may replace it
    # after an identity check. The caller gets no success receipt.
    finally:
        os.close(descriptor)


def build_candidate(*, app_bundle: Path, output: Path,
                    version: str, source_revision: str) -> dict:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("helper package version is invalid")
    if not re.fullmatch(r"[0-9a-f]{40}", source_revision):
        raise ValueError("helper package source revision is invalid")
    source = _source_bundle(str(app_bundle))
    destination = output.parent.resolve(strict=True) / output.name
    if destination.suffix != ".pkg" or os.path.lexists(destination):
        raise ValueError("helper package output must be a new .pkg file")
    if destination.is_relative_to(source):
        raise ValueError("helper package output must be outside the source app")
    provenance_sha256 = verify_app(source, version=version, source_revision=source_revision)
    with tempfile.TemporaryDirectory(prefix="fpi-helper-package-", dir=destination.parent) as temporary:
        workspace = Path(temporary)
        payload = workspace / "payload"
        staged_app = payload / APP_RELATIVE
        staged_app.parent.mkdir(parents=True)
        # Retain links if the source changes unexpectedly; the second profile
        # scan rejects them instead of dereferencing them outside this bundle.
        copy_public_app_without_local_attributes(source, staged_app)
        if verify_app(staged_app, version=version, source_revision=source_revision) != provenance_sha256:
            raise ValueError("helper package provenance changed during staging")
        daemon = payload / PLIST_RELATIVE
        daemon.parent.mkdir(parents=True)
        daemon.write_bytes(plistlib.dumps(package_launchdaemon(), fmt=plistlib.FMT_XML, sort_keys=True))
        daemon.chmod(0o644)
        strip_staged_metadata(payload)
        # Parent directories contain only public package payload. Their installed
        # modes must be explicit even under the private signer's umask 077.
        for current, directories, files in os.walk(payload):
            Path(current).chmod(0o755)
        # Notarization and signature must still be valid after sanitizing only
        # the fresh payload copy. Never modify the retained source release.
        if verify_app(staged_app, version=version, source_revision=source_revision) != provenance_sha256:
            raise ValueError("helper package sealed app changed during metadata normalization")
        components = workspace / "components.plist"
        components.write_bytes(plistlib.dumps(package_components(), fmt=plistlib.FMT_XML, sort_keys=True))
        candidate = workspace / "candidate.pkg"
        run_checked(["/usr/bin/pkgbuild", "--root", str(payload),
                     "--component-plist", str(components), "--install-location", "/",
                     "--ownership", "recommended", "--compression", "legacy", "--identifier", BUNDLE_ID + ".helper-package",
                     "--version", version, str(candidate)])
        digest, size = publish_candidate(candidate, destination)
        return {"status": "UNSIGNED_CANDIDATE_ONLY", "installer_version": version,
                "source_revision": source_revision, "provenance_sha256": provenance_sha256,
                "package_sha256": digest, "package_bytes": size,
                "app_install_path": "/" + APP_RELATIVE, "launchdaemon_path": "/" + PLIST_RELATIVE,
                "installation_scripts": False, "production_admitted": False,
                "metadata_profile": "removable-attributes-cleared-os-provenance-may-remain"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-revision", required=True)
    args = parser.parse_args()
    try:
        receipt = build_candidate(app_bundle=args.app_bundle, output=args.output,
                                  version=args.version, source_revision=args.source_revision)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(2, f"helper package candidate failed: {error}\n")
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    main()
