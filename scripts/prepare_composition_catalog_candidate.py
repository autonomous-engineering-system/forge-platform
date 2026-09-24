#!/usr/bin/env python3
"""Prepare exact immutable inputs for the offline composition-catalog signer.

This command performs no signing or publication.  It accepts only an already
reviewed composition manifest and component-combination index, validates their
cross-document bindings through the production parsers, and emits the exact
canonical unsigned outer-catalog bytes that the local catalog key must sign.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import re
import shutil
import sys
from typing import Mapping

from forge_platform.composition_catalog import ComponentCombinationCatalogEntry
from forge_platform.universal_installer import (
    CompositionCatalogEntry,
    CompositionManifest,
    DownloadIdentity,
    InstallerRequirement,
    SemanticVersion,
    canonical_rfc3339_utc_timestamp,
)


SCHEMA = "forge-platform.composition-catalog-candidate/v1"
ASSIGNMENT = "L1-FORGE-PLATFORM-MANAGED-INSTALLER-V1-20260923"
REPOSITORY = "autonomous-engineering-system/forge-platform"
STABLE_TAG = "forge-platform-composition-catalog-stable"
CATALOG_ASSET = "ForgePlatformInstallerCompositionCatalog.json"
MAXIMUM_DOCUMENT_BYTES = 512 * 1024
SHA = re.compile(r"^[0-9a-f]{40}$")
KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")


def _pairs(values: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if not isinstance(key, str) or key in result:
            raise ValueError("JSON contains duplicate or invalid keys")
        result[key] = value
    return result


def _read(path: Path, label: str) -> tuple[bytes, Mapping[str, object]]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} must be a regular non-symlink file")
    size = path.stat().st_size
    if size <= 0 or size > MAXIMUM_DOCUMENT_BYTES:
        raise ValueError(f"{label} exceeds the publication size boundary")
    raw = path.read_bytes()
    if len(raw) != size:
        raise ValueError(f"{label} changed while it was read")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"{label} is not strict UTF-8 JSON") from error
    if not isinstance(value, Mapping):
        raise ValueError(f"{label} root must be an object")
    return raw, value


def _canonical(value: Mapping[str, object], *, newline: bool = False) -> bytes:
    result = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ).encode("utf-8")
    return result + (b"\n" if newline else b"")


def _digest(raw: bytes) -> str:
    return "sha256:" + sha256(raw).hexdigest()


def _asset_name(value: str, label: str) -> str:
    if Path(value).name != value or not value.endswith(".json") or len(value.encode("utf-8")) > 180:
        raise ValueError(f"{label} is unsafe")
    return value


def _timestamp(value: str, label: str) -> datetime:
    parsed = canonical_rfc3339_utc_timestamp(value, label)
    if parsed.microsecond != 0:
        raise ValueError(f"{label} must use whole seconds")
    return parsed.astimezone(timezone.utc)


def prepare(
    *,
    manifest_path: Path,
    index_path: Path,
    output_directory: Path,
    source_sha: str,
    sequence: int,
    published_at: str,
    expires_at: str,
    manifest_asset_name: str,
    index_asset_name: str,
    key_ids: tuple[str, ...],
) -> Mapping[str, object]:
    if SHA.fullmatch(source_sha) is None:
        raise ValueError("source SHA must be one full lowercase Git SHA")
    if type(sequence) is not int or sequence <= 0 or sequence > (2**64) - 1:
        raise ValueError("catalog sequence must be a positive UInt64")
    publication_time = _timestamp(published_at, "catalog published_at")
    expiration_time = _timestamp(expires_at, "catalog expires_at")
    if expiration_time <= publication_time:
        raise ValueError("catalog expires_at must be later than published_at")
    if not key_ids or tuple(sorted(key_ids)) != key_ids or len(set(key_ids)) != len(key_ids):
        raise ValueError("catalog key IDs must be unique and strictly sorted")
    if any(KEY_ID.fullmatch(key_id) is None for key_id in key_ids):
        raise ValueError("catalog key ID is invalid")

    manifest_asset_name = _asset_name(manifest_asset_name, "manifest asset name")
    index_asset_name = _asset_name(index_asset_name, "index asset name")
    immutable_tag = f"forge-platform-composition-catalog-v{sequence}"
    base = f"https://github.com/{REPOSITORY}/releases/download/{immutable_tag}"
    manifest_url = f"{base}/{manifest_asset_name}"
    index_url = f"{base}/{index_asset_name}"

    manifest_raw, manifest_value = _read(manifest_path, "composition manifest")
    manifest_digest = _digest(manifest_raw)
    requirement_value = manifest_value.get("requires_installer")
    if not isinstance(requirement_value, Mapping):
        raise ValueError("composition manifest installer requirement is missing")
    capabilities = requirement_value.get("capabilities")
    if not isinstance(capabilities, list) or any(not isinstance(item, str) for item in capabilities):
        raise ValueError("composition manifest capabilities are invalid")
    requirement = InstallerRequirement(
        SemanticVersion.parse(requirement_value.get("minimum_version"), "minimum installer version"),
        frozenset(capabilities),
    )
    composition_id = manifest_value.get("composition_id")
    channel = manifest_value.get("channel")
    manifest = CompositionManifest.from_catalog_bytes(
        CompositionCatalogEntry(
            composition_id,
            channel,
            DownloadIdentity(manifest_url, manifest_digest),
            requirement,
        ),
        manifest_raw,
    )

    index_raw, index_value = _read(index_path, "component-combination catalog")
    expected_index_fields = {
        "schema", "sequence", "channel", "published_at", "expires_at", "compositions"
    }
    if set(index_value) != expected_index_fields:
        raise ValueError("component-combination catalog fields are invalid")
    if index_value["schema"] != "forge-platform.component-combination-catalog/v1":
        raise ValueError("component-combination catalog schema is unsupported")
    if index_value["sequence"] != sequence or index_value["channel"] != manifest.channel:
        raise ValueError("component-combination catalog identity does not bind the request")
    if index_value["published_at"] != published_at or index_value["expires_at"] != expires_at:
        raise ValueError("component-combination catalog freshness does not bind the request")
    compositions = index_value["compositions"]
    if not isinstance(compositions, list) or len(compositions) != 1:
        raise ValueError("candidate must contain exactly one reviewed composition")
    selected = ComponentCombinationCatalogEntry.from_mapping(compositions[0])
    if (
        selected.composition_id != manifest.composition_id
        or selected.channel != manifest.channel
        or selected.manifest != DownloadIdentity(manifest_url, manifest_digest)
        or selected.installer_requirement != manifest.installer_requirement
        or selected.upgrade_from != manifest.upgrade_from
        or selected.component_identities != frozenset(component.identity for component in manifest.components)
    ):
        raise ValueError("component-combination entry does not exactly bind the composition manifest")

    index_digest = _digest(index_raw)
    unsigned_catalog: dict[str, object] = {
        "schema": "forge-platform.composition-catalog/v1",
        "sequence": sequence,
        "channel": manifest.channel,
        "published_at": published_at,
        "expires_at": expires_at,
        "approved_python_runtime_identity": manifest.python_runtime.identity_digest,
        "compositions": [{
            "composition_id": manifest.composition_id,
            "channel": manifest.channel,
            "url": manifest_url,
            "digest": manifest_digest,
            "requires_installer": {
                "minimum_version": str(manifest.installer_requirement.minimum_version),
                "capabilities": sorted(manifest.installer_requirement.capabilities),
            },
        }],
        "component_combination_catalog": {"url": index_url, "digest": index_digest},
    }
    unsigned_raw = _canonical(unsigned_catalog)
    candidate: dict[str, object] = {
        "schema": SCHEMA,
        "assignment_id": ASSIGNMENT,
        "repository": REPOSITORY,
        "source_sha": source_sha,
        "sequence": sequence,
        "channel": manifest.channel,
        "published_at": published_at,
        "expires_at": expires_at,
        "immutable_release_tag": immutable_tag,
        "stable_release_tag": STABLE_TAG,
        "catalog_asset_name": CATALOG_ASSET,
        "manifest_asset_name": manifest_asset_name,
        "manifest_url": manifest_url,
        "manifest_digest": manifest_digest,
        "component_combination_catalog_asset_name": index_asset_name,
        "component_combination_catalog_url": index_url,
        "component_combination_catalog_digest": index_digest,
        "unsigned_catalog_digest": _digest(unsigned_raw),
        "catalog_key_ids": list(key_ids),
        "composition_id": manifest.composition_id,
        "approved_python_runtime_identity": manifest.python_runtime.identity_digest,
    }

    if output_directory.exists():
        raise ValueError("output directory already exists")
    output_directory.mkdir(mode=0o700, parents=True)
    shutil.copyfile(manifest_path, output_directory / manifest_asset_name)
    shutil.copyfile(index_path, output_directory / index_asset_name)
    (output_directory / "composition-catalog-unsigned.json").write_bytes(unsigned_raw)
    (output_directory / "composition-catalog-candidate.json").write_bytes(
        _canonical(candidate, newline=True)
    )
    return candidate


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--component-index", required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--sequence", required=True, type=int)
    parser.add_argument("--published-at", required=True)
    parser.add_argument("--expires-at", required=True)
    parser.add_argument("--manifest-asset-name", required=True)
    parser.add_argument("--index-asset-name", required=True)
    parser.add_argument("--key-id", action="append", required=True)
    args = parser.parse_args(argv)
    try:
        candidate = prepare(
            manifest_path=Path(args.manifest),
            index_path=Path(args.component_index),
            output_directory=Path(args.output_directory),
            source_sha=args.source_sha,
            sequence=args.sequence,
            published_at=args.published_at,
            expires_at=args.expires_at,
            manifest_asset_name=args.manifest_asset_name,
            index_asset_name=args.index_asset_name,
            key_ids=tuple(args.key_id),
        )
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        print(f"COMPOSITION_CATALOG_CANDIDATE=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "COMPOSITION_CATALOG_CANDIDATE=PASS"
        f" sequence={candidate['sequence']}"
        f" composition_id={candidate['composition_id']}"
        f" manifest_digest={candidate['manifest_digest']}"
        f" index_digest={candidate['component_combination_catalog_digest']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
