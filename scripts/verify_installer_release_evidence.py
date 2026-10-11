#!/usr/bin/env python3
"""Bind a signed-descriptor handoff to exact installer release evidence.

This is intentionally a structural evidence verifier, not a cryptographic
signer or trust-root implementation.  A protected signing/notarization stage
must cryptographically verify the descriptor's structured public signature
envelopes and Apple evidence before it supplies the opaque qualification
receipt retained by ``InstallerReleaseOperation``.  This script enforces the
same reviewed key-ID/threshold envelope policy, then makes sure that the
supplied descriptor, exact archive bytes, candidate source, and durable
operation describe the same release identity.  It never downloads, signs,
notarizes, or publishes an artifact.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import sys
from typing import Mapping
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    InstallerReleaseOperation,
    InstallerReleaseOperationError,
)
from forge_platform.composition_catalog_trust import (  # noqa: E402
    COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES,
    COMPOSITION_CATALOG_TRUST_RESOURCE_NAME,
    CompositionCatalogTrust,
    parse_composition_catalog_trust_bytes,
)
from forge_platform.installer_release_provenance import (  # noqa: E402
    INSTALLER_RELEASE_PROVENANCE_MAXIMUM_BYTES,
    INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME,
    InstallerReleaseProvenance,
    parse_installer_release_provenance_bytes,
)
from forge_platform.installer_release_trust import (  # noqa: E402
    INSTALLER_RELEASE_TRUST_MAXIMUM_BYTES,
    INSTALLER_RELEASE_TRUST_RESOURCE_NAME,
    InstallerReleaseTrust,
    parse_installer_release_trust_bytes,
)
from forge_platform.universal_installer import (  # noqa: E402
    MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES,
    SignatureThresholdPolicy,
    canonical_https_url,
    parse_public_signature_envelopes,
)
from forge_platform.macos_platform_contract import (  # noqa: E402
    INSTALLER_ARCHITECTURE,
    INSTALLER_ARCHITECTURES,
    MINIMUM_MACOS_SEMANTIC_VERSION,
    MINIMUM_MACOS_VERSION,
    require_thin_arm64_macho_header,
)


_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
_SEMVER = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_RAW_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
_ARCHITECTURES = INSTALLER_ARCHITECTURES
_CHANNELS = frozenset({"stable", "candidate"})
_GITHUB_REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
_GITHUB_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_DESCRIPTOR_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,122}\.json$")
_ARCHIVE_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,123}\.zip$")
_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_TEAM_IDENTIFIER = re.compile(r"^[A-Z0-9]{10}$")
_RECEIPT_REFERENCE = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_ARCHIVE_APP_BUNDLE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,122}\.app$")
_MAXIMUM_OPERATION_BYTES = 512 * 1024


@dataclass(frozen=True)
class InstallerReleaseEvidenceVerification:
    """One verified release operation plus optional catalog-policy evidence.

    ``catalog_trust_status`` describes only the code-signed public policy in
    the archive. It is not evidence that a catalog was fetched, accepted,
    selected, or used to authorize a component operation.
    """

    operation: InstallerReleaseOperation
    catalog_trust_status: str


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON value is not permitted: {value}")


def _unique_pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("JSON has duplicate or invalid object keys")
        result[key] = value
    return result


def _strict_object(raw_bytes: bytes, label: str) -> Mapping[str, object]:
    try:
        parsed = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=_unique_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"{label} is not strict JSON") from error
    if not isinstance(parsed, Mapping):
        raise ValueError(f"{label} root must be an object")
    return parsed


def _mapping(value: object, expected: frozenset[str], label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != expected:
        raise ValueError(f"{label} fields are invalid")
    return value


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} is required")
    return value


def _digest(value: object, label: str) -> str:
    result = _string(value, label)
    if _DIGEST.fullmatch(result) is None:
        raise ValueError(f"{label} must be a SHA-256 identity")
    return result


def _raw_sha256(value: object, label: str) -> str:
    result = _string(value, label)
    if _RAW_SHA256.fullmatch(result) is None:
        raise ValueError(f"{label} must be a raw lowercase SHA-256 identity")
    return result


def _https_url(value: object, label: str) -> str:
    return canonical_https_url(value, label)


def _timestamp(value: object, label: str) -> datetime:
    result = _string(value, label)
    try:
        parsed = datetime.fromisoformat(result.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{label} must be an RFC3339 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must include a timezone")
    return parsed


def _read_regular_non_symlink_file(
    value: str,
    *,
    label: str,
    maximum_bytes: int,
) -> tuple[Path, bytes]:
    """Capture a bounded CLI evidence input without following its leaf.

    The exact bytes are parsed immediately after this function returns. A
    caller-selected FIFO, device, directory, empty file, oversized file or
    symlink is not a release evidence input. Ancestor symlinks are normalized
    intentionally (including macOS ``/tmp``); the selected leaf is not.
    """

    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    try:
        parent = supplied.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"{label} does not exist") from error
    path = parent / supplied.name
    if path.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise ValueError(f"{label} cannot be opened safely on this platform")
    flags = os.O_RDONLY | os.O_NONBLOCK | nofollow | getattr(os, "O_CLOEXEC", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError(f"{label} cannot be opened safely") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"{label} must be a regular file")
        if before.st_size < 1 or before.st_size > maximum_bytes:
            raise ValueError(f"{label} has an unsupported size")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(maximum_bytes + 1)
        after = os.fstat(descriptor)
        if (
            len(contents) > maximum_bytes
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{label} changed while it was being read")
        return path, contents
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _archive_arguments(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        architecture, separator, raw_path = value.partition("=")
        if not separator or architecture not in _ARCHITECTURES or not raw_path:
            raise ValueError("archive must use a supported architecture=path identity")
        if architecture in result:
            raise ValueError("archive architecture was supplied more than once")
        supplied = Path(raw_path).expanduser()
        if supplied.is_symlink():
            raise ValueError("archive path must not be selected through a symlink")
        candidate = supplied.resolve(strict=True)
        if not candidate.is_file():
            raise ValueError("archive path must resolve to a regular file")
        result[architecture] = candidate
    if set(result) != set(_ARCHITECTURES):
        raise ValueError("exactly one arm64 archive is required")
    return dict(sorted(result.items()))


def _file_digest(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return "sha256:" + digest.hexdigest()


def _archive_platform_contract(path: Path) -> None:
    """Require one macOS-26 app containing one thin arm64 executable."""

    try:
        with zipfile.ZipFile(path) as archive:
            executable_entries = [
                entry
                for entry in archive.infolist()
                if entry.filename.endswith("/Contents/MacOS/ForgePlatformInstaller")
            ]
            if len(executable_entries) != 1:
                raise ValueError("installer archive must contain exactly one installer executable")
            executable = executable_entries[0]
            executable_parts = executable.filename.split("/")
            if (
                len(executable_parts) != 4
                or _ARCHIVE_APP_BUNDLE_NAME.fullmatch(executable_parts[0]) is None
                or executable_parts[1:] != ["Contents", "MacOS", "ForgePlatformInstaller"]
            ):
                raise ValueError("installer archive executable path is invalid")
            executable_mode = executable.external_attr >> 16
            if (
                executable.is_dir()
                or stat.S_IFMT(executable_mode) != stat.S_IFREG
                or not executable_mode & stat.S_IXUSR
            ):
                raise ValueError("installer archive executable must be a regular executable file")
            with archive.open(executable, "r") as stream:
                require_thin_arm64_macho_header(
                    stream.read(32),
                    "installer archive executable",
                )

            plist_path = f"{executable_parts[0]}/Contents/Info.plist"
            plist_entries = [entry for entry in archive.infolist() if entry.filename == plist_path]
            if len(plist_entries) != 1 or plist_entries[0].file_size > 1024 * 1024:
                raise ValueError("installer archive must contain one bounded Info.plist")
            plist_entry = plist_entries[0]
            plist_mode = plist_entry.external_attr >> 16
            if plist_entry.is_dir() or stat.S_IFMT(plist_mode) != stat.S_IFREG:
                raise ValueError("installer archive Info.plist must be a regular file")
            with archive.open(plist_entry, "r") as stream:
                plist_bytes = stream.read((1024 * 1024) + 1)
            if len(plist_bytes) > 1024 * 1024:
                raise ValueError("installer archive Info.plist exceeds its maximum size")
            metadata = plistlib.loads(plist_bytes)
            if (
                not isinstance(metadata, dict)
                or metadata.get("CFBundleExecutable") != "ForgePlatformInstaller"
                or metadata.get("LSMinimumSystemVersion") != MINIMUM_MACOS_VERSION
            ):
                raise ValueError("installer archive does not declare the macOS 26 executable contract")
    except (OSError, RuntimeError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        raise ValueError("installer archive platform contract cannot be inspected safely") from error


def _bundled_resource_bytes(
    path: Path,
    *,
    resource_name: str,
    maximum_bytes: int,
    resource_label: str,
    required: bool = True,
) -> bytes | None:
    """Read one bounded app resource from an archive without extraction.

    A protected evidence handoff must prove the bytes which will actually be
    code-signed inside the archive, rather than accepting an adjacent JSON
    file or an operation's asserted digest. Archive traversal paths, duplicate
    resources and resource symlinks are rejected even though this verifier
    never extracts the zip.
    """

    try:
        with zipfile.ZipFile(path) as archive:
            candidates: list[zipfile.ZipInfo] = []
            selected_components: list[str] | None = None
            for entry in archive.infolist():
                if not entry.filename.endswith(resource_name):
                    continue
                components = entry.filename.split("/")
                if (
                    len(components) != 4
                    or _ARCHIVE_APP_BUNDLE_NAME.fullmatch(components[0]) is None
                    or components[1:]
                    != ["Contents", "Resources", resource_name]
                ):
                    raise ValueError(f"archive {resource_label} resource path is invalid")
                candidates.append(entry)
                selected_components = components
            if not candidates and not required:
                return None
            if len(candidates) != 1:
                raise ValueError(f"archive must contain exactly one bundled {resource_label} resource")
            resource = candidates[0]
            assert selected_components is not None
            ancestor_names = {
                "/".join(selected_components[:index])
                for index in range(1, len(selected_components) - 1)
            }
            for entry in archive.infolist():
                entry_name = entry.filename[:-1] if entry.is_dir() else entry.filename
                if entry_name not in ancestor_names:
                    continue
                unix_mode = entry.external_attr >> 16
                file_kind = stat.S_IFMT(unix_mode)
                if (
                    not entry.is_dir()
                    or file_kind == stat.S_IFLNK
                    or (file_kind and file_kind != stat.S_IFDIR)
                ):
                    raise ValueError(
                        f"archive {resource_label} resource ancestor must be a directory, never a symlink"
                    )
            unix_mode = resource.external_attr >> 16
            file_kind = stat.S_IFMT(unix_mode)
            if (
                resource.is_dir()
                or file_kind == stat.S_IFLNK
                or (file_kind and file_kind != stat.S_IFREG)
            ):
                raise ValueError(f"archive {resource_label} resource must be a regular non-symlink file")
            if resource.file_size > maximum_bytes:
                raise ValueError(f"archive {resource_label} resource exceeds its maximum size")
            with archive.open(resource, "r") as stream:
                contents = stream.read(maximum_bytes + 1)
            if len(contents) > maximum_bytes:
                raise ValueError(f"archive {resource_label} resource exceeds its maximum size")
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise ValueError("installer archive cannot be inspected safely") from error
    return contents


def _bundled_release_provenance(path: Path) -> InstallerReleaseProvenance:
    contents = _bundled_resource_bytes(
        path,
        resource_name=INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME,
        maximum_bytes=INSTALLER_RELEASE_PROVENANCE_MAXIMUM_BYTES,
        resource_label="provenance",
    )
    assert contents is not None
    return parse_installer_release_provenance_bytes(
        contents,
        label="archive provenance resource",
    )


def _bundled_release_trust(path: Path) -> InstallerReleaseTrust:
    contents = _bundled_resource_bytes(
        path,
        resource_name=INSTALLER_RELEASE_TRUST_RESOURCE_NAME,
        maximum_bytes=INSTALLER_RELEASE_TRUST_MAXIMUM_BYTES,
        resource_label="release trust",
    )
    assert contents is not None
    return parse_installer_release_trust_bytes(
        contents,
        label="archive release trust resource",
    )


def _bundled_composition_catalog_trust(path: Path) -> CompositionCatalogTrust | None:
    """Read the optional V1 policy without creating a catalog authority."""

    contents = _bundled_resource_bytes(
        path,
        resource_name=COMPOSITION_CATALOG_TRUST_RESOURCE_NAME,
        maximum_bytes=COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES,
        resource_label="composition catalog trust",
        required=False,
    )
    if contents is None:
        return None
    return parse_composition_catalog_trust_bytes(
        contents,
        label="archive composition catalog trust resource",
    )


def _archive_trust_binds_operation(
    path: Path,
    operation: InstallerReleaseOperation,
) -> InstallerReleaseTrust:
    """Bind all semantic V2 trust facts to the reviewed release identity."""

    trust = _bundled_release_trust(path)
    identity = operation.release_identity
    if trust.configuration_sha256 != identity.release_trust_configuration_sha256:
        raise ValueError("archive trust configuration does not bind the reviewed identity")
    if trust.repository != identity.github_repository:
        raise ValueError("archive trust repository does not bind the reviewed identity")
    if trust.release_descriptor_asset_name != identity.release_descriptor_asset_name:
        raise ValueError("archive trust descriptor asset name does not bind the reviewed identity")
    if trust.expected_bundle_identifier != identity.bundle_identifier:
        raise ValueError("archive trust bundle identifier does not bind the reviewed identity")
    if trust.expected_team_identifier != identity.team_identifier:
        raise ValueError("archive trust Apple Team identifier does not bind the reviewed identity")
    if trust.signature_threshold != identity.signature_threshold:
        raise ValueError("archive trust signature threshold does not bind the reviewed identity")
    if trust.signature_key_ids != identity.signature_key_ids:
        raise ValueError("archive trust signing key identities do not bind the reviewed identity")
    return trust


def _archive_catalog_trust_binds_operation(
    path: Path,
    operation: InstallerReleaseOperation,
    release_trust: InstallerReleaseTrust,
) -> str | None:
    """Bind an optional catalog policy to the exact current-bundle V2 scope."""

    catalog_trust = _bundled_composition_catalog_trust(path)
    if catalog_trust is None:
        return None
    if (
        catalog_trust.installer_release_trust_configuration_sha256
        != release_trust.configuration_sha256
        or catalog_trust.installer_release_trust_configuration_sha256
        != operation.release_identity.release_trust_configuration_sha256
    ):
        raise ValueError(
            "archive composition catalog trust release trust configuration does not bind the reviewed identity"
        )
    return catalog_trust.configuration_sha256


def _archive_provenance_binds_operation(path: Path, operation: InstallerReleaseOperation) -> None:
    provenance = _bundled_release_provenance(path)
    if provenance.provenance_sha256 != operation.provenance_sha256:
        raise ValueError("archive provenance digest does not bind the durable operation")
    if provenance.installer_version != operation.installer_version:
        raise ValueError("archive provenance installer version does not bind the durable operation")
    if provenance.channel != operation.channel:
        raise ValueError("archive provenance channel does not bind the durable operation")
    if provenance.release_sequence != operation.release_sequence:
        raise ValueError("archive provenance sequence does not bind the durable operation")
    if provenance.source_revision != operation.source_revision:
        raise ValueError("archive provenance source revision does not bind the durable operation")
    if provenance.policy_revision != operation.policy_revision:
        raise ValueError("archive provenance policy revision does not bind the durable operation")
    if provenance.release_trust_configuration_sha256 != operation.release_identity.release_trust_configuration_sha256:
        raise ValueError("archive provenance trust configuration does not bind the reviewed identity")
    if provenance.capabilities != operation.capabilities:
        raise ValueError("archive provenance capabilities do not bind the durable operation")


def _descriptor_assets(
    descriptor: Mapping[str, object],
    operation: InstallerReleaseOperation,
) -> None:
    installer = _mapping(
        descriptor.get("installer"),
        frozenset({
            "version", "source_revision", "policy_revision", "release_trust_configuration_sha256",
            "provenance_sha256", "capabilities", "assets",
        }),
        "installer descriptor",
    )
    if installer["version"] != operation.installer_version:
        raise ValueError("descriptor installer version does not bind the operation")
    if installer["source_revision"] != operation.source_revision:
        raise ValueError("descriptor source revision does not bind the operation")
    if installer["policy_revision"] != operation.policy_revision:
        raise ValueError("descriptor policy revision does not bind the operation")
    if _raw_sha256(
        installer["release_trust_configuration_sha256"], "descriptor release trust configuration digest"
    ) != operation.release_identity.release_trust_configuration_sha256:
        raise ValueError("descriptor release trust configuration does not bind the reviewed identity")
    if _raw_sha256(installer["provenance_sha256"], "descriptor provenance digest") != operation.provenance_sha256:
        raise ValueError("descriptor provenance digest does not bind the operation")
    capabilities = installer["capabilities"]
    if not isinstance(capabilities, list) or not capabilities or any(
        not isinstance(item, str) or _CAPABILITY.fullmatch(item) is None for item in capabilities
    ):
        raise ValueError("descriptor capabilities are invalid")
    if (
        len(capabilities) != len(set(capabilities))
        or capabilities != sorted(capabilities)
        or tuple(capabilities) != operation.capabilities
    ):
        raise ValueError("descriptor capabilities do not bind the operation")
    assets = installer["assets"]
    if not isinstance(assets, list) or not assets:
        raise ValueError("descriptor assets are required")
    observed: dict[str, str] = {}
    identity = operation.release_identity
    for asset in assets:
        value = _mapping(
            asset,
            frozenset({
                "operating_system", "architecture", "minimum_macos_version", "asset_name", "digest",
                "bundle_identifier", "team_identifier",
                "code_directory_sha256", "notarization_receipt_reference",
            } | ({"helper_package"} if descriptor["schema"].endswith("/v2") else set())),
            "descriptor asset",
        )
        if value["operating_system"] != "macos":
            raise ValueError("descriptor asset operating system is invalid")
        if value["minimum_macos_version"] != MINIMUM_MACOS_SEMANTIC_VERSION:
            raise ValueError("descriptor asset minimum macOS version must be 26.0.0")
        architecture = _string(value["architecture"], "descriptor asset architecture")
        if architecture not in _ARCHITECTURES or architecture in observed:
            raise ValueError("descriptor asset architecture is invalid or duplicated")
        asset_name = _string(value["asset_name"], "descriptor asset name")
        if _ARCHIVE_ASSET_NAME.fullmatch(asset_name) is None or asset_name != identity.asset_name(architecture):
            raise ValueError("descriptor asset name does not bind the canonical GitHub release identity")
        if (
            _string(value["bundle_identifier"], "descriptor bundle identifier") != identity.bundle_identifier
            or _BUNDLE_IDENTIFIER.fullmatch(value["bundle_identifier"]) is None
        ):
            raise ValueError("descriptor bundle identifier does not bind the release identity")
        if (
            _string(value["team_identifier"], "descriptor team identifier") != identity.team_identifier
            or _TEAM_IDENTIFIER.fullmatch(value["team_identifier"]) is None
        ):
            raise ValueError("descriptor Apple Team identifier does not bind the release identity")
        if _raw_sha256(value["code_directory_sha256"], "descriptor CodeDirectory digest") != (
            operation.qualification.archive_code_directory_sha256[architecture]
        ):
            raise ValueError("descriptor CodeDirectory digest does not bind qualified archive evidence")
        notarization_reference = _string(
            value["notarization_receipt_reference"], "descriptor notarization receipt reference"
        )
        if (
            _RECEIPT_REFERENCE.fullmatch(notarization_reference) is None
            or notarization_reference
            != operation.qualification.archive_notarization_receipt_references[architecture]
        ):
            raise ValueError("descriptor notarization receipt does not bind qualified archive evidence")
        observed[architecture] = _digest(value["digest"], "descriptor asset digest")
    if set(observed) != set(operation.archives):
        raise ValueError("descriptor asset architectures do not exactly bind the operation archives")
    for architecture, digest in operation.archives.items():
        if observed[architecture] != digest:
            raise ValueError("descriptor asset digest does not bind the operation archive")


def _descriptor_signature_envelopes(
    signatures_value: object,
    operation: InstallerReleaseOperation,
) -> None:
    """Require the descriptor to expose the reviewed public threshold shape.

    This deliberately stops before cryptographic verification: only the
    protected signer/notarization environment owns a concrete public-key trust
    root.  The structural gate still rejects opaque signatures, untrusted key
    IDs, duplicate key IDs, algorithm drift and insufficient threshold evidence
    before that later verifier can issue a qualification receipt.
    """

    policy = SignatureThresholdPolicy(
        algorithm=operation.release_identity.signature_algorithm,
        trusted_key_ids=frozenset(operation.release_identity.signature_key_ids),
        threshold=operation.release_identity.signature_threshold,
    )
    policy.require_eligible(
        parse_public_signature_envelopes(signatures_value, label="installer release descriptor")
    )


def _descriptor_github_release(
    descriptor: Mapping[str, object],
    operation: InstallerReleaseOperation,
) -> None:
    """Reject descriptor identity drift before any archive name is accepted."""

    release = _mapping(
        descriptor.get("github_release"),
        frozenset({"repository", "tag", "descriptor_asset_name"}),
        "descriptor GitHub release identity",
    )
    repository = _string(release["repository"], "descriptor GitHub repository")
    tag = _string(release["tag"], "descriptor GitHub tag")
    descriptor_asset_name = _string(
        release["descriptor_asset_name"], "descriptor GitHub descriptor asset name"
    )
    if (
        _GITHUB_REPOSITORY.fullmatch(repository) is None
        or _GITHUB_TAG.fullmatch(tag) is None
        or _DESCRIPTOR_ASSET_NAME.fullmatch(descriptor_asset_name) is None
    ):
        raise ValueError("descriptor GitHub release identity is invalid")
    if (
        repository != operation.release_identity.github_repository
        or tag != operation.release_tag
        or descriptor_asset_name != operation.release_identity.release_descriptor_asset_name
    ):
        raise ValueError("descriptor GitHub release identity does not bind the reviewed release identity")


def verify(
    *,
    operation_raw: bytes,
    descriptor_raw: bytes,
    archive_paths: Mapping[str, Path],
    source_revision: str,
    expected_operation_id: str,
    expected_version: str,
    expected_channel: str,
    expected_release_sequence: int,
    expected_policy_revision: str,
    expected_provenance_sha256: str,
    expected_release_trust_configuration_sha256: str,
    expected_github_repository: str,
    expected_release_tag: str,
    expected_descriptor_asset_name: str,
    expected_bundle_identifier: str,
    expected_team_identifier: str,
    expected_asset_prefix: str,
    helper_package_path: Path | None = None,
    helper_companion_path: Path | None = None,
) -> InstallerReleaseEvidenceVerification:
    if _REVISION.fullmatch(source_revision) is None:
        raise ValueError("candidate source revision is invalid")
    if not descriptor_raw or len(descriptor_raw) > MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES:
        raise ValueError("installer release descriptor exceeds the accepted byte bound")
    try:
        operation = InstallerReleaseOperation.parse(_strict_object(operation_raw, "installer operation"))
    except InstallerReleaseOperationError as error:
        raise ValueError("durable installer release operation is invalid") from error
    if operation.source_revision != source_revision:
        raise ValueError("durable operation source revision does not match the exact candidate")
    if (
        operation.operation_id != expected_operation_id
        or operation.installer_version != expected_version
        or operation.channel != expected_channel
        or operation.release_sequence != expected_release_sequence
        or operation.policy_revision != expected_policy_revision
        or operation.provenance_sha256 != _raw_sha256(expected_provenance_sha256, "expected provenance digest")
    ):
        raise ValueError("durable operation does not bind the requested installer release context")
    identity = operation.release_identity
    if (
        identity.github_repository != expected_github_repository
        or operation.release_tag != expected_release_tag
        or identity.release_descriptor_asset_name != expected_descriptor_asset_name
        or (
            identity.release_trust_configuration_sha256
            != _raw_sha256(expected_release_trust_configuration_sha256, "expected release trust configuration digest")
        )
        or identity.bundle_identifier != expected_bundle_identifier
        or identity.team_identifier != expected_team_identifier
        or identity.asset_prefix != expected_asset_prefix
    ):
        raise ValueError("durable operation does not bind the reviewed installer release identity")
    if operation.state not in {"QUALIFIED", "PUBLISHED", "CLEANUP_PENDING", "RELEASE_COMPLETE"}:
        raise ValueError("durable installer release operation state is unsupported")
    if set(archive_paths) != set(operation.archives):
        raise ValueError("supplied archives do not match the durable operation architectures")
    catalog_trust_configurations: set[str | None] = set()
    for architecture, path in archive_paths.items():
        if _file_digest(path) != operation.archives[architecture]:
            raise ValueError("archive digest does not bind the durable operation")
        if architecture != INSTALLER_ARCHITECTURE:
            raise ValueError("installer archive architecture must be arm64")
        _archive_platform_contract(path)
        release_trust = _archive_trust_binds_operation(path, operation)
        _archive_provenance_binds_operation(path, operation)
        catalog_trust_configurations.add(
            _archive_catalog_trust_binds_operation(path, operation, release_trust)
        )
    if len(catalog_trust_configurations) != 1:
        raise ValueError("archive composition catalog trust policies differ across architectures")

    descriptor = _strict_object(descriptor_raw, "installer release descriptor")
    descriptor = _mapping(
        descriptor,
        frozenset({
            "schema", "sequence", "channel", "published_at", "expires_at", "github_release", "installer", "composition_catalog",
            "signatures",
        }),
        "installer release descriptor",
    )
    from scripts.installer_helper_package_release import package_metadata
    helper_metadata = package_metadata(descriptor)
    from forge_platform.installer_helper_companion import requires_companion, bound_metadata, read_document, qualification_binding
    if requires_companion(descriptor):
        if helper_companion_path is None:
            raise ValueError("signed helper companion is required")
        companion_raw, _ = read_document(helper_companion_path)
        helper_metadata = bound_metadata(descriptor_raw, companion_raw, qualification_binding(operation))
        companion = _strict_object(companion_raw, "helper companion")
        _descriptor_signature_envelopes(companion["signatures"], operation)
    elif helper_companion_path is not None:
        raise ValueError("unbound helper companion is not admitted")
    if (helper_metadata is None) != (helper_package_path is None):
        raise ValueError("helper package input does not match descriptor schema")
    if isinstance(descriptor["sequence"], bool) or not isinstance(descriptor["sequence"], int) or descriptor["sequence"] <= 0:
        raise ValueError("descriptor sequence is invalid")
    if descriptor["sequence"] != operation.release_sequence:
        raise ValueError("descriptor sequence does not bind the operation")
    if descriptor["channel"] != operation.channel or descriptor["channel"] not in _CHANNELS:
        raise ValueError("descriptor channel does not bind the operation")
    published_at = _timestamp(descriptor["published_at"], "descriptor publication timestamp")
    expires_at = _timestamp(descriptor["expires_at"], "descriptor expiry timestamp")
    if expires_at <= published_at:
        raise ValueError("descriptor expiry does not follow publication")
    catalog = _mapping(descriptor["composition_catalog"], frozenset({"url"}), "descriptor catalog")
    _https_url(catalog["url"], "descriptor catalog URL")
    _descriptor_github_release(descriptor, operation)
    _descriptor_signature_envelopes(descriptor["signatures"], operation)
    _descriptor_assets(descriptor, operation)
    if helper_metadata is not None:
        from scripts.verified_installer_helper_package import read_descriptor
        observed_helper = read_descriptor(helper_package_path,
            team=operation.release_identity.team_identifier,
            notarization_reference=helper_metadata["notarization_receipt_reference"],
            archive=archive_paths[INSTALLER_ARCHITECTURE], preparation=operation,
            archive_digest=operation.archives[INSTALLER_ARCHITECTURE])
        if observed_helper != helper_metadata:
            raise ValueError("helper package bytes do not bind the descriptor")
    if _file_digest_bytes(descriptor_raw) != operation.descriptor_digest:
        raise ValueError("descriptor digest does not bind the durable operation")
    if (
        operation.qualification.source_revision != source_revision
        or operation.qualification.policy_revision != operation.policy_revision
    ):
        raise ValueError("qualification evidence does not bind the candidate source revision and policy")
    catalog_trust_configuration = next(iter(catalog_trust_configurations))
    return InstallerReleaseEvidenceVerification(
        operation=operation,
        catalog_trust_status=(
            "STRUCTURALLY_BOUND_V1"
            if catalog_trust_configuration is not None
            else "ABSENT_FAIL_CLOSED"
        ),
    )


def _file_digest_bytes(value: bytes) -> str:
    return "sha256:" + sha256(value).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", required=True)
    parser.add_argument("--descriptor", required=True)
    parser.add_argument("--archive", action="append", default=[], metavar="ARCHITECTURE=PATH")
    parser.add_argument("--helper-package")
    parser.add_argument("--helper-companion")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--operation-id", required=True)
    parser.add_argument("--installer-version", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--release-sequence", required=True, type=int)
    parser.add_argument("--policy-revision", required=True)
    parser.add_argument("--provenance-sha256", required=True)
    parser.add_argument("--release-trust-configuration-sha256", required=True)
    parser.add_argument("--github-repository", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--descriptor-asset-name", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument("--team-identifier", required=True)
    parser.add_argument("--asset-prefix", required=True)
    args = parser.parse_args()
    try:
        operation_path, operation_raw = _read_regular_non_symlink_file(
            args.operation,
            label="installer release operation",
            maximum_bytes=_MAXIMUM_OPERATION_BYTES,
        )
        descriptor_path, descriptor_raw = _read_regular_non_symlink_file(
            args.descriptor,
            label="installer release descriptor",
            maximum_bytes=MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES,
        )
        if descriptor_path.name != args.descriptor_asset_name:
            raise ValueError("descriptor path does not use the canonical GitHub descriptor asset name")
        verification = verify(
            operation_raw=operation_raw,
            descriptor_raw=descriptor_raw,
            archive_paths=_archive_arguments(args.archive),
            helper_package_path=Path(args.helper_package) if args.helper_package else None,
            helper_companion_path=Path(args.helper_companion) if args.helper_companion else None,
            source_revision=args.source_sha,
            expected_operation_id=args.operation_id,
            expected_version=args.installer_version,
            expected_channel=args.channel,
            expected_release_sequence=args.release_sequence,
            expected_policy_revision=args.policy_revision,
            expected_provenance_sha256=args.provenance_sha256,
            expected_release_trust_configuration_sha256=args.release_trust_configuration_sha256,
            expected_github_repository=args.github_repository,
            expected_release_tag=args.release_tag,
            expected_descriptor_asset_name=args.descriptor_asset_name,
            expected_bundle_identifier=args.bundle_identifier,
            expected_team_identifier=args.team_identifier,
            expected_asset_prefix=args.asset_prefix,
        )
        print(
            "INSTALLER_RELEASE_EVIDENCE_STRUCTURE=PASS"
            f" version={verification.operation.installer_version}"
            f" tag={verification.operation.release_tag}"
            f" state={verification.operation.state}"
            f" signature_envelopes=STRUCTURALLY_BOUND"
            f" threshold={verification.operation.release_identity.signature_threshold}"
            f" catalog_trust={verification.catalog_trust_status}"
            " cryptographic_signature_verification=NOT_PERFORMED"
        )
    except (OSError, ValueError) as error:
        print(f"INSTALLER_RELEASE_EVIDENCE=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
