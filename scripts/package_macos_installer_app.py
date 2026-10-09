#!/usr/bin/env python3
"""Create one deterministic, unsigned macOS ``.app`` candidate bundle.

This helper is deliberately limited to bundle layout. It does not invoke a
signer, query Keychain, perform network I/O, stage a release, hand off a
process, or publish anything. The output is therefore a *candidate* that a
protected signing/notarization stage must replace or qualify before it can be
distributed.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from hashlib import sha256
import io
import os
from pathlib import Path
from pathlib import PurePosixPath
import plistlib
import re
import shutil
import stat
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from validate_installer_version import load_manifest
from forge_platform.forge_281_maintenance_resources import (
    CONTROLLER_NAME as FORGE281_CONTROLLER_NAME, RECEIPT_NAME as FORGE281_RECEIPT_NAME,
    CONTROLLER_SHA256 as FORGE281_CONTROLLER_SHA256, RELEASE_RECEIPT_SHA256 as FORGE281_RECEIPT_SHA256,
    METADATA as FORGE281_METADATA,
)
from forge_platform.composition_catalog_trust import (
    COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES,
    COMPOSITION_CATALOG_TRUST_RESOURCE_NAME,
    parse_composition_catalog_trust_bytes,
)
from forge_platform.installer_release_provenance import (
    INSTALLER_RELEASE_PROVENANCE_MAXIMUM_BYTES,
    INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME,
    parse_installer_release_provenance_bytes,
)
from forge_platform.installer_release_trust import (
    INSTALLER_RELEASE_TRUST_MAXIMUM_BYTES,
    INSTALLER_RELEASE_TRUST_RESOURCE_NAME,
    parse_installer_release_trust_bytes,
)
from forge_platform.macos_platform_contract import (
    MINIMUM_MACOS_VERSION,
    require_thin_arm64_macho_header,
)


_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_MINIMUM_MACOS = MINIMUM_MACOS_VERSION
_HELPER_LABEL = "com.autonomous-engineering-system.forge-platform-installer.helper"
_HELPER_PLIST_NAME = f"{_HELPER_LABEL}.plist"
_HELPER_BUNDLE_PROGRAM = "Contents/Resources/forge-platform-installer-helper"
_HELPER_MACH_SERVICES = (
    _HELPER_LABEL,
    f"{_HELPER_LABEL}.product-operations",
    f"{_HELPER_LABEL}.released-route",
)
_PRODUCT_WORKER_RESOURCE_NAME = "forge-platform-product-worker.pyz"
_PRODUCT_WORKER_DIGEST_INFO_KEY = "ForgePlatformProductWorkerSHA256"
_PRODUCT_WORKER_MAXIMUM_BYTES = 16 * 1_024 * 1_024
_PRODUCT_WORKER_MAXIMUM_UNCOMPRESSED_BYTES = 64 * 1_024 * 1_024
_PRODUCT_WORKER_MAXIMUM_ENTRIES = 4_096
_PRODUCT_WORKER_ZIP_DATE_TIME = (1980, 1, 1, 0, 0, 0)
_FORGE_UPDATE_CONTROLLER_RESOURCE_NAME = "forge-update-controller.py"
_FORGE_UPDATE_CONTROLLER_DIGEST_INFO_KEY = "ForgePlatformForgeUpdateControllerSHA256"
_FORGE_UPDATE_CONTROLLER_SOURCE_INFO_KEY = "ForgePlatformForgeUpdateControllerSourceRevision"
_FORGE_UPDATE_CONTROLLER_SOURCE = "e4b99a249845a547fd6b8e7e11d22467b2d0886d"
_FORGE_UPDATE_CONTROLLER_SHA256 = "sha256:6a6bb4ade3db9d1e45ba64a0d928e91013109de3243e8e2dbccfaa04a7a455b4"
_FORGE_UPDATE_CONTROLLER_MAXIMUM_BYTES = 512 * 1_024
_FORGE_RELEASE_RECEIPT_RESOURCE_NAME = "forge-release-complete-2.7.38.json"
_FORGE_RELEASE_RECEIPT_DIGEST_INFO_KEY = "ForgePlatformForgeReleaseCompleteSHA256"
_FORGE_RELEASE_SOURCE_INFO_KEY = "ForgePlatformForgeReleaseSourceRevision"
_FORGE_RELEASE_SOURCE = "0a3d6e35b01da93bb5a674ae7795558655c16c7d"
_FORGE_RELEASE_RECEIPT_SHA256 = "sha256:7f8f4646a369ea565e52f8420df665acb64d032e5004e1b45ef7dc8427548c49"
_FORGE_RELEASE_RECEIPT_MAXIMUM_BYTES = 64 * 1_024
_FORGE_239_CONTROLLER_RESOURCE_NAME = "forge-update-controller-2.7.39.py"
_FORGE_239_CONTROLLER_DIGEST_INFO_KEY = "ForgePlatformForge239UpdateControllerSHA256"
_FORGE_239_CONTROLLER_SOURCE_INFO_KEY = "ForgePlatformForge239UpdateControllerSourceRevision"
_FORGE_239_CONTROLLER_SOURCE = "ebc43dc12da27353f85c991a26da9852aa790f05"
_FORGE_239_CONTROLLER_SHA256 = "sha256:84bac133849c539a2bfae662234be93c3cd6583e841cae34eb27f3b21728fb87"
_FORGE_239_RECEIPT_RESOURCE_NAME = "forge-release-complete-2.7.39.json"
_FORGE_239_RECEIPT_DIGEST_INFO_KEY = "ForgePlatformForge239ReleaseCompleteSHA256"
_FORGE_239_RELEASE_SOURCE_INFO_KEY = "ForgePlatformForge239ReleaseSourceRevision"
_FORGE_239_RELEASE_SOURCE = "ebc43dc12da27353f85c991a26da9852aa790f05"
_FORGE_239_RECEIPT_SHA256 = "sha256:078a9f09f048cbd1fd36c4d5f83a5739dfeb3c3a546ba94bb1148596135ba15f"


@dataclass(frozen=True)
class SealedReleaseTrustResource:
    """Validated, non-secret bytes for the released application's trust file.

    Packaging writes ``contents`` captured during validation rather than
    reopening the caller's path. A later source-file change therefore cannot
    turn a validated descriptor into different bundled bytes.
    """

    source: Path
    contents: bytes
    configuration_sha256: str
    repository: str
    release_descriptor_locator: str
    release_descriptor_asset_name: str
    expected_bundle_identifier: str
    expected_team_identifier: str
    signature_threshold: int
    signature_key_ids: tuple[str, ...]


@dataclass(frozen=True)
class SealedReleaseProvenanceResource:
    """Validated, non-secret bytes for the app's immutable release provenance.

    The provenance file is packaged before code signing and deliberately does
    not contain a final descriptor digest: that descriptor is created only
    after the signed archive has an exact digest.  The later signed descriptor
    binds this resource's semantic digest instead, avoiding a code-signing
    circularity while preserving exact current-bundle provenance.
    """

    source: Path
    contents: bytes
    provenance_sha256: str
    installer_version: str
    channel: str
    release_sequence: int
    source_revision: str
    policy_revision: str
    capabilities: tuple[str, ...]
    release_trust_configuration_sha256: str


@dataclass(frozen=True)
class SealedCompositionCatalogTrustResource:
    """Validated public V1 catalog policy bound to this installer trust root.

    The resource is a separately code-signed policy, not a catalog, session,
    downloader, or product-operation authorization.  Packaging preserves the
    exact captured bytes so a later source-file change cannot replace the
    policy that was validated for the candidate bundle.
    """

    source: Path
    contents: bytes
    configuration_sha256: str
    installer_release_trust_configuration_sha256: str
    signature_threshold: int
    signature_key_ids: tuple[str, ...]


@dataclass(frozen=True)
class SealedProductWorkerResource:
    """Exact deterministic Python worker bytes bound into ``Info.plist``."""

    source: Path
    contents: bytes
    sha256: str


@dataclass(frozen=True)
class SealedForgeUpdateControllerResource:
    source: Path
    contents: bytes
    sha256: str


@dataclass(frozen=True)
class SealedForgeReleaseCompleteReceiptResource:
    source: Path
    contents: bytes
    sha256: str


def _sealed_forge_release_receipt_resource(value: str) -> SealedForgeReleaseCompleteReceiptResource:
    source, contents = _read_regular_non_symlink_file(
        value, description="Forge RELEASE_COMPLETE receipt",
        maximum_bytes=_FORGE_RELEASE_RECEIPT_MAXIMUM_BYTES,
    )
    return _validated_forge_release_receipt_resource(source, contents)


def _validated_forge_release_receipt_resource(
    source: Path, contents: bytes
) -> SealedForgeReleaseCompleteReceiptResource:
    digest = "sha256:" + sha256(contents).hexdigest()
    if not contents or digest != _FORGE_RELEASE_RECEIPT_SHA256:
        raise ValueError("Forge RELEASE_COMPLETE receipt does not match the exact public release")
    return SealedForgeReleaseCompleteReceiptResource(source, contents, digest)


def _sealed_forge_update_controller_resource(value: str) -> SealedForgeUpdateControllerResource:
    source, contents = _read_regular_non_symlink_file(
        value, description="Forge update controller resource",
        maximum_bytes=_FORGE_UPDATE_CONTROLLER_MAXIMUM_BYTES,
    )
    return _validated_forge_update_controller_resource(source, contents)


def _validated_forge_update_controller_resource(
    source: Path, contents: bytes
) -> SealedForgeUpdateControllerResource:
    digest = "sha256:" + sha256(contents).hexdigest()
    if not contents or digest != _FORGE_UPDATE_CONTROLLER_SHA256:
        raise ValueError("Forge update controller does not match the exact protected source")
    return SealedForgeUpdateControllerResource(source, contents, digest)


def _sealed_forge_239_controller_resource(value: str) -> SealedForgeUpdateControllerResource:
    source, contents = _read_regular_non_symlink_file(
        value, description="Forge 2.7.39 update controller",
        maximum_bytes=_FORGE_UPDATE_CONTROLLER_MAXIMUM_BYTES,
    )
    return _validated_forge_239_controller_resource(source, contents)


def _validated_forge_239_controller_resource(
    source: Path, contents: bytes,
) -> SealedForgeUpdateControllerResource:
    digest = "sha256:" + sha256(contents).hexdigest()
    if not contents or digest != _FORGE_239_CONTROLLER_SHA256:
        raise ValueError("Forge 2.7.39 controller does not match the published producer source")
    return SealedForgeUpdateControllerResource(source, contents, digest)


def _sealed_forge_239_receipt_resource(value: str) -> SealedForgeReleaseCompleteReceiptResource:
    source, contents = _read_regular_non_symlink_file(
        value, description="Forge 2.7.39 RELEASE_COMPLETE receipt",
        maximum_bytes=_FORGE_RELEASE_RECEIPT_MAXIMUM_BYTES,
    )
    return _validated_forge_239_receipt_resource(source, contents)


def _validated_forge_239_receipt_resource(
    source: Path, contents: bytes,
) -> SealedForgeReleaseCompleteReceiptResource:
    digest = "sha256:" + sha256(contents).hexdigest()
    if not contents or digest != _FORGE_239_RECEIPT_SHA256:
        raise ValueError("Forge 2.7.39 receipt does not match the public release")
    return SealedForgeReleaseCompleteReceiptResource(source, contents, digest)


def _sealed_forge_281_resource(value: str, *, receipt: bool):
    source, contents = _read_regular_non_symlink_file(value,
        description="Forge 2.8.1 maintenance receipt" if receipt else "Forge 2.8.1 maintenance controller",
        maximum_bytes=_FORGE_RELEASE_RECEIPT_MAXIMUM_BYTES if receipt else _FORGE_UPDATE_CONTROLLER_MAXIMUM_BYTES)
    digest = "sha256:" + sha256(contents).hexdigest()
    expected = FORGE281_RECEIPT_SHA256 if receipt else FORGE281_CONTROLLER_SHA256
    if not contents or digest != expected:
        raise ValueError("Forge 2.8.1 maintenance resource does not match its exact source")
    resource = SealedForgeReleaseCompleteReceiptResource if receipt else SealedForgeUpdateControllerResource
    return resource(source, contents, digest)


def _read_regular_non_symlink_file(value: str, *, description: str, maximum_bytes: int) -> tuple[Path, bytes]:
    """Read one bounded regular file without following a leaf symlink.

    Ancestor symlinks are normalized to their physical path. This preserves
    normal macOS paths such as ``/tmp`` while refusing a caller-selected file
    symlink and retaining the exact bytes that were validated.
    """

    source = _normalized_non_symlink_leaf(value, description=description)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(source, flags)
    except FileNotFoundError as error:
        raise ValueError(f"{description} does not exist") from error
    except OSError as error:
        raise ValueError(f"{description} cannot be opened safely") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"{description} must be a regular non-symlink file")
        if before.st_size > maximum_bytes:
            raise ValueError(f"{description} exceeds its maximum size")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(maximum_bytes + 1)
        if len(contents) > maximum_bytes:
            raise ValueError(f"{description} exceeds its maximum size")
        # A descriptor written while it is being read is not a stable trust
        # input. Reject it rather than copying a partially observed resource.
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{description} changed while it was being read")
        return source, contents
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _normalized_non_symlink_leaf(value: str, *, description: str) -> Path:
    """Resolve only ancestors, leaving the selected leaf for ``O_NOFOLLOW``.

    Resolving the complete path would follow a leaf swapped to a symlink in
    the small interval between the initial check and the open. This form still
    normalizes macOS ancestor aliases such as ``/tmp`` and ``/private/tmp``.
    """

    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{description} must not be selected through a symlink")
    try:
        parent = supplied.parent.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"{description} does not exist") from error
    source = parent / supplied.name
    if source.is_symlink():
        raise ValueError(f"{description} must not be selected through a symlink")
    return source


def _sealed_product_worker_resource(value: str) -> SealedProductWorkerResource:
    supplied = Path(value).expanduser()
    if supplied.suffix != ".pyz":
        raise ValueError("product worker resource must have a .pyz filename")
    source, contents = _read_regular_non_symlink_file(
        value,
        description="product worker resource",
        maximum_bytes=_PRODUCT_WORKER_MAXIMUM_BYTES,
    )
    return _validated_product_worker_resource(source, contents)


def _validated_product_worker_resource(
    source: Path,
    contents: bytes,
) -> SealedProductWorkerResource:
    """Require the worker to be one canonical, bounded, deterministic zipapp."""

    if not contents:
        raise ValueError("product worker resource is empty")
    try:
        with zipfile.ZipFile(io.BytesIO(contents), "r") as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            if not entries or len(entries) > _PRODUCT_WORKER_MAXIMUM_ENTRIES:
                raise ValueError("product worker resource entry count is invalid")
            if names != sorted(names) or len(names) != len(set(names)):
                raise ValueError("product worker resource entries are not canonical")
            if "__main__.py" not in names:
                raise ValueError("product worker resource has no __main__.py")
            total = 0
            payloads: list[tuple[str, bytes]] = []
            for entry in entries:
                path = PurePosixPath(entry.filename)
                mode = entry.external_attr >> 16
                if (
                    entry.filename.endswith("/")
                    or entry.filename.startswith("/")
                    or "\\" in entry.filename
                    or not path.parts
                    or any(part in {"", ".", ".."} for part in path.parts)
                    or entry.date_time != _PRODUCT_WORKER_ZIP_DATE_TIME
                    or entry.create_system != 3
                    or stat.S_IFMT(mode) != stat.S_IFREG
                    or stat.S_IMODE(mode) != 0o644
                    or entry.flag_bits != 0
                    or entry.compress_type != zipfile.ZIP_STORED
                    or entry.extra
                    or entry.comment
                ):
                    raise ValueError("product worker resource entry is unsafe")
                total += entry.file_size
                if total > _PRODUCT_WORKER_MAXIMUM_UNCOMPRESSED_BYTES:
                    raise ValueError("product worker resource expands beyond its maximum size")
                payloads.append((entry.filename, archive.read(entry)))
            if archive.comment:
                raise ValueError("product worker resource entry is unsafe")
    except (OSError, zipfile.BadZipFile) as error:
        raise ValueError("product worker resource is not a valid zipapp") from error
    canonical = io.BytesIO()
    with zipfile.ZipFile(canonical, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, payload in payloads:
            entry = zipfile.ZipInfo(name, date_time=_PRODUCT_WORKER_ZIP_DATE_TIME)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(entry, payload)
    if canonical.getvalue() != contents:
        raise ValueError("product worker resource bytes are not canonical")
    return SealedProductWorkerResource(
        source=source,
        contents=contents,
        sha256="sha256:" + sha256(contents).hexdigest(),
    )


def _source_executable(value: str, *, description: str = "installer executable") -> Path:
    candidate = _normalized_non_symlink_leaf(value, description=description)
    if not candidate.is_file():
        raise ValueError(f"{description} must be a regular non-symlink file")
    if not os.access(candidate, os.X_OK):
        raise ValueError(f"{description} must be executable")
    _require_arm64_macho_file(candidate, label=description)
    return candidate


def _require_arm64_macho_file(path: Path, *, label: str) -> None:
    """Read one stable header without following a selected executable symlink."""

    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise ValueError(f"{label} cannot be opened safely on this platform")
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | nofollow | getattr(os, "O_CLOEXEC", 0))
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"{label} must be a regular non-symlink file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            header = stream.read(32)
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{label} changed while it was being read")
        require_thin_arm64_macho_header(header, label)
    except OSError as error:
        raise ValueError(f"{label} cannot be opened safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _sealed_release_trust_resource(value: str) -> SealedReleaseTrustResource:
    """Validate the exact public V2 descriptor consumed by the native loader."""

    supplied = Path(value).expanduser()
    if supplied.suffix != ".json":
        raise ValueError("sealed release trust resource must have a .json filename")
    source, contents = _read_regular_non_symlink_file(
        value,
        description="sealed release trust resource",
        maximum_bytes=INSTALLER_RELEASE_TRUST_MAXIMUM_BYTES,
    )
    return _validated_sealed_release_trust_resource(source, contents)


def _validated_sealed_release_trust_resource(
    source: Path,
    contents: bytes,
) -> SealedReleaseTrustResource:
    """Revalidate captured V2 bytes before they become a bundle resource.

    ``package`` is also a library API.  Its public dataclass parameter must
    not turn a manually constructed object into a way around the strict CLI
    parser; therefore the bytes are always parsed again at the final write
    boundary.
    """

    trust = parse_installer_release_trust_bytes(
        contents,
        label="sealed release trust resource",
    )
    return SealedReleaseTrustResource(
        source=source,
        contents=contents,
        configuration_sha256=trust.configuration_sha256,
        repository=trust.repository,
        release_descriptor_locator=trust.release_descriptor_locator,
        release_descriptor_asset_name=trust.release_descriptor_asset_name,
        expected_bundle_identifier=trust.expected_bundle_identifier,
        expected_team_identifier=trust.expected_team_identifier,
        signature_threshold=trust.signature_threshold,
        signature_key_ids=trust.signature_key_ids,
    )


def _sealed_composition_catalog_trust_resource(value: str) -> SealedCompositionCatalogTrustResource:
    """Validate one exact public V1 policy for the catalog-signing keys."""

    supplied = Path(value).expanduser()
    if supplied.suffix != ".json":
        raise ValueError("sealed composition catalog trust resource must have a .json filename")
    source, contents = _read_regular_non_symlink_file(
        value,
        description="sealed composition catalog trust resource",
        maximum_bytes=COMPOSITION_CATALOG_TRUST_MAXIMUM_BYTES,
    )
    return _validated_sealed_composition_catalog_trust_resource(source, contents)


def _validated_sealed_composition_catalog_trust_resource(
    source: Path,
    contents: bytes,
) -> SealedCompositionCatalogTrustResource:
    """Revalidate captured V1 policy bytes at the public API boundary."""

    trust = parse_composition_catalog_trust_bytes(
        contents,
        label="sealed composition catalog trust resource",
    )
    return SealedCompositionCatalogTrustResource(
        source=source,
        contents=contents,
        configuration_sha256=trust.configuration_sha256,
        installer_release_trust_configuration_sha256=(
            trust.installer_release_trust_configuration_sha256
        ),
        signature_threshold=trust.signature_threshold,
        signature_key_ids=trust.signature_key_ids,
    )


def _sealed_release_provenance_resource(value: str) -> SealedReleaseProvenanceResource:
    """Validate the exact public V1 provenance resource copied into the app.

    It intentionally has no URL, private key, credential, raw descriptor
    bytes, final archive digest, or post-signing CodeDirectory hash.  Those
    facts are supplied only by the later protected qualification path and bind
    this resource's stable semantic digest.
    """

    supplied = Path(value).expanduser()
    if supplied.suffix != ".json":
        raise ValueError("sealed release provenance resource must have a .json filename")
    source, contents = _read_regular_non_symlink_file(
        value,
        description="sealed release provenance resource",
        maximum_bytes=INSTALLER_RELEASE_PROVENANCE_MAXIMUM_BYTES,
    )
    return _validated_sealed_release_provenance_resource(source, contents)


def _validated_sealed_release_provenance_resource(
    source: Path,
    contents: bytes,
) -> SealedReleaseProvenanceResource:
    """Revalidate captured V1 bytes at the public packager API boundary."""

    provenance = parse_installer_release_provenance_bytes(
        contents,
        label="sealed release provenance resource",
    )
    return SealedReleaseProvenanceResource(
        source=source,
        contents=contents,
        provenance_sha256=provenance.provenance_sha256,
        installer_version=provenance.installer_version,
        channel=provenance.channel,
        release_sequence=provenance.release_sequence,
        source_revision=provenance.source_revision,
        policy_revision=provenance.policy_revision,
        capabilities=provenance.capabilities,
        release_trust_configuration_sha256=provenance.release_trust_configuration_sha256,
    )


def _output_bundle(value: str) -> Path:
    supplied = Path(value).expanduser()
    if supplied.is_symlink():
        raise ValueError("installer app bundle output must not be selected through a symlink")
    candidate = supplied.resolve(strict=False)
    if candidate.suffix != ".app":
        raise ValueError("installer app bundle output must end in .app")
    if candidate.exists():
        raise ValueError("installer app bundle output must not already exist")
    if candidate.parent.exists() and not candidate.parent.is_dir():
        raise ValueError("installer app bundle parent is not a directory")
    return candidate


def _bundle_identifier(value: str) -> str:
    if _BUNDLE_IDENTIFIER.fullmatch(value) is None:
        raise ValueError("installer bundle identifier is invalid")
    return value


def package(
    *,
    executable: Path,
    cli_executable: Path,
    helper_executable: Path | None = None,
    product_worker: SealedProductWorkerResource | None = None,
    forge_update_controller: SealedForgeUpdateControllerResource | None = None,
    forge_release_receipt: SealedForgeReleaseCompleteReceiptResource | None = None,
    forge_239_update_controller: SealedForgeUpdateControllerResource | None = None,
    forge_239_release_receipt: SealedForgeReleaseCompleteReceiptResource | None = None,
    forge_281_maintenance_controller: SealedForgeUpdateControllerResource | None = None,
    forge_281_release_receipt: SealedForgeReleaseCompleteReceiptResource | None = None,
    output: Path,
    bundle_identifier: str,
    sealed_release_trust: SealedReleaseTrustResource | None = None,
    sealed_release_provenance: SealedReleaseProvenanceResource | None = None,
    sealed_composition_catalog_trust: SealedCompositionCatalogTrustResource | None = None,
) -> None:
    """Lay out an unsigned app bundle without replacing an existing target.

    This public API repeats every path and identifier admission check performed
    by the CLI.  A caller must not be able to bypass the no-symlink executable
    rule merely by constructing ``Path`` or resource dataclasses directly.
    """

    executable = _source_executable(str(executable), description="installer GUI executable")
    cli_executable = _source_executable(
        str(cli_executable), description="installer CLI executable"
    )
    helper_executable = (
        _source_executable(
            str(helper_executable), description="installer privileged helper executable"
        )
        if helper_executable is not None
        else None
    )
    executables = [executable, cli_executable]
    if helper_executable is not None:
        executables.append(helper_executable)
    identities = {(item.stat().st_dev, item.stat().st_ino) for item in executables}
    if len(identities) != len(executables):
        raise ValueError("installer GUI, CLI and helper executables must be distinct files")
    output = _output_bundle(str(output))
    bundle_identifier = _bundle_identifier(bundle_identifier)

    if sealed_release_trust is not None:
        sealed_release_trust = _validated_sealed_release_trust_resource(
            sealed_release_trust.source,
            sealed_release_trust.contents,
        )
    if sealed_release_provenance is not None:
        sealed_release_provenance = _validated_sealed_release_provenance_resource(
            sealed_release_provenance.source,
            sealed_release_provenance.contents,
        )
    if sealed_composition_catalog_trust is not None:
        sealed_composition_catalog_trust = _validated_sealed_composition_catalog_trust_resource(
            sealed_composition_catalog_trust.source,
            sealed_composition_catalog_trust.contents,
        )
    if product_worker is not None:
        product_worker = _validated_product_worker_resource(
            product_worker.source,
            product_worker.contents,
        )
    if forge_update_controller is not None:
        forge_update_controller = _validated_forge_update_controller_resource(
            forge_update_controller.source, forge_update_controller.contents
        )
        if helper_executable is None or product_worker is None:
            raise ValueError("Forge update controller requires helper and product worker")
    if forge_release_receipt is not None:
        forge_release_receipt = _validated_forge_release_receipt_resource(
            forge_release_receipt.source, forge_release_receipt.contents
        )
        if forge_update_controller is None:
            raise ValueError("Forge release receipt requires exact update controller")
    if (forge_281_maintenance_controller is None) != (forge_281_release_receipt is None):
        raise ValueError("Forge 2.8.1 maintenance controller and receipt must be paired")
    if forge_281_maintenance_controller is not None and forge_281_release_receipt is not None:
        for resource, expected in ((forge_281_maintenance_controller, FORGE281_CONTROLLER_SHA256),
                                   (forge_281_release_receipt, FORGE281_RECEIPT_SHA256)):
            if not resource.contents or "sha256:" + sha256(resource.contents).hexdigest() != expected:
                raise ValueError("Forge 2.8.1 maintenance resource bytes changed")
        if helper_executable is None or product_worker is None:
            raise ValueError("Forge 2.8.1 maintenance resources require helper and product worker")
    if (forge_239_update_controller is None) != (forge_239_release_receipt is None):
        raise ValueError("Forge 2.7.39 update controller and release receipt must be paired")
    if forge_239_update_controller is not None and forge_239_release_receipt is not None:
        forge_239_update_controller = _validated_forge_239_controller_resource(
            forge_239_update_controller.source, forge_239_update_controller.contents
        )
        forge_239_release_receipt = _validated_forge_239_receipt_resource(
            forge_239_release_receipt.source, forge_239_release_receipt.contents
        )
        if helper_executable is None or product_worker is None:
            raise ValueError("Forge 2.7.39 resources require helper and product worker")

    if sealed_composition_catalog_trust is not None and (
        sealed_release_trust is None or sealed_release_provenance is None
    ):
        raise ValueError(
            "sealed composition catalog trust resource requires both sealed release trust and provenance resources"
        )
    if (sealed_release_trust is None) != (sealed_release_provenance is None):
        raise ValueError(
            "released installer packaging requires both sealed release trust and provenance resources"
        )
    if (
        sealed_release_trust is not None
        and sealed_release_provenance is not None
        and sealed_release_trust.configuration_sha256
        != sealed_release_provenance.release_trust_configuration_sha256
    ):
        raise ValueError(
            "sealed release provenance trust configuration digest does not match the bundled release trust resource"
        )
    if (
        sealed_release_trust is not None
        and sealed_release_trust.expected_bundle_identifier != bundle_identifier
    ):
        raise ValueError(
            "sealed release trust resource bundle identifier does not match the packaged app"
        )
    if (
        sealed_composition_catalog_trust is not None
        and sealed_release_trust is not None
        and sealed_composition_catalog_trust.installer_release_trust_configuration_sha256
        != sealed_release_trust.configuration_sha256
    ):
        raise ValueError(
            "sealed composition catalog trust resource release trust configuration digest does not match the bundled release trust resource"
        )

    manifest = load_manifest()
    version = manifest["version"]
    if not isinstance(version, str):  # The manifest validator establishes this.
        raise RuntimeError("installer version manifest returned an invalid version")
    manifest_channel = manifest["channel"]
    manifest_capabilities = manifest["capabilities"]
    if not isinstance(manifest_channel, str) or not isinstance(manifest_capabilities, list):
        raise RuntimeError("installer version manifest returned invalid release projections")
    if sealed_release_provenance is not None:
        if sealed_release_provenance.installer_version != version:
            raise ValueError(
                "sealed release provenance installer version does not match the packaged app"
            )
        if sealed_release_provenance.channel != manifest_channel:
            raise ValueError(
                "sealed release provenance channel does not match the packaged app"
            )
        if sealed_release_provenance.capabilities != tuple(sorted(manifest_capabilities)):
            raise ValueError(
                "sealed release provenance capabilities do not match the packaged app"
            )

    contents = output / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    launch_daemons = contents / "Library" / "LaunchDaemons"
    destination = macos / "ForgePlatformInstaller"
    cli_destination = macos / "forge-platform-installer"
    helper_destination = resources / "forge-platform-installer-helper"
    product_worker_destination = resources / _PRODUCT_WORKER_RESOURCE_NAME
    forge_controller_destination = resources / _FORGE_UPDATE_CONTROLLER_RESOURCE_NAME
    forge_receipt_destination = resources / _FORGE_RELEASE_RECEIPT_RESOURCE_NAME
    forge_239_controller_destination = resources / _FORGE_239_CONTROLLER_RESOURCE_NAME
    forge_239_receipt_destination = resources / _FORGE_239_RECEIPT_RESOURCE_NAME
    helper_plist = launch_daemons / _HELPER_PLIST_NAME
    info_plist = contents / "Info.plist"
    output_owned = False
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        try:
            output.mkdir(mode=0o755)
        except FileExistsError as error:
            raise ValueError("installer app bundle output must not already exist") from error
        output_owned = True
        contents.mkdir(mode=0o755)
        macos.mkdir(mode=0o755)
        shutil.copyfile(executable, destination, follow_symlinks=False)
        source_mode = stat.S_IMODE(executable.stat().st_mode)
        destination.chmod(source_mode | stat.S_IXUSR)
        _require_arm64_macho_file(destination, label="packaged installer executable")
        shutil.copyfile(cli_executable, cli_destination, follow_symlinks=False)
        cli_source_mode = stat.S_IMODE(cli_executable.stat().st_mode)
        cli_destination.chmod(cli_source_mode | stat.S_IXUSR)
        _require_arm64_macho_file(cli_destination, label="packaged installer CLI executable")
        if helper_executable is not None:
            resources.mkdir(mode=0o755)
            launch_daemons.mkdir(parents=True, mode=0o755)
            shutil.copyfile(helper_executable, helper_destination, follow_symlinks=False)
            helper_source_mode = stat.S_IMODE(helper_executable.stat().st_mode)
            helper_destination.chmod(helper_source_mode | stat.S_IXUSR)
            _require_arm64_macho_file(
                helper_destination,
                label="packaged installer privileged helper executable",
            )
            helper_metadata = {
                "AssociatedBundleIdentifiers": bundle_identifier,
                "BundleProgram": _HELPER_BUNDLE_PROGRAM,
                "Label": _HELPER_LABEL,
                "MachServices": {name: True for name in _HELPER_MACH_SERVICES},
            }
            with helper_plist.open("xb") as stream:
                plistlib.dump(helper_metadata, stream, fmt=plistlib.FMT_XML, sort_keys=True)
            helper_plist.chmod(0o644)
        metadata = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "ForgePlatformInstaller",
            "CFBundleIdentifier": bundle_identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Forge Platform Installer",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": _MINIMUM_MACOS,
            "NSHighResolutionCapable": True,
        }
        if product_worker is not None:
            metadata[_PRODUCT_WORKER_DIGEST_INFO_KEY] = product_worker.sha256
        if forge_update_controller is not None:
            metadata[_FORGE_UPDATE_CONTROLLER_DIGEST_INFO_KEY] = forge_update_controller.sha256
            metadata[_FORGE_UPDATE_CONTROLLER_SOURCE_INFO_KEY] = _FORGE_UPDATE_CONTROLLER_SOURCE
        if forge_release_receipt is not None:
            metadata[_FORGE_RELEASE_RECEIPT_DIGEST_INFO_KEY] = forge_release_receipt.sha256
            metadata[_FORGE_RELEASE_SOURCE_INFO_KEY] = _FORGE_RELEASE_SOURCE
        if forge_281_maintenance_controller is not None:
            metadata.update(FORGE281_METADATA)
        if forge_239_update_controller is not None and forge_239_release_receipt is not None:
            metadata[_FORGE_239_CONTROLLER_DIGEST_INFO_KEY] = forge_239_update_controller.sha256
            metadata[_FORGE_239_CONTROLLER_SOURCE_INFO_KEY] = _FORGE_239_CONTROLLER_SOURCE
            metadata[_FORGE_239_RECEIPT_DIGEST_INFO_KEY] = forge_239_release_receipt.sha256
            metadata[_FORGE_239_RELEASE_SOURCE_INFO_KEY] = _FORGE_239_RELEASE_SOURCE
        with info_plist.open("wb") as stream:
            plistlib.dump(metadata, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        info_plist.chmod(0o644)
        if (
            sealed_release_trust is not None
            or sealed_release_provenance is not None
            or sealed_composition_catalog_trust is not None
            or product_worker is not None
            or forge_update_controller is not None
            or forge_release_receipt is not None
            or forge_239_update_controller is not None
        ):
            resources.mkdir(mode=0o755, exist_ok=helper_executable is not None)
        if product_worker is not None:
            with product_worker_destination.open("xb") as stream:
                stream.write(product_worker.contents)
            product_worker_destination.chmod(0o644)
        if forge_update_controller is not None:
            with forge_controller_destination.open("xb") as stream:
                stream.write(forge_update_controller.contents)
            forge_controller_destination.chmod(0o644)
        if forge_release_receipt is not None:
            with forge_receipt_destination.open("xb") as stream:
                stream.write(forge_release_receipt.contents)
            forge_receipt_destination.chmod(0o644)
        if forge_281_maintenance_controller is not None and forge_281_release_receipt is not None:
            for name, resource in ((FORGE281_CONTROLLER_NAME, forge_281_maintenance_controller),
                                   (FORGE281_RECEIPT_NAME, forge_281_release_receipt)):
                destination = resources / name
                with destination.open("xb") as stream:
                    stream.write(resource.contents)
                destination.chmod(0o644)
        if forge_239_update_controller is not None and forge_239_release_receipt is not None:
            with forge_239_controller_destination.open("xb") as stream:
                stream.write(forge_239_update_controller.contents)
            forge_239_controller_destination.chmod(0o644)
            with forge_239_receipt_destination.open("xb") as stream:
                stream.write(forge_239_release_receipt.contents)
            forge_239_receipt_destination.chmod(0o644)
        if sealed_release_trust is not None:
            trust_destination = resources / INSTALLER_RELEASE_TRUST_RESOURCE_NAME
            with trust_destination.open("xb") as stream:
                stream.write(sealed_release_trust.contents)
            trust_destination.chmod(0o644)
        if sealed_release_provenance is not None:
            provenance_destination = resources / INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME
            with provenance_destination.open("xb") as stream:
                stream.write(sealed_release_provenance.contents)
            provenance_destination.chmod(0o644)
        if sealed_composition_catalog_trust is not None:
            catalog_trust_destination = resources / COMPOSITION_CATALOG_TRUST_RESOURCE_NAME
            with catalog_trust_destination.open("xb") as stream:
                stream.write(sealed_composition_catalog_trust.contents)
            catalog_trust_destination.chmod(0o644)
    except BaseException:
        # The output path was required to be new and is therefore the sole
        # operation-owned cleanup target on failure.
        if output_owned:
            shutil.rmtree(output, ignore_errors=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--cli-executable", required=True)
    parser.add_argument(
        "--helper-executable",
        help=(
            "optional thin arm64 privileged helper copied to "
            f"{_HELPER_BUNDLE_PROGRAM}; released candidates require this input"
        ),
    )
    parser.add_argument(
        "--product-worker",
        help=(
            "optional deterministic Python zipapp copied to "
            f"Contents/Resources/{_PRODUCT_WORKER_RESOURCE_NAME} and bound by "
            f"the {_PRODUCT_WORKER_DIGEST_INFO_KEY} Info.plist value"
        ),
    )
    parser.add_argument(
        "--forge-update-controller",
        help=(
            "exact protected Forge 2.7.38 external update controller copied to "
            f"Contents/Resources/{_FORGE_UPDATE_CONTROLLER_RESOURCE_NAME}"
        ),
    )
    parser.add_argument(
        "--forge-release-complete-receipt",
        help=(
            "exact public Forge 2.7.38 RELEASE_COMPLETE receipt copied to "
            f"Contents/Resources/{_FORGE_RELEASE_RECEIPT_RESOURCE_NAME}"
        ),
    )
    parser.add_argument(
        "--forge-239-update-controller",
        help=("exact published Forge 2.7.39 update script copied to "
              f"Contents/Resources/{_FORGE_239_CONTROLLER_RESOURCE_NAME}"),
    )
    parser.add_argument(
        "--forge-239-release-complete-receipt",
        help=("exact public Forge 2.7.39 RELEASE_COMPLETE receipt copied to "
              f"Contents/Resources/{_FORGE_239_RECEIPT_RESOURCE_NAME}"),
    )
    parser.add_argument("--forge-281-maintenance-controller")
    parser.add_argument("--forge-281-release-complete-receipt")
    parser.add_argument("--output", required=True)
    parser.add_argument("--bundle-identifier", required=True)
    parser.add_argument(
        "--sealed-release-trust-resource",
        help=(
            "explicit public V2 JSON trust descriptor to copy verbatim to "
            f"Contents/Resources/{INSTALLER_RELEASE_TRUST_RESOURCE_NAME}"
        ),
    )
    parser.add_argument(
        "--sealed-release-provenance-resource",
        help=(
            "explicit public V1 JSON release provenance to copy verbatim to "
            f"Contents/Resources/{INSTALLER_RELEASE_PROVENANCE_RESOURCE_NAME}"
        ),
    )
    parser.add_argument(
        "--sealed-composition-catalog-trust-resource",
        help=(
            "explicit public V1 JSON catalog-signing policy to copy verbatim to "
            f"Contents/Resources/{COMPOSITION_CATALOG_TRUST_RESOURCE_NAME}; requires "
            "the matched V2 release-trust and V1 provenance resources"
        ),
    )
    args = parser.parse_args()
    try:
        executable = _source_executable(
            args.executable, description="installer GUI executable"
        )
        cli_executable = _source_executable(
            args.cli_executable, description="installer CLI executable"
        )
        helper_executable = (
            _source_executable(
                args.helper_executable,
                description="installer privileged helper executable",
            )
            if args.helper_executable is not None
            else None
        )
        product_worker = (
            _sealed_product_worker_resource(args.product_worker)
            if args.product_worker is not None
            else None
        )
        forge_update_controller = (
            _sealed_forge_update_controller_resource(args.forge_update_controller)
            if args.forge_update_controller is not None
            else None
        )
        forge_release_receipt = (
            _sealed_forge_release_receipt_resource(args.forge_release_complete_receipt)
            if args.forge_release_complete_receipt is not None
            else None
        )
        forge_239_update_controller = (
            _sealed_forge_239_controller_resource(args.forge_239_update_controller)
            if args.forge_239_update_controller is not None else None
        )
        forge_239_release_receipt = (
            _sealed_forge_239_receipt_resource(args.forge_239_release_complete_receipt)
            if args.forge_239_release_complete_receipt is not None else None
        )
        output = _output_bundle(args.output)
        bundle_identifier = _bundle_identifier(args.bundle_identifier)
        sealed_release_trust = (
            _sealed_release_trust_resource(args.sealed_release_trust_resource)
            if args.sealed_release_trust_resource is not None
            else None
        )
        sealed_release_provenance = (
            _sealed_release_provenance_resource(args.sealed_release_provenance_resource)
            if args.sealed_release_provenance_resource is not None
            else None
        )
        sealed_composition_catalog_trust = (
            _sealed_composition_catalog_trust_resource(
                args.sealed_composition_catalog_trust_resource
            )
            if args.sealed_composition_catalog_trust_resource is not None
            else None
        )
        package(
            executable=executable,
            cli_executable=cli_executable,
            helper_executable=helper_executable,
            product_worker=product_worker,
            forge_update_controller=forge_update_controller,
            forge_release_receipt=forge_release_receipt,
            forge_239_update_controller=forge_239_update_controller,
            forge_239_release_receipt=forge_239_release_receipt,
            forge_281_maintenance_controller=(
                _sealed_forge_281_resource(args.forge_281_maintenance_controller, receipt=False)
                if args.forge_281_maintenance_controller is not None else None),
            forge_281_release_receipt=(
                _sealed_forge_281_resource(args.forge_281_release_complete_receipt, receipt=True)
                if args.forge_281_release_complete_receipt is not None else None),
            output=output,
            bundle_identifier=bundle_identifier,
            sealed_release_trust=sealed_release_trust,
            sealed_release_provenance=sealed_release_provenance,
            sealed_composition_catalog_trust=sealed_composition_catalog_trust,
        )
        print(
            "INSTALLER_APP_BUNDLE=PASS"
            f" version={load_manifest()['version']}"
            f" bundle_identifier={bundle_identifier}"
            " cli=PACKAGED"
            f" privileged_helper={'PACKAGED' if helper_executable is not None else 'ABSENT_FAIL_CLOSED'}"
            f" product_worker={'PACKAGED' if product_worker is not None else 'ABSENT_FAIL_CLOSED'}"
            f" forge_update_controller={'PACKAGED' if forge_update_controller is not None else 'ABSENT_FAIL_CLOSED'}"
            f" forge_release_receipt={'PACKAGED' if forge_release_receipt is not None else 'ABSENT_FAIL_CLOSED'}"
            f" forge_239_update_controller={'PACKAGED' if forge_239_update_controller is not None else 'ABSENT_FAIL_CLOSED'}"
            f" forge_239_release_receipt={'PACKAGED' if forge_239_release_receipt is not None else 'ABSENT_FAIL_CLOSED'}"
            f" sealed_release_trust={'PACKAGED_V2' if sealed_release_trust is not None else 'ABSENT_FAIL_CLOSED'}"
            f" sealed_release_provenance={'PACKAGED_V1' if sealed_release_provenance is not None else 'ABSENT_FAIL_CLOSED'}"
            f" sealed_composition_catalog_trust={'PACKAGED_V1' if sealed_composition_catalog_trust is not None else 'ABSENT_FAIL_CLOSED'}"
            " signing=UNSIGNED_CANDIDATE"
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"INSTALLER_APP_BUNDLE=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
