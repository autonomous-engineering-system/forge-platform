#!/usr/bin/env python3
"""Bind offline Ed25519 signatures to one exact composition-catalog candidate."""
from __future__ import annotations

import argparse
import base64
import binascii
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Mapping

from forge_platform.universal_installer import (
    CompositionCatalog,
    PublicSignatureEnvelope,
    SignatureThresholdPolicy,
)


CANDIDATE_SCHEMA = "forge-platform.composition-catalog-candidate/v1"
OPERATION_SCHEMA = "forge-platform.composition-catalog-publication/v1"
CATALOG_ASSET = "ForgePlatformInstallerCompositionCatalog.json"
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
SIGNATURE = re.compile(r"^[A-Za-z0-9_-]{86}$")
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def _pairs(values: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if not isinstance(key, str) or key in result:
            raise ValueError("JSON contains duplicate or invalid keys")
        result[key] = value
    return result


def _load(path: Path, label: str, maximum: int = 1024 * 1024) -> Mapping[str, object]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0 or path.stat().st_size > maximum:
        raise ValueError(f"{label} is not a bounded regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"{label} is not strict JSON") from error
    if not isinstance(value, Mapping):
        raise ValueError(f"{label} root must be an object")
    return value


def _canonical(value: Mapping[str, object], *, newline: bool = False) -> bytes:
    result = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
    ).encode("utf-8")
    return result + (b"\n" if newline else b"")


def _sha(raw: bytes) -> str:
    return "sha256:" + sha256(raw).hexdigest()


def _decode_signature(value: str) -> bytes:
    if SIGNATURE.fullmatch(value) is None:
        raise ValueError("catalog signature is not canonical unpadded base64url")
    raw = base64.urlsafe_b64decode(value + "==")
    if len(raw) != 64 or base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != value:
        raise ValueError("catalog signature is not one canonical Ed25519 signature")
    return raw


def _decode_public_key(value: str) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("catalog public key is not canonical base64") from error
    if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != value:
        raise ValueError("catalog public key is not one canonical Ed25519 public key")
    return raw


def _verify_openssl(payload: bytes, signature: bytes, public_key: bytes) -> bool:
    with tempfile.TemporaryDirectory(prefix="forge-catalog-signature-") as directory:
        root = Path(directory)
        payload_path = root / "payload.json"
        signature_path = root / "signature.bin"
        key_path = root / "public-key.der"
        payload_path.write_bytes(payload)
        signature_path.write_bytes(signature)
        key_path.write_bytes(SPKI_PREFIX + public_key)
        result = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER",
                "-inkey", str(key_path), "-rawin", "-in", str(payload_path),
                "-sigfile", str(signature_path),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0


class _OpenSSLVerifier:
    def __init__(self, keys: Mapping[str, bytes]) -> None:
        self.keys = keys

    def verify(
        self,
        canonical_payload: bytes,
        signatures: tuple[PublicSignatureEnvelope, ...],
        *,
        policy: SignatureThresholdPolicy,
    ) -> bool:
        valid = 0
        for signature in signatures:
            key = self.keys.get(signature.key_id)
            if key is not None and _verify_openssl(
                canonical_payload,
                _decode_signature(signature.signature),
                key,
            ):
                valid += 1
        return valid >= policy.threshold


def finalize(
    *,
    candidate_directory: Path,
    signature_paths: tuple[Path, ...],
    catalog_trust_path: Path,
    output_directory: Path,
    workflow_run_id: int,
    workflow_run_attempt: int,
) -> Mapping[str, object]:
    candidate = _load(
        candidate_directory / "composition-catalog-candidate.json", "catalog candidate"
    )
    if candidate.get("schema") != CANDIDATE_SCHEMA:
        raise ValueError("catalog candidate schema is unsupported")
    unsigned_path = candidate_directory / "composition-catalog-unsigned.json"
    if unsigned_path.is_symlink() or not unsigned_path.is_file():
        raise ValueError("unsigned catalog payload is missing")
    unsigned_raw = unsigned_path.read_bytes()
    if _sha(unsigned_raw) != candidate.get("unsigned_catalog_digest"):
        raise ValueError("unsigned catalog bytes do not match the candidate digest")
    unsigned = _load(unsigned_path, "unsigned catalog")
    if _canonical(unsigned) != unsigned_raw or "signatures" in unsigned:
        raise ValueError("unsigned catalog payload is not exact canonical JSON")

    trust = _load(catalog_trust_path, "catalog trust resource", maximum=32 * 1024)
    expected_trust_fields = {
        "schema_version", "configuration_sha256",
        "installer_release_trust_configuration_sha256", "signature_threshold",
        "ed25519_public_keys",
    }
    if set(trust) != expected_trust_fields or trust["schema_version"] != 1:
        raise ValueError("catalog trust resource fields are invalid")
    threshold = trust["signature_threshold"]
    key_values = trust["ed25519_public_keys"]
    if type(threshold) is not int or threshold <= 0 or not isinstance(key_values, list):
        raise ValueError("catalog trust threshold is invalid")
    keys: dict[str, bytes] = {}
    for value in key_values:
        if not isinstance(value, Mapping) or set(value) != {"key_id", "public_key_base64"}:
            raise ValueError("catalog trust key entry is invalid")
        key_id = value["key_id"]
        public = value["public_key_base64"]
        if not isinstance(key_id, str) or KEY_ID.fullmatch(key_id) is None or not isinstance(public, str):
            raise ValueError("catalog trust key entry is invalid")
        if key_id in keys:
            raise ValueError("catalog trust key IDs are duplicated")
        keys[key_id] = _decode_public_key(public)
    if threshold > len(keys) or list(keys) != sorted(keys):
        raise ValueError("catalog trust keys or threshold are invalid")
    trust_tokens = [
        "forge-platform-installer-composition-catalog-trust-v1",
        "schema_version=1",
        "installer_release_trust_configuration_sha256="
        + str(trust["installer_release_trust_configuration_sha256"]),
        f"signature_threshold={threshold}",
        f"ed25519_public_key_count={len(keys)}",
    ]
    for value in key_values:
        trust_tokens.extend(
            [
                "ed25519_public_key_id=" + str(value["key_id"]),
                "ed25519_public_key_base64=" + str(value["public_key_base64"]),
            ]
        )
    expected_configuration = sha256("\0".join(trust_tokens).encode("utf-8")).hexdigest()
    if trust.get("configuration_sha256") != expected_configuration:
        raise ValueError("catalog trust configuration digest is invalid")
    if candidate.get("catalog_key_ids") != list(keys):
        raise ValueError("catalog candidate key IDs do not match sealed public trust")

    envelopes: list[Mapping[str, object]] = []
    seen: set[str] = set()
    for path in signature_paths:
        envelope = _load(path, "catalog signature envelope", maximum=4096)
        if set(envelope) != {"algorithm", "key_id", "signature"} or envelope["algorithm"] != "ed25519":
            raise ValueError("catalog signature envelope fields are invalid")
        key_id = envelope["key_id"]
        signature = envelope["signature"]
        if not isinstance(key_id, str) or key_id not in keys or key_id in seen or not isinstance(signature, str):
            raise ValueError("catalog signature key is invalid or duplicated")
        if not _verify_openssl(unsigned_raw, _decode_signature(signature), keys[key_id]):
            raise ValueError("catalog signature does not verify against sealed public trust")
        seen.add(key_id)
        envelopes.append(dict(envelope))
    if len(seen) < threshold:
        raise ValueError("catalog signature threshold is not satisfied")
    envelopes.sort(key=lambda value: str(value["key_id"]))

    signed = dict(unsigned)
    signed["signatures"] = envelopes
    signed_raw = _canonical(signed, newline=True)
    policy = SignatureThresholdPolicy(
        algorithm="ed25519", trusted_key_ids=frozenset(keys), threshold=threshold
    )
    verified = CompositionCatalog.from_signed_bytes(
        signed_raw,
        _OpenSSLVerifier(keys),
        signature_policy=policy,
    )
    if verified.sequence != candidate.get("sequence") or verified.catalog_digest != _sha(signed_raw):
        raise ValueError("signed catalog parser did not reproduce the candidate identity")

    manifest_name = candidate.get("manifest_asset_name")
    index_name = candidate.get("component_combination_catalog_asset_name")
    if not isinstance(manifest_name, str) or not isinstance(index_name, str):
        raise ValueError("candidate publication asset names are invalid")
    manifest_raw = (candidate_directory / manifest_name).read_bytes()
    index_raw = (candidate_directory / index_name).read_bytes()
    if _sha(manifest_raw) != candidate.get("manifest_digest") or _sha(index_raw) != candidate.get(
        "component_combination_catalog_digest"
    ):
        raise ValueError("candidate immutable asset digests changed before signing")

    operation: dict[str, object] = {
        "schema": OPERATION_SCHEMA,
        "assignment_id": candidate["assignment_id"],
        "repository": candidate["repository"],
        "source_sha": candidate["source_sha"],
        "sequence": candidate["sequence"],
        "composition_id": candidate["composition_id"],
        "immutable_release_tag": candidate["immutable_release_tag"],
        "stable_release_tag": candidate["stable_release_tag"],
        "catalog_asset_name": CATALOG_ASSET,
        "catalog_digest": _sha(signed_raw),
        "manifest_asset_name": manifest_name,
        "manifest_digest": candidate["manifest_digest"],
        "component_combination_catalog_asset_name": index_name,
        "component_combination_catalog_digest": candidate[
            "component_combination_catalog_digest"
        ],
        "signature_key_ids": sorted(seen),
        "workflow_run_id": workflow_run_id,
        "workflow_run_attempt": workflow_run_attempt,
        "state": "QUALIFIED",
    }
    if output_directory.exists():
        raise ValueError("output directory already exists")
    output_directory.mkdir(mode=0o700, parents=True)
    (output_directory / CATALOG_ASSET).write_bytes(signed_raw)
    (output_directory / manifest_name).write_bytes(manifest_raw)
    (output_directory / index_name).write_bytes(index_raw)
    (output_directory / "composition-catalog-operation.json").write_bytes(
        _canonical(operation, newline=True)
    )
    return operation


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-directory", required=True)
    parser.add_argument("--signature", action="append", required=True)
    parser.add_argument("--catalog-trust", required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--workflow-run-id", required=True, type=int)
    parser.add_argument("--workflow-run-attempt", required=True, type=int)
    args = parser.parse_args(argv)
    try:
        operation = finalize(
            candidate_directory=Path(args.candidate_directory),
            signature_paths=tuple(Path(path) for path in args.signature),
            catalog_trust_path=Path(args.catalog_trust),
            output_directory=Path(args.output_directory),
            workflow_run_id=args.workflow_run_id,
            workflow_run_attempt=args.workflow_run_attempt,
        )
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        print(f"SIGNED_COMPOSITION_CATALOG=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "SIGNED_COMPOSITION_CATALOG=PASS"
        f" sequence={operation['sequence']}"
        f" catalog_digest={operation['catalog_digest']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
