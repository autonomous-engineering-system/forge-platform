"""Exact bundled Forge 2.7.38 update resources for the privileged worker.

The native helper first verifies its signed parent and worker bytes. This
reader independently binds the fixed sibling resource paths and Info.plist
claims before those paths can enter a product-owned update request.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import os
from pathlib import Path
import plistlib
import stat


_CONTROLLER_SOURCE = "bf7ae99c67e32fd2047965f19ece30a35071e868"
_CONTROLLER_DIGEST = "sha256:9c43e1c3dcb411fb5f81a6a70d99b0c28b6bb2c79117f70703a50037e2e78183"
_RELEASE_SOURCE = "0a3d6e35b01da93bb5a674ae7795558655c16c7d"
_RELEASE_DIGEST = "sha256:7f8f4646a369ea565e52f8420df665acb64d032e5004e1b45ef7dc8427548c49"
_WORKER_NAME = "forge-platform-product-worker.pyz"
_CONTROLLER_NAME = "forge-update-controller.py"
_RECEIPT_NAME = "forge-release-complete-2.7.38.json"
_BUNDLE_IDENTIFIER = "com.autonomous-engineering-system.forge-platform-installer"


class ForgeUpdateResourceError(RuntimeError):
    """The code-sealed worker cannot prove its exact Forge update resources."""


@dataclass(frozen=True)
class ForgeUpdateResources:
    controller: Path
    release_receipt: Path


def _read_stable(path: Path, maximum: int) -> bytes:
    if not path.is_absolute() or path.is_symlink():
        raise ForgeUpdateResourceError("Forge update resource path is unsafe")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ForgeUpdateResourceError("Forge update resource path crosses a symlink")
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid not in {0, os.getuid()}
            or before.st_mode & 0o022
            or not 0 < before.st_size <= maximum
        ):
            raise ForgeUpdateResourceError("Forge update resource has unsafe metadata")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1_024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            len(data) != before.st_size
            or len(data) > maximum
            or (before.st_dev, before.st_ino, before.st_size,
                before.st_mtime_ns, before.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_size,
                after.st_mtime_ns, after.st_ctime_ns)
        ):
            raise ForgeUpdateResourceError("Forge update resource changed during readback")
        return data
    except OSError as error:
        raise ForgeUpdateResourceError("Forge update resource is unavailable") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_forge_update_resources(worker: Path) -> ForgeUpdateResources:
    """Return only exact controller/receipt siblings of the invoked worker."""
    if (
        not isinstance(worker, Path)
        or not worker.is_absolute()
        or worker.name != _WORKER_NAME
        or worker.parent.name != "Resources"
        or worker.parent.parent.name != "Contents"
        or worker.parent.parent.parent.suffix != ".app"
    ):
        raise ForgeUpdateResourceError("Forge update worker bundle layout is invalid")
    resources = worker.parent
    info = worker.parent.parent / "Info.plist"
    _read_stable(worker, 16 * 1_024 * 1_024)
    try:
        metadata = plistlib.loads(_read_stable(info, 1 * 1_024 * 1_024))
    except (ValueError, TypeError) as error:
        raise ForgeUpdateResourceError("Forge update app metadata is invalid") from error
    if (
        not isinstance(metadata, dict)
        or metadata.get("CFBundleIdentifier") != _BUNDLE_IDENTIFIER
        or metadata.get("ForgePlatformForgeUpdateControllerSourceRevision") != _CONTROLLER_SOURCE
        or metadata.get("ForgePlatformForgeUpdateControllerSHA256") != _CONTROLLER_DIGEST
        or metadata.get("ForgePlatformForgeReleaseSourceRevision") != _RELEASE_SOURCE
        or metadata.get("ForgePlatformForgeReleaseCompleteSHA256") != _RELEASE_DIGEST
    ):
        raise ForgeUpdateResourceError("Forge update app metadata changed")
    controller = resources / _CONTROLLER_NAME
    receipt = resources / _RECEIPT_NAME
    if "sha256:" + sha256(_read_stable(controller, 512 * 1_024)).hexdigest() != _CONTROLLER_DIGEST:
        raise ForgeUpdateResourceError("Forge update controller bytes changed")
    if "sha256:" + sha256(_read_stable(receipt, 64 * 1_024)).hexdigest() != _RELEASE_DIGEST:
        raise ForgeUpdateResourceError("Forge release receipt bytes changed")
    return ForgeUpdateResources(controller, receipt)
