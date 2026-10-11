"""Read-only helper-package evidence for the protected release producer.

No signing, installing, credential access or caller-supplied inspection tool.
"""
from hashlib import sha256
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
from scripts.prepare_macos_installer_bootstrap_metadata import _no_acl

ASSET_NAME = "forge-platform-installer-helper-arm64.pkg"
MAXIMUM_BYTES = 512 * 1024 * 1024


def _same(first, second):
    fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    return all(getattr(first, key) == getattr(second, key) for key in fields)


def _observe(tool, arguments):
    # Inspector selection is closed; their output never enters release evidence.
    if tool not in {"/usr/sbin/pkgutil", "/usr/bin/xcrun", "/usr/sbin/spctl"}:
        return None
    try:
        with tempfile.TemporaryFile() as output:
            completed = subprocess.run([tool, *arguments], stdin=subprocess.DEVNULL,
                stdout=output, stderr=output, timeout=20, check=False,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty", "LANG": "C", "LC_ALL": "C"})
            if completed.returncode != 0 or output.tell() > 16 * 1024:
                return None
            output.seek(0)
            return output.read(16 * 1024 + 1).decode("utf-8")
    except (OSError, UnicodeError, subprocess.SubprocessError):
        return None


def _check_platform(path, team):
    signature = _observe("/usr/sbin/pkgutil", ["--check-signature", str(path)])
    if signature is None:
        return False
    lines = [line.strip() for line in signature.splitlines()]
    statuses = [line for line in lines if line.startswith("Status:")]
    leaves = [line for line in lines if line.startswith("1.")]
    if (statuses != ["Status: signed by a developer certificate issued by Apple for distribution"]
        or len(leaves) != 1 or not leaves[0].startswith("1. Developer ID Installer: ")
        or not leaves[0].endswith(" (" + team + ")")):
        return False
    return (_observe("/usr/bin/xcrun", ["stapler", "validate", str(path)]) is not None
        and _observe("/usr/sbin/spctl", ["--assess", "--type", "install", str(path)]) is not None)


def read_descriptor(path: Path, *, team: str, notarization_reference: str, archive: Path, preparation, archive_digest: str) -> dict:
    """Capture digest/size only after actual platform trust and stable readback."""
    if (not isinstance(team, str) or re.fullmatch(r"[A-Z0-9]{10}", team) is None
        or not isinstance(notarization_reference, str)
        or re.fullmatch(r"receipt:[a-z0-9][a-z0-9._-]{0,127}", notarization_reference) is None
        or path.name != ASSET_NAME or path.is_symlink()):
        raise ValueError("helper package identity is invalid")
    path = path.parent.resolve(strict=True) / path.name
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent = os.fstat(directory)
        if parent.st_uid != os.geteuid() or stat.S_IMODE(parent.st_mode) != 0o700 or not _no_acl(directory):
            raise ValueError("helper package parent is not private")
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
        try:
            before = os.fstat(descriptor)
            if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.geteuid()
                or stat.S_IMODE(before.st_mode) != 0o600 or not 0 < before.st_size <= MAXIMUM_BYTES
                or not _no_acl(descriptor)):
                raise ValueError("helper package file is not private and bounded")
            digest = sha256()
            total = 0
            while True:
                block = os.read(descriptor, 64 * 1024)
                if not block:
                    break
                total += len(block)
                if total > before.st_size:
                    raise ValueError("helper package changed during read")
                digest.update(block)
            if total != before.st_size or not _check_platform(path, team):
                raise ValueError("helper package platform trust was not established")
            from scripts.installer_helper_package_payload import verify_payload
            verify_payload(descriptor, archive=archive, preparation=preparation, archive_digest=archive_digest)
            if (not _same(before, os.fstat(descriptor))
                or not _same(before, os.stat(path.name, dir_fd=directory, follow_symlinks=False))
                or not _same(parent, os.fstat(directory)) or not _same(parent, path.parent.lstat())
                or not _no_acl(descriptor) or not _no_acl(directory)):
                raise ValueError("helper package identity changed during inspection")
            return {"asset_name": ASSET_NAME, "digest": "sha256:" + digest.hexdigest(),
                "bytes": total, "notarization_receipt_reference": notarization_reference}
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)
