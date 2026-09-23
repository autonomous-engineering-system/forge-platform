#!/usr/bin/env python3
"""Prepare the code-signed public installer provenance for an offline release."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

from forge_platform.composition_catalog_trust import parse_composition_catalog_trust_bytes
from forge_platform.installer_release_operation import INSTALLER_RELEASE_POLICY_REVISION
from forge_platform.installer_release_provenance import (
    InstallerReleaseProvenance,
    canonical_release_provenance_sha256,
    parse_installer_release_provenance_bytes,
)
from forge_platform.installer_release_trust import parse_installer_release_trust_bytes
from validate_installer_release_identity import load_identity

_REVISION = re.compile(r"^[0-9a-f]{40}$")
_VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def _read_regular(path: Path, label: str, maximum: int = 32 * 1024) -> bytes:
    supplied = path.expanduser()
    if supplied.is_symlink() or not supplied.is_file():
        raise ValueError(f"{label} must be a regular non-symlink file")
    data = supplied.read_bytes()
    if not data or len(data) > maximum:
        raise ValueError(f"{label} has invalid size")
    return data


def _manifest(root: Path) -> tuple[str, str, tuple[str, ...]]:
    value = json.loads(
        (root / "installer-version.json").read_text(encoding="utf-8"),
        parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
    )
    if not isinstance(value, dict):
        raise ValueError("installer version manifest is invalid")
    version = value.get("version")
    channel = value.get("channel")
    capabilities = value.get("capabilities")
    if (
        not isinstance(version, str)
        or _VERSION.fullmatch(version) is None
        or channel not in {"stable", "candidate"}
        or not isinstance(capabilities, list)
        or not capabilities
        or any(not isinstance(item, str) for item in capabilities)
        or capabilities != sorted(capabilities)
        or len(capabilities) != len(set(capabilities))
    ):
        raise ValueError("installer version manifest release projection is invalid")
    return version, channel, tuple(capabilities)


def _atomic_exact(path: Path, data: bytes) -> None:
    path = path.expanduser()
    if path.is_symlink():
        raise ValueError("provenance output must not be a symlink")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists():
        if not path.is_file() or path.read_bytes() != data:
            raise ValueError("provenance output already contains different bytes")
        os.chmod(path, 0o600)
        return
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.link(temporary, path, follow_symlinks=False)
        os.unlink(temporary)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def prepare(
    *,
    root: Path,
    release_identity: Path,
    release_trust_resource: Path,
    catalog_trust_resource: Path,
    source_revision: str,
    release_sequence: int,
    output: Path,
) -> InstallerReleaseProvenance:
    if _REVISION.fullmatch(source_revision) is None:
        raise ValueError("source revision must be an exact lowercase Git SHA")
    if isinstance(release_sequence, bool) or release_sequence <= 0 or release_sequence > (1 << 64) - 1:
        raise ValueError("release sequence must be a positive UInt64")

    identity = load_identity(require_ready=True, path=release_identity)
    if identity is None:
        raise ValueError("reviewed release identity is required")
    trust = parse_installer_release_trust_bytes(
        _read_regular(release_trust_resource, "release trust resource")
    )
    if (
        trust.configuration_sha256 != identity.release_trust_configuration_sha256
        or trust.repository != identity.github_repository
        or trust.release_descriptor_asset_name != identity.release_descriptor_asset_name
        or trust.expected_bundle_identifier != identity.bundle_identifier
        or trust.expected_team_identifier != identity.team_identifier
        or trust.signature_key_ids != identity.signature_key_ids
        or trust.signature_threshold != identity.signature_threshold
    ):
        raise ValueError("release trust resource does not bind the reviewed release identity")

    catalog = parse_composition_catalog_trust_bytes(
        _read_regular(catalog_trust_resource, "composition catalog trust resource")
    )
    if catalog.installer_release_trust_configuration_sha256 != trust.configuration_sha256:
        raise ValueError("composition catalog trust does not bind the release trust configuration")

    version, channel, capabilities = _manifest(root)
    digest = canonical_release_provenance_sha256(
        installer_version=version,
        channel=channel,
        release_sequence=release_sequence,
        source_revision=source_revision,
        policy_revision=INSTALLER_RELEASE_POLICY_REVISION,
        capabilities=capabilities,
        release_trust_configuration_sha256=trust.configuration_sha256,
    )
    provenance = InstallerReleaseProvenance(
        provenance_sha256=digest,
        installer_version=version,
        channel=channel,
        release_sequence=release_sequence,
        source_revision=source_revision,
        policy_revision=INSTALLER_RELEASE_POLICY_REVISION,
        capabilities=capabilities,
        release_trust_configuration_sha256=trust.configuration_sha256,
    )
    payload = {
        "schema_version": 1,
        "provenance_sha256": provenance.provenance_sha256,
        "installer_version": provenance.installer_version,
        "channel": provenance.channel,
        "release_sequence": provenance.release_sequence,
        "source_revision": provenance.source_revision,
        "policy_revision": provenance.policy_revision,
        "capabilities": list(provenance.capabilities),
        "release_trust_configuration_sha256": provenance.release_trust_configuration_sha256,
    }
    encoded = (json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")
    restored = parse_installer_release_provenance_bytes(encoded)
    if restored != provenance:
        raise ValueError("generated provenance failed exact parser readback")
    _atomic_exact(output, encoded)
    return provenance


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--release-identity", type=Path, default=ROOT / "installer-release-identity.json")
    parser.add_argument("--release-trust-resource", type=Path, required=True)
    parser.add_argument("--catalog-trust-resource", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--release-sequence", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        value = prepare(
            root=args.source_root.resolve(),
            release_identity=args.release_identity,
            release_trust_resource=args.release_trust_resource,
            catalog_trust_resource=args.catalog_trust_resource,
            source_revision=args.source_sha,
            release_sequence=args.release_sequence,
            output=args.output,
        )
    except (OSError, ValueError, RuntimeError) as error:
        print(f"OFFLINE_INSTALLER_PROVENANCE=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "OFFLINE_INSTALLER_PROVENANCE=PASS"
        f" version={value.installer_version}"
        f" sequence={value.release_sequence}"
        f" provenance_sha256={value.provenance_sha256}"
        f" trust_sha256={value.release_trust_configuration_sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
