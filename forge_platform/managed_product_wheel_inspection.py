"""Read-only, fail-closed inspection of exact frozen Forge/EP pure Python wheels.

The privileged helper supplies bytes only after signed-composition authority,
HTTPS acquisition, and digest-bound private staging. This module never writes
an installed venv, product data, credentials, or a producer-owned state file.
"""

from __future__ import annotations

from base64 import urlsafe_b64encode
from configparser import ConfigParser, Error as ConfigError
from dataclasses import dataclass
from email.parser import Parser
from hashlib import sha256
from io import BytesIO, StringIO
import csv
import json
from pathlib import PurePosixPath
import re
import stat
import zipfile


MAXIMUM_WHEEL_BYTES = 256 * 1024 * 1024
MAXIMUM_EXPANDED_BYTES = 512 * 1024 * 1024
MAXIMUM_MEMBERS = 4_096
MAXIMUM_PATH_BYTES = 1_024
MAXIMUM_MEMBER_BYTES = 64 * 1024 * 1024
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){2}\Z")
_ENTRYPOINTS = {
    "forge-runtime": (
        "forge_autonomy", "forge-autonomy", "forge",
        {"forge": "forge.__main__:main"},
    ),
    "engineering-platform-server": (
        "engineering_platform", "engineering-platform", "engineering_platform",
        {
            "engineering-execution-host": "engineering_platform.__main__:main",
            "engineering-platform": "engineering_platform.submission_cli:main",
            "engineering-platform-host": "engineering_platform.__main__:main",
            "engineering-platform-maintenance": "engineering_platform.central_operational_reset:main",
            "engineering-platform-server": "engineering_platform.server:main",
            "engineering-platform-system-provisioner":
                "engineering_platform.system_instance_provisioner:main",
            "engineering-project-agent": "engineering_platform.project_agent:main",
            "engineering-reconciliation-adopt":
                "engineering_platform.reconciliation_adoption:main",
        },
    ),
}


class ManagedProductWheelInspectionError(ValueError):
    """The exact wheel is missing, malformed, or violates its frozen contract."""


@dataclass(frozen=True)
class ManagedProductWheelMember:
    path: str
    contents: bytes


@dataclass(frozen=True)
class ManagedProductWheelInventory:
    component_identity: str
    version: str
    wheel_sha256: str
    evidence_reference: str
    members: tuple[ManagedProductWheelMember, ...]
    entrypoints: tuple[tuple[str, str], ...]


def inspect_product_wheel(
    wheel: bytes, *, component_identity: str, version: str,
    artifact_sha256: str,
) -> ManagedProductWheelInventory:
    """Verify every archive member and RECORD byte before returning data."""

    if (
        not isinstance(wheel, bytes)
        or not wheel
        or len(wheel) > MAXIMUM_WHEEL_BYTES
        or component_identity not in _ENTRYPOINTS
        or not isinstance(version, str)
        or _VERSION.fullmatch(version) is None
        or not isinstance(artifact_sha256, str)
        or _DIGEST.fullmatch(artifact_sha256) is None
        or "sha256:" + sha256(wheel).hexdigest() != artifact_sha256
    ):
        raise ManagedProductWheelInspectionError("wheel identity is invalid")
    distribution, metadata_name, package_root, expected_entrypoints = _ENTRYPOINTS[
        component_identity
    ]
    dist_info = f"{distribution}-{version}.dist-info"
    try:
        with zipfile.ZipFile(BytesIO(wheel)) as archive:
            entries = archive.infolist()
            if not entries or len(entries) > MAXIMUM_MEMBERS:
                raise ManagedProductWheelInspectionError("wheel inventory is unavailable")
            names: set[str] = set()
            folded: set[str] = set()
            total = 0
            members: list[ManagedProductWheelMember] = []
            for entry in entries:
                name = _member_name(entry.filename, package_root, dist_info)
                if name in names or name.casefold() in folded:
                    raise ManagedProductWheelInspectionError("wheel member is duplicated")
                names.add(name)
                folded.add(name.casefold())
                mode = entry.external_attr >> 16
                if (
                    entry.is_dir()
                    or (mode and not stat.S_ISREG(mode))
                    or entry.flag_bits & 1
                    or entry.file_size < 0
                    or entry.file_size > MAXIMUM_MEMBER_BYTES
                ):
                    raise ManagedProductWheelInspectionError("wheel member type is unsafe")
                total += entry.file_size
                if total > MAXIMUM_EXPANDED_BYTES:
                    raise ManagedProductWheelInspectionError("wheel expansion is too large")
                contents = archive.read(entry)
                if len(contents) != entry.file_size:
                    raise ManagedProductWheelInspectionError("wheel member size changed")
                members.append(ManagedProductWheelMember(name, contents))
            # A file cannot also be an ancestor of another file. This matters
            # on case-insensitive macOS volumes even when the ZIP names differ.
            for name in names:
                parts = name.casefold().split("/")
                if any("/".join(parts[:index]) in folded
                       for index in range(1, len(parts))):
                    raise ManagedProductWheelInspectionError(
                        "wheel member collides with an ancestor"
                    )
    except (zipfile.BadZipFile, OSError, RuntimeError) as error:
        raise ManagedProductWheelInspectionError("wheel archive is unreadable") from error

    by_name = {member.path: member.contents for member in members}
    record_name = f"{dist_info}/RECORD"
    for required in (
        f"{dist_info}/WHEEL", f"{dist_info}/METADATA",
        f"{dist_info}/entry_points.txt", record_name,
    ):
        if required not in by_name:
            raise ManagedProductWheelInspectionError("wheel metadata is incomplete")
    _wheel_metadata(by_name[f"{dist_info}/WHEEL"])
    _package_metadata(by_name[f"{dist_info}/METADATA"], metadata_name, version)
    entrypoints = _console_scripts(
        by_name[f"{dist_info}/entry_points.txt"], expected_entrypoints
    )
    _record(by_name[record_name], by_name, record_name)
    material = {
        "component": component_identity,
        "version": version,
        "wheel": artifact_sha256,
        "members": [
            (item.path, sha256(item.contents).hexdigest())
            for item in sorted(members, key=lambda item: item.path)
        ],
        "entrypoints": list(entrypoints),
    }
    evidence = "sha256:" + sha256(json.dumps(
        material, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ).encode("ascii")).hexdigest()
    return ManagedProductWheelInventory(
        component_identity=component_identity,
        version=version,
        wheel_sha256=artifact_sha256,
        evidence_reference=evidence,
        members=tuple(sorted(members, key=lambda item: item.path)),
        entrypoints=entrypoints,
    )


def _member_name(name: str, package_root: str, dist_info: str) -> str:
    if (
        not isinstance(name, str)
        or not name
        or len(name.encode("utf-8")) > MAXIMUM_PATH_BYTES
        or not name.isascii()
        or "\\" in name
        or name.startswith("/")
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
    ):
        raise ManagedProductWheelInspectionError("wheel member path is unsafe")
    parts = name.split("/")
    if (
        any(part in {"", ".", ".."} for part in parts)
        or str(PurePosixPath(name)) != name
        or parts[0] not in {package_root, dist_info}
        or len(parts) < 2
    ):
        raise ManagedProductWheelInspectionError("wheel member escapes product roots")
    return name


def _wheel_metadata(raw: bytes) -> None:
    try:
        metadata = Parser().parsestr(raw.decode("utf-8"), headersonly=True)
    except UnicodeError as error:
        raise ManagedProductWheelInspectionError("WHEEL metadata is not UTF-8") from error
    expected = {
        "Wheel-Version": "1.0",
        "Root-Is-Purelib": "true",
        "Tag": "py3-none-any",
    }
    if any(metadata.get_all(name) != [value] for name, value in expected.items()):
        raise ManagedProductWheelInspectionError("wheel is not a qualified purelib wheel")


def _package_metadata(raw: bytes, name: str, version: str) -> None:
    try:
        metadata = Parser().parsestr(raw.decode("utf-8"), headersonly=True)
    except UnicodeError as error:
        raise ManagedProductWheelInspectionError("package metadata is not UTF-8") from error
    if (
        metadata.get_all("Name") != [name]
        or metadata.get_all("Version") != [version]
        or metadata.get_all("Requires-Dist") not in (None, [])
    ):
        raise ManagedProductWheelInspectionError("wheel product identity changed")


def _console_scripts(
    raw: bytes, expected: dict[str, str],
) -> tuple[tuple[str, str], ...]:
    try:
        parser = ConfigParser(interpolation=None, strict=True)
        parser.optionxform = str
        parser.read_string(raw.decode("utf-8"))
    except (UnicodeError, ConfigError) as error:
        raise ManagedProductWheelInspectionError("entrypoints are invalid") from error
    if parser.sections() != ["console_scripts"] or dict(parser.items("console_scripts")) != expected:
        raise ManagedProductWheelInspectionError("product entrypoints changed")
    return tuple(sorted(expected.items()))


def _record(raw: bytes, members: dict[str, bytes], record_name: str) -> None:
    try:
        rows = list(csv.reader(StringIO(raw.decode("utf-8")), strict=True))
    except (UnicodeError, csv.Error) as error:
        raise ManagedProductWheelInspectionError("wheel RECORD is invalid") from error
    seen: set[str] = set()
    for row in rows:
        if len(row) != 3 or row[0] in seen or row[0] not in members:
            raise ManagedProductWheelInspectionError("wheel RECORD inventory changed")
        name, digest, size = row
        seen.add(name)
        if name == record_name:
            if digest or size:
                raise ManagedProductWheelInspectionError("RECORD self-hash is invalid")
            continue
        expected_hash = urlsafe_b64encode(sha256(members[name]).digest()).rstrip(b"=").decode()
        if digest != "sha256=" + expected_hash or size != str(len(members[name])):
            raise ManagedProductWheelInspectionError("wheel RECORD bytes changed")
    if seen != set(members):
        raise ManagedProductWheelInspectionError("wheel RECORD is incomplete")
