#!/usr/bin/env python3
"""Validate the reviewed public identity required for installer publication.

The repository deliberately started ``UNCONFIGURED``: a source merge must not
silently choose an Apple Team, application bundle identifier, signing keys, or
GitHub publication namespace.  ``--require-ready`` is used only by the actual
installer release workflow and fails closed until those non-secret policy facts
have been reviewed and committed. A ``READY`` identity also fails when either
committed public trust resource does not match it exactly.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
IDENTITY_PATH = ROOT / "installer-release-identity.json"
SCHEMA = "forge-platform.installer-release-identity/v1"
FIELDS = frozenset({"schema", "status", "identity", "signing_key_policy"})

sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (  # noqa: E402
    InstallerReleaseIdentity,
    InstallerReleaseOperationError,
)
from forge_platform.installer_release_trust import parse_installer_release_trust_bytes  # noqa: E402
from forge_platform.composition_catalog_trust import parse_composition_catalog_trust_bytes  # noqa: E402


RELEASE_TRUST_PATH = ROOT / "release-trust/ForgePlatformInstallerReleaseTrust.json"
CATALOG_TRUST_PATH = ROOT / "release-trust/ForgePlatformInstallerCompositionCatalogTrust.json"


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("installer release identity has duplicate or invalid keys")
        result[key] = value
    return result


def load_identity(
    *,
    require_ready: bool = False,
    path: Path | None = None,
) -> InstallerReleaseIdentity | None:
    """Load one reviewed public identity source without selecting a default.

    Release-side preparation passes an explicit reviewed identity file so a
    candidate cannot accidentally bind whichever checkout happens to be on
    ``sys.path``.  The command-line validator continues to use the repository
    authority by default.
    """

    source = IDENTITY_PATH if path is None else Path(path)
    try:
        payload = json.loads(source.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("installer release identity source is unreadable") from error
    if not isinstance(payload, dict) or set(payload) != FIELDS or payload["schema"] != SCHEMA:
        raise RuntimeError("installer release identity source has invalid fields or schema")
    status = payload["status"]
    if status == "UNCONFIGURED":
        if payload["identity"] is not None or payload["signing_key_policy"] is not None:
            raise RuntimeError("unconfigured installer release identity must not contain partial policy facts")
        if require_ready:
            raise RuntimeError(
                "installer publication is blocked: commit a reviewed READY installer release identity and signing-key policy"
            )
        return None
    if status != "READY":
        raise RuntimeError("installer release identity status is unsupported")
    identity_value = payload["identity"]
    signing_policy = payload["signing_key_policy"]
    if not isinstance(identity_value, dict) or not isinstance(signing_policy, dict):
        raise RuntimeError("ready installer release identity requires complete public identity and signing policy")
    expected_identity = {
        "github_repository", "bundle_identifier", "team_identifier", "release_tag_prefix", "asset_prefix",
        "release_descriptor_asset_name", "release_trust_configuration_sha256",
    }
    expected_policy = {"algorithm", "key_ids", "threshold"}
    if set(identity_value) != expected_identity or set(signing_policy) != expected_policy:
        raise RuntimeError("ready installer release identity has unknown or missing policy fields")
    if not isinstance(signing_policy["key_ids"], list) or not signing_policy["key_ids"]:
        raise RuntimeError("ready installer release identity requires a non-empty signing key ID list")
    try:
        return InstallerReleaseIdentity(
            github_repository=identity_value["github_repository"],
            bundle_identifier=identity_value["bundle_identifier"],
            team_identifier=identity_value["team_identifier"],
            release_tag_prefix=identity_value["release_tag_prefix"],
            asset_prefix=identity_value["asset_prefix"],
            release_descriptor_asset_name=identity_value["release_descriptor_asset_name"],
            release_trust_configuration_sha256=identity_value["release_trust_configuration_sha256"],
            signature_algorithm=signing_policy["algorithm"],
            signature_key_ids=tuple(signing_policy["key_ids"]),
            signature_threshold=signing_policy["threshold"],
        )
    except (InstallerReleaseOperationError, TypeError) as error:
        raise RuntimeError("ready installer release identity is invalid") from error


def _field(identity: InstallerReleaseIdentity, name: str) -> str:
    values = {
        "github_repository": identity.github_repository,
        "bundle_identifier": identity.bundle_identifier,
        "team_identifier": identity.team_identifier,
        "release_tag_prefix": identity.release_tag_prefix,
        "asset_prefix": identity.asset_prefix,
        "release_descriptor_asset_name": identity.release_descriptor_asset_name,
        "release_trust_configuration_sha256": identity.release_trust_configuration_sha256,
        "signature_algorithm": identity.signature_algorithm,
        "signature_threshold": str(identity.signature_threshold),
    }
    try:
        return values[name]
    except KeyError as error:
        raise RuntimeError("requested installer release identity field is unsupported") from error


def validate_ready_resources(
    identity: InstallerReleaseIdentity,
    *,
    release_trust_path: Path = RELEASE_TRUST_PATH,
    catalog_trust_path: Path = CATALOG_TRUST_PATH,
) -> None:
    try:
        release = parse_installer_release_trust_bytes(release_trust_path.read_bytes())
        catalog = parse_composition_catalog_trust_bytes(catalog_trust_path.read_bytes())
    except (OSError, ValueError) as error:
        raise RuntimeError("ready installer public trust resources are invalid") from error
    if (
        release.configuration_sha256 != identity.release_trust_configuration_sha256
        or release.repository != identity.github_repository
        or release.release_descriptor_asset_name != identity.release_descriptor_asset_name
        or release.expected_bundle_identifier != identity.bundle_identifier
        or release.expected_team_identifier != identity.team_identifier
        or release.signature_key_ids != identity.signature_key_ids
        or release.signature_threshold != identity.signature_threshold
    ):
        raise RuntimeError("ready installer release trust does not bind the reviewed identity")
    if catalog.installer_release_trust_configuration_sha256 != release.configuration_sha256:
        raise RuntimeError("ready composition catalog trust does not bind installer release trust")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-ready", action="store_true")
    parser.add_argument("--field")
    args = parser.parse_args(argv)
    try:
        identity = load_identity(require_ready=args.require_ready or args.field is not None)
        if args.field is not None:
            if identity is None:
                raise RuntimeError("requested installer release identity field has no configured value")
            validate_ready_resources(identity)
            print(_field(identity, args.field))
        elif identity is None:
            print("INSTALLER_RELEASE_IDENTITY=UNCONFIGURED publication=BLOCKED")
        else:
            validate_ready_resources(identity)
            print(
                "INSTALLER_RELEASE_IDENTITY=READY"
                f" repository={identity.github_repository}"
                f" bundle_identifier={identity.bundle_identifier}"
                f" team_identifier={identity.team_identifier}"
                f" signature_threshold={identity.signature_threshold}"
            )
        return 0
    except RuntimeError as error:
        print(f"INSTALLER_RELEASE_IDENTITY=FAIL reason={error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
