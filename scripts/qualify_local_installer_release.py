#!/usr/bin/env python3
"""Create and cryptographically sign exact local installer release evidence."""
from __future__ import annotations

import argparse
import base64
import binascii
from dataclasses import asdict
from datetime import datetime
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from typing import Mapping
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (
    InstallerQualificationEvidence,
    InstallerReleaseOperation,
    InstallerReleaseOperationError,
    InstallerReleaseOperationStore,
    InstallerReleasePreparation,
)
from forge_platform.installer_release_trust import parse_installer_release_trust_bytes

_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_RECEIPT = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("JSON contains duplicate or invalid keys")
        result[key] = value
    return result


def _read_json(path: Path, label: str, maximum: int = 1024 * 1024) -> object:
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= maximum:
        raise ValueError(f"{label} must be a bounded regular file")
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not strict JSON") from error


def _digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError("release archive must be a regular non-symlink file")
    value = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return "sha256:" + value.hexdigest()


def _canonical(value: object) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")


def _timestamp(value: str, label: str) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{label} must be RFC3339") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must include a timezone")
    return value


def _descriptor_key_tool(path: Path) -> Path:
    supplied = path.expanduser()
    if supplied.is_symlink():
        raise ValueError("descriptor Keychain tool must not be selected through a symlink")
    resolved = supplied.resolve(strict=True)
    metadata = resolved.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise ValueError("descriptor Keychain tool ownership is invalid")
    if stat.S_IMODE(metadata.st_mode) & 0o022 or not os.access(resolved, os.X_OK):
        raise ValueError("descriptor Keychain tool permissions are invalid")
    return resolved


def _tool_public_key(tool: Path, key_id: str) -> bytes:
    result = subprocess.run(
        [str(tool), "public-key", key_id],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=30,
        check=False,
    )
    prefix = f"OFFLINE_DESCRIPTOR_KEY=READY key_id={key_id} public_key_base64="
    lines = result.stdout.splitlines()
    if result.returncode != 0 or len(lines) != 1 or not lines[0].startswith(prefix):
        raise ValueError("reviewed descriptor key is unavailable in the local Keychain")
    try:
        public = base64.b64decode(lines[0][len(prefix):], validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("descriptor Keychain public key is invalid") from error
    if len(public) != 32:
        raise ValueError("descriptor Keychain public key is not Ed25519")
    return public


def _tool_signature(tool: Path, key_id: str, payload: bytes) -> tuple[dict[str, str], bytes]:
    with tempfile.TemporaryDirectory(prefix="forge-descriptor-sign-") as temporary:
        root = Path(temporary)
        message = root / "descriptor.json"
        output = root / "signature.json"
        message.write_bytes(payload)
        message.chmod(0o600)
        result = subprocess.run(
            [str(tool), "sign", key_id, str(message), str(output)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            raise ValueError("descriptor Keychain signing failed")
        envelope = _read_json(output, "descriptor signature envelope", maximum=4096)
    if not isinstance(envelope, Mapping) or set(envelope) != {"algorithm", "key_id", "signature"}:
        raise ValueError("descriptor signature envelope is invalid")
    if envelope.get("algorithm") != "ed25519" or envelope.get("key_id") != key_id:
        raise ValueError("descriptor signature envelope is not bound to the reviewed key")
    encoded = envelope.get("signature")
    if not isinstance(encoded, str) or re.fullmatch(r"[A-Za-z0-9_-]{86}", encoded) is None:
        raise ValueError("descriptor signature encoding is invalid")
    try:
        raw = base64.urlsafe_b64decode(encoded + "==")
    except (ValueError, binascii.Error) as error:
        raise ValueError("descriptor signature encoding is invalid") from error
    if len(raw) != 64:
        raise ValueError("descriptor signature is not Ed25519")
    return dict(envelope), raw


def _verify_signature(public_key: bytes, payload: bytes, signature: bytes) -> None:
    with tempfile.TemporaryDirectory(prefix="forge-descriptor-verify-") as temporary:
        root = Path(temporary)
        public_path = root / "public.der"
        signature_path = root / "signature.bin"
        public_path.write_bytes(_SPKI_PREFIX + public_key)
        signature_path.write_bytes(signature)
        public_path.chmod(0o600)
        signature_path.chmod(0o600)
        verified = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify", "-rawin", "-pubin",
                "-keyform", "DER", "-inkey", str(public_path),
                "-sigfile", str(signature_path),
            ],
            input=payload,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
    if verified.returncode != 0:
        raise ValueError("descriptor Ed25519 signature verification failed")


def qualify(
    *,
    preparation_path: Path,
    signed_archive: Path,
    release_trust_path: Path,
    descriptor_key_tool: Path,
    code_directory_sha256: str,
    notarization_receipt_reference: str,
    catalog_url: str,
    published_at: str,
    expires_at: str,
    run_id: int,
    journal_root: Path,
    output_directory: Path,
) -> InstallerReleaseOperation:
    try:
        preparation = InstallerReleasePreparation.parse(
            _read_json(preparation_path, "installer release preparation")
        )
    except InstallerReleaseOperationError as error:
        raise ValueError("installer release preparation is invalid") from error
    if _SHA256.fullmatch(code_directory_sha256) is None:
        raise ValueError("CodeDirectory SHA-256 is invalid")
    if _RECEIPT.fullmatch(notarization_receipt_reference) is None:
        raise ValueError("notarization receipt reference is invalid")
    if type(run_id) is not int or run_id <= 0:
        raise ValueError("GitHub authorization run ID is invalid")
    parsed_url = urlsplit(catalog_url)
    if parsed_url.scheme != "https" or not parsed_url.netloc or parsed_url.username or parsed_url.password or parsed_url.fragment:
        raise ValueError("composition catalog URL must be canonical HTTPS")
    published_at = _timestamp(published_at, "publication timestamp")
    expires_at = _timestamp(expires_at, "expiry timestamp")
    if datetime.fromisoformat(expires_at.replace("Z", "+00:00")) <= datetime.fromisoformat(
        published_at.replace("Z", "+00:00")
    ):
        raise ValueError("descriptor expiry must follow publication")

    trust = parse_installer_release_trust_bytes(
        release_trust_path.read_bytes(),
        label="local signer release trust resource",
    )
    identity = preparation.release_identity
    if (
        trust.configuration_sha256 != identity.release_trust_configuration_sha256
        or trust.repository != identity.github_repository
        or trust.release_descriptor_asset_name != identity.release_descriptor_asset_name
        or trust.expected_bundle_identifier != identity.bundle_identifier
        or trust.expected_team_identifier != identity.team_identifier
        or trust.signature_key_ids != identity.signature_key_ids
        or trust.signature_threshold != identity.signature_threshold
    ):
        raise ValueError("embedded release trust does not bind the reviewed release identity")

    archive_digest = _digest(signed_archive)
    descriptor: dict[str, object] = {
        "schema": "forge-platform.installer-release/v1",
        "sequence": preparation.release_sequence,
        "channel": preparation.channel,
        "published_at": published_at,
        "expires_at": expires_at,
        "github_release": {
            "repository": identity.github_repository,
            "tag": identity.release_tag(preparation.installer_version),
            "descriptor_asset_name": identity.release_descriptor_asset_name,
        },
        "installer": {
            "version": preparation.installer_version,
            "source_revision": preparation.source_revision,
            "policy_revision": preparation.policy_revision,
            "release_trust_configuration_sha256": identity.release_trust_configuration_sha256,
            "provenance_sha256": preparation.provenance_sha256,
            "capabilities": list(preparation.capabilities),
            "assets": [{
                "operating_system": "macos",
                "architecture": "arm64",
                "minimum_macos_version": "26.0.0",
                "asset_name": identity.asset_name("arm64"),
                "digest": archive_digest,
                "bundle_identifier": identity.bundle_identifier,
                "team_identifier": identity.team_identifier,
                "code_directory_sha256": code_directory_sha256,
                "notarization_receipt_reference": notarization_receipt_reference,
            }],
        },
        "composition_catalog": {"url": catalog_url},
    }
    payload = _canonical(descriptor)
    tool = _descriptor_key_tool(descriptor_key_tool)
    expected_public = dict(trust.ed25519_public_keys)
    signatures: list[dict[str, str]] = []
    for key_id in sorted(identity.signature_key_ids):
        raw_public = _tool_public_key(tool, key_id)
        if base64.b64encode(raw_public).decode("ascii") != expected_public[key_id]:
            raise ValueError("descriptor Keychain key does not match embedded public trust")
        envelope, raw_signature = _tool_signature(tool, key_id, payload)
        _verify_signature(raw_public, payload, raw_signature)
        signatures.append(envelope)
    if len(signatures) < identity.signature_threshold:
        raise ValueError("descriptor signature threshold was not met")
    descriptor["signatures"] = signatures
    descriptor_raw = _canonical(descriptor)
    descriptor_digest = "sha256:" + sha256(descriptor_raw).hexdigest()

    qualification = InstallerQualificationEvidence(
        source_revision=preparation.source_revision,
        policy_revision=preparation.policy_revision,
        release_sequence=preparation.release_sequence,
        provenance_sha256=preparation.provenance_sha256,
        release_trust_configuration_sha256=identity.release_trust_configuration_sha256,
        candidate_manifest_digest=preparation.preparation.candidate_manifest_digest,
        candidate_archives=preparation.preparation.candidate_archives,
        descriptor_digest=descriptor_digest,
        archives={"arm64": archive_digest},
        archive_code_directory_sha256={"arm64": code_directory_sha256},
        archive_notarization_receipt_references={"arm64": notarization_receipt_reference},
        qualification_receipt_reference=f"receipt:local-signing-qualification-{run_id}",
    )
    operation = InstallerReleaseOperation.create(
        operation_id=preparation.operation_id,
        installer_version=preparation.installer_version,
        channel=preparation.channel,
        release_sequence=preparation.release_sequence,
        source_revision=preparation.source_revision,
        policy_revision=preparation.policy_revision,
        provenance_sha256=preparation.provenance_sha256,
        release_identity=identity,
        capabilities=preparation.capabilities,
        preparation=preparation.preparation,
        archives={"arm64": archive_digest},
        descriptor_digest=descriptor_digest,
        qualification=qualification,
    )
    store = InstallerReleaseOperationStore(journal_root)
    store.acquire(operation.operation_id)
    try:
        store.prepare_candidate(preparation)
        stored = store.prepare_qualified(operation)
    finally:
        store.release(operation.operation_id)

    output_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor_path = output_directory / identity.release_descriptor_asset_name
    operation_path = output_directory / "installer-release-operation.json"
    for path, raw in (
        (descriptor_path, descriptor_raw + b"\n"),
        (operation_path, _canonical(asdict(stored)) + b"\n"),
    ):
        if path.exists() and path.read_bytes() != raw:
            raise ValueError(f"{path.name} already contains different release evidence")
        if not path.exists():
            with path.open("xb") as stream:
                stream.write(raw)
            path.chmod(0o600)
    return stored


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preparation", required=True)
    parser.add_argument("--signed-archive", required=True)
    parser.add_argument("--release-trust", required=True)
    parser.add_argument("--descriptor-key-tool", required=True)
    parser.add_argument("--code-directory-sha256", required=True)
    parser.add_argument("--notarization-receipt-reference", required=True)
    parser.add_argument("--catalog-url", required=True)
    parser.add_argument("--published-at", required=True)
    parser.add_argument("--expires-at", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--journal-root", required=True)
    parser.add_argument("--output-directory", required=True)
    args = parser.parse_args(argv)
    try:
        operation = qualify(
            preparation_path=Path(args.preparation),
            signed_archive=Path(args.signed_archive),
            release_trust_path=Path(args.release_trust),
            descriptor_key_tool=Path(args.descriptor_key_tool),
            code_directory_sha256=args.code_directory_sha256,
            notarization_receipt_reference=args.notarization_receipt_reference,
            catalog_url=args.catalog_url,
            published_at=args.published_at,
            expires_at=args.expires_at,
            run_id=args.run_id,
            journal_root=Path(args.journal_root),
            output_directory=Path(args.output_directory),
        )
    except (OSError, RuntimeError, ValueError, InstallerReleaseOperationError, subprocess.SubprocessError) as error:
        print(f"LOCAL_INSTALLER_QUALIFICATION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "LOCAL_INSTALLER_QUALIFICATION=PASS"
        f" operation_id={operation.operation_id}"
        f" descriptor_digest={operation.descriptor_digest}"
        f" archive_digest={operation.archives['arm64']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
