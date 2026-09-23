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
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from validate_installer_version import load_manifest
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


def _source_executable(value: str) -> Path:
    candidate = _normalized_non_symlink_leaf(value, description="installer executable")
    if not candidate.is_file():
        raise ValueError("installer executable must be a regular non-symlink file")
    if not os.access(candidate, os.X_OK):
        raise ValueError("installer executable must be executable")
    _require_arm64_macho_file(candidate, label="installer executable")
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

    executable = _source_executable(str(executable))
    cli_executable = _source_executable(str(cli_executable))
    main_details = executable.stat()
    cli_details = cli_executable.stat()
    if (
        main_details.st_dev == cli_details.st_dev
        and main_details.st_ino == cli_details.st_ino
    ):
        raise ValueError("installer GUI and CLI executables must be distinct files")
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
    destination = macos / "ForgePlatformInstaller"
    cli_destination = macos / "forge-platform-installer"
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
        with info_plist.open("wb") as stream:
            plistlib.dump(metadata, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        info_plist.chmod(0o644)
        if (
            sealed_release_trust is not None
            or sealed_release_provenance is not None
            or sealed_composition_catalog_trust is not None
        ):
            resources.mkdir(mode=0o755)
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
        executable = _source_executable(args.executable)
        cli_executable = _source_executable(args.cli_executable)
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
