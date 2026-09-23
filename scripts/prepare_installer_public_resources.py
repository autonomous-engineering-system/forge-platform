#!/usr/bin/env python3
"""Prepare exact public code-signed resources for one installer release.

This is a non-secret pre-signing boundary. It consumes only reviewed public
release identity/trust policy, the canonical installer-version manifest and an
exact protected source/release sequence. It writes the V1 provenance resource
that must be embedded together with the reviewed V2 release-trust and V1
composition-catalog-trust resources *before* Developer ID signing.

It never accesses a private signing key, Keychain credential, notarization
credential, provider credential or GitHub token.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from forge_platform.composition_catalog_trust import (  # noqa: E402
    parse_composition_catalog_trust_bytes,
)
from forge_platform.installer_release_operation import (  # noqa: E402
    INSTALLER_RELEASE_POLICY_REVISION,
)
from forge_platform.installer_release_provenance import (  # noqa: E402
    InstallerReleaseProvenance,
    canonical_release_provenance_sha256,
    parse_installer_release_provenance_bytes,
)
from forge_platform.installer_release_trust import (  # noqa: E402
    GITHUB_RELEASE_ASSET_LOCATOR,
    parse_installer_release_trust_bytes,
)
from validate_installer_release_identity import load_identity  # noqa: E402
from validate_installer_version import load_manifest  # noqa: E402


_MAXIMUM_PUBLIC_RESOURCE_BYTES = 64 * 1024


def _read_regular(path: Path, label: str) -> bytes:
    supplied = Path(path).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{label} must not be selected through a symlink")
    resolved = supplied.resolve(strict=True)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(resolved, flags)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size < 1
            or before.st_size > _MAXIMUM_PUBLIC_RESOURCE_BYTES
        ):
            raise ValueError(f"{label} must be one bounded regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            raw = stream.read(_MAXIMUM_PUBLIC_RESOURCE_BYTES + 1)
        after = os.fstat(descriptor)
        if (
            len(raw) > _MAXIMUM_PUBLIC_RESOURCE_BYTES
            or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ValueError(f"{label} changed while it was being read")
        return raw
    finally:
        os.close(descriptor)


def _write_atomic(path: Path, raw: bytes) -> None:
    destination = Path(path).expanduser().resolve(strict=False)
    if destination.suffix != ".json":
        raise ValueError("public release resource output must be a .json file")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
        directory = os.open(destination.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


def prepare(
    *,
    release_identity_path: Path,
    release_trust_path: Path,
    composition_catalog_trust_path: Path,
    installer_version_manifest: Path,
    source_revision: str,
    release_sequence: int,
    expected_provenance_sha256: str,
    output_directory: Path,
) -> InstallerReleaseProvenance:
    identity = load_identity(require_ready=True, path=release_identity_path)
    if identity is None:
        raise ValueError("reviewed installer release identity is required")

    release_trust_raw = _read_regular(release_trust_path, "installer release trust resource")
    release_trust = parse_installer_release_trust_bytes(release_trust_raw)
    if (
        release_trust.repository != identity.github_repository
        or release_trust.release_descriptor_locator != GITHUB_RELEASE_ASSET_LOCATOR
        or release_trust.release_descriptor_asset_name != identity.release_descriptor_asset_name
        or release_trust.expected_bundle_identifier != identity.bundle_identifier
        or release_trust.expected_team_identifier != identity.team_identifier
        or release_trust.configuration_sha256 != identity.release_trust_configuration_sha256
        or release_trust.signature_key_ids != identity.signature_key_ids
        or release_trust.signature_threshold != identity.signature_threshold
    ):
        raise ValueError("installer release trust resource does not bind the reviewed release identity")

    catalog_trust_raw = _read_regular(
        composition_catalog_trust_path, "composition catalog trust resource"
    )
    catalog_trust = parse_composition_catalog_trust_bytes(catalog_trust_raw)
    if (
        catalog_trust.installer_release_trust_configuration_sha256
        != release_trust.configuration_sha256
    ):
        raise ValueError("composition catalog trust does not bind the installer release trust root")

    manifest = load_manifest(installer_version_manifest)
    version = manifest["version"]
    channel = manifest["channel"]
    capabilities = tuple(sorted(manifest["capabilities"]))
    provenance_sha256 = canonical_release_provenance_sha256(
        installer_version=version,
        channel=channel,
        release_sequence=release_sequence,
        source_revision=source_revision,
        policy_revision=INSTALLER_RELEASE_POLICY_REVISION,
        release_trust_configuration_sha256=release_trust.configuration_sha256,
        capabilities=capabilities,
    )
    if provenance_sha256 != expected_provenance_sha256:
        raise ValueError("requested provenance digest does not match exact release context")

    provenance = InstallerReleaseProvenance(
        provenance_sha256=provenance_sha256,
        installer_version=version,
        channel=channel,
        release_sequence=release_sequence,
        source_revision=source_revision,
        policy_revision=INSTALLER_RELEASE_POLICY_REVISION,
        capabilities=capabilities,
        release_trust_configuration_sha256=release_trust.configuration_sha256,
    )
    output_directory = Path(output_directory).expanduser().resolve(strict=False)
    provenance_raw = (
        json.dumps(
            {
                "schema_version": 1,
                **asdict(provenance),
                "capabilities": list(provenance.capabilities),
            },
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")
    # Reparse the exact output bytes before they become a code-signed resource.
    parse_installer_release_provenance_bytes(provenance_raw)

    _write_atomic(output_directory / "ForgePlatformInstallerReleaseTrust.json", release_trust_raw)
    _write_atomic(
        output_directory / "ForgePlatformInstallerCompositionCatalogTrust.json",
        catalog_trust_raw,
    )
    _write_atomic(output_directory / "ForgePlatformInstallerReleaseProvenance.json", provenance_raw)
    return provenance


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-identity", required=True, type=Path)
    parser.add_argument("--release-trust", required=True, type=Path)
    parser.add_argument("--composition-catalog-trust", required=True, type=Path)
    parser.add_argument("--installer-version-manifest", default=ROOT / "installer-version.json", type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--release-sequence", required=True, type=int)
    parser.add_argument("--expected-provenance-sha256", required=True)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        provenance = prepare(
            release_identity_path=args.release_identity,
            release_trust_path=args.release_trust,
            composition_catalog_trust_path=args.composition_catalog_trust,
            installer_version_manifest=args.installer_version_manifest,
            source_revision=args.source_sha,
            release_sequence=args.release_sequence,
            expected_provenance_sha256=args.expected_provenance_sha256,
            output_directory=args.output_directory,
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"INSTALLER_PUBLIC_RESOURCES=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "INSTALLER_PUBLIC_RESOURCES=PASS"
        f" version={provenance.installer_version}"
        f" sequence={provenance.release_sequence}"
        f" provenance_sha256={provenance.provenance_sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
