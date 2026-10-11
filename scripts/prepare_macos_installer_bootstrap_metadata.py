#!/usr/bin/env python3
"""Prepare public link inputs only; never sign, bless, install or activate."""
from __future__ import annotations

import argparse
import base64
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
from package_macos_installer_app import (  # noqa: E402
    _sealed_release_provenance_resource,
    _sealed_release_trust_resource,
)

LABEL = "com.autonomous-engineering-system.forge-platform-installer.bootstrap"
APP_IDENTIFIER = "com.autonomous-engineering-system.forge-platform-installer"
TEAM = "ZEML4LPXH4"
SCHEMA = "forge-platform.installer-bootstrap/v1"


def requirement(identifier: str) -> str:
    if identifier not in {LABEL, APP_IDENTIFIER}:
        raise ValueError("bootstrap requirement identifier is not admitted")
    return (
        f'anchor apple generic and identifier "{identifier}" and '
        'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
        'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
        f'certificate leaf[subject.OU] = "{TEAM}"'
    )


def _library():
    return ctypes.CDLL("/usr/lib/libSystem.B.dylib" if sys.platform == "darwin" else None, use_errno=True)


def _no_acl(descriptor: int) -> bool:
    if sys.platform != "darwin":
        return "system.posix_acl_access" not in os.listxattr(descriptor)
    library = _library()
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    library.acl_free.argtypes = [ctypes.c_void_p]
    ctypes.set_errno(0)
    acl = library.acl_get_fd_np(descriptor, 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        return ctypes.get_errno() == errno.ENOENT
    try:
        entry = ctypes.c_void_p()
        ctypes.set_errno(0)
        return library.acl_get_entry(acl, 0, ctypes.byref(entry)) == -1 and ctypes.get_errno() == errno.EINVAL
    finally:
        library.acl_free(acl)


def _directory_bound(descriptor: int, path: Path) -> None:
    held, named = os.fstat(descriptor), path.lstat()
    if (not stat.S_ISDIR(held.st_mode) or held.st_uid != os.geteuid()
        or stat.S_IMODE(held.st_mode) != 0o700 or not _no_acl(descriptor)
        or (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino)
        or not stat.S_ISDIR(named.st_mode)):
        raise ValueError("bootstrap output directory identity changed")


def _publish_exclusively(source: Path, destination: Path) -> None:
    library = _library()
    if sys.platform == "darwin":
        function = library.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = function(os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    else:
        function = library.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, "exclusive bootstrap output publication failed")


def link_payloads(policy, release) -> dict[str, bytes]:
    """Derive exact public metadata from already parsed release resources."""
    if (policy.expected_bundle_identifier != APP_IDENTIFIER
        or policy.expected_team_identifier != TEAM
        or policy.repository != "autonomous-engineering-system/forge-platform"
        or release.release_trust_configuration_sha256 != policy.configuration_sha256):
        raise ValueError("bootstrap public release policy does not match")
    info = {
        "CFBundleIdentifier": LABEL,
        "CFBundleVersion": release.installer_version,
        "CFBundleShortVersionString": release.installer_version,
        "SMAuthorizedClients": [requirement(APP_IDENTIFIER)],
        "FPIBootstrapSchema": SCHEMA,
        "FPIReleaseTrustResource": base64.b64encode(policy.contents).decode("ascii"),
        "FPIReleaseProvenanceResource": base64.b64encode(release.contents).decode("ascii"),
    }
    launchd = {"Label": LABEL, "MachServices": {LABEL: True}}
    application = {"SMPrivilegedExecutables": {LABEL: requirement(LABEL)}}
    files = {
        "bootstrap-info.plist": plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True),
        "bootstrap-launchd.plist": plistlib.dumps(launchd, fmt=plistlib.FMT_XML, sort_keys=True),
        "application-requirements.plist": plistlib.dumps(application, fmt=plistlib.FMT_XML, sort_keys=True),
    }
    return files


def prepare(*, trust: Path, provenance: Path, output: Path) -> dict[str, object]:
    policy = _sealed_release_trust_resource(str(trust))
    release = _sealed_release_provenance_resource(str(provenance))
    files = link_payloads(policy, release)
    if any(len(data) > 128 * 1024 for data in files.values()):
        raise ValueError("bootstrap metadata exceeds bound")
    # New private output only; retain incomplete output after a write failure.
    # Never remove or overwrite an existing or concurrently substituted path.
    parent = output.parent.resolve(strict=True)
    output = parent / output.name
    if os.path.lexists(output):
        raise FileExistsError("bootstrap output already exists")
    stage = Path(tempfile.mkdtemp(prefix=".fpi-bootstrap-metadata-", dir=parent))
    directory = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _directory_bound(directory, stage)
        identities = {}
        def write(name: str, data: bytes) -> None:
            descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
                identities[name] = os.fstat(stream.fileno())
        for name, data in files.items():
            write(name, data)
        receipt = {
            "schema": SCHEMA,
            "status": "UNSIGNED_LINK_INPUT_ONLY",
            "production_admitted": False,
            "installer_version": release.installer_version,
            "release_sequence": release.release_sequence,
            "source_revision": release.source_revision,
            "release_trust_configuration_sha256": policy.configuration_sha256,
            "provenance_sha256": release.provenance_sha256,
            "files": {name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                      for name, data in files.items()},
        }
        os.fsync(directory)
        write("receipt.json", (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode("utf-8"))
        os.fsync(directory)
        _directory_bound(directory, stage)
        _publish_exclusively(stage, output)
        parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
        _directory_bound(directory, output)
        for name, expected in identities.items():
            descriptor = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
            try:
                actual = os.fstat(descriptor)
                fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
                if (any(getattr(actual, field) != getattr(expected, field) for field in fields)
                    or not stat.S_ISREG(actual.st_mode) or actual.st_nlink != 1
                    or actual.st_uid != os.geteuid() or stat.S_IMODE(actual.st_mode) != 0o600
                    or not _no_acl(descriptor)):
                    raise ValueError("bootstrap output file identity changed")
            finally:
                os.close(descriptor)
        _directory_bound(directory, output)
        return receipt
    finally:
        os.close(directory)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-trust", required=True, type=Path)
    parser.add_argument("--release-provenance", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(trust=args.release_trust, provenance=args.release_provenance, output=args.output)
    except (OSError, ValueError):
        parser.exit(1, "BOOTSTRAP_METADATA=FAIL\n")
    print("BOOTSTRAP_METADATA=UNSIGNED_LINK_INPUT_ONLY")


if __name__ == "__main__":
    main()
