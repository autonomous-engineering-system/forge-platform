"""Closed companion-package identity and immutable publication readback."""
from hashlib import sha256
import os
from pathlib import Path
import re
import stat
from scripts.verified_installer_helper_package import ASSET_NAME, MAXIMUM_BYTES


def package_metadata(descriptor):
    schema = descriptor.get("schema")
    if schema not in {"forge-platform.installer-release/v1", "forge-platform.installer-release/v2"}:
        raise ValueError("installer release descriptor schema is invalid")
    installer = descriptor.get("installer")
    assets = installer.get("assets") if isinstance(installer, dict) else None
    if not isinstance(assets, list) or len(assets) != 1 or not isinstance(assets[0], dict):
        raise ValueError("companion package requires one exact installer asset")
    present = "helper_package" in assets[0]
    if schema.endswith("/v1"):
        if present:
            raise ValueError("V1 descriptor cannot contain a helper package")
        return None
    value = assets[0].get("helper_package")
    if (not isinstance(value, dict) or set(value) != {"asset_name", "digest", "bytes", "notarization_receipt_reference"}
        or value["asset_name"] != ASSET_NAME
        or not isinstance(value["digest"], str) or re.fullmatch(r"sha256:[0-9a-f]{64}", value["digest"]) is None
        or isinstance(value["bytes"], bool) or not isinstance(value["bytes"], int) or not 0 < value["bytes"] <= MAXIMUM_BYTES
        or not isinstance(value["notarization_receipt_reference"], str)
        or re.fullmatch(r"receipt:[a-z0-9][a-z0-9._-]{0,127}", value["notarization_receipt_reference"]) is None):
        raise ValueError("helper package descriptor is invalid")
    return dict(value)


def require_readback(path: Path, metadata):
    if path.name != ASSET_NAME:
        raise ValueError("helper package readback asset name differs")
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size != metadata["bytes"]):
            raise ValueError("helper package readback file is invalid")
        digest = sha256()
        remaining = before.st_size
        while remaining:
            block = os.read(fd, min(65536, remaining))
            if not block:
                raise ValueError("helper package readback is truncated")
            remaining -= len(block)
            digest.update(block)
        if os.read(fd, 1) or "sha256:" + digest.hexdigest() != metadata["digest"]:
            raise ValueError("helper package readback bytes differ")
        fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        after = os.fstat(fd)
        named = path.lstat()
        if any(getattr(before, f) != getattr(other, f) for f in fields for other in (after, named)):
            raise ValueError("helper package readback identity changed")
        return (before.st_dev, before.st_ino)
    finally:
        os.close(fd)
