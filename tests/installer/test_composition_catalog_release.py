#!/usr/bin/env python3
"""Behavioral checks for protected composition-catalog preparation/signing."""
from __future__ import annotations

import base64
from hashlib import sha256
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.universal_installer import CompositionCatalog, SignatureThresholdPolicy
from tests.installer.test_universal_installer import manifest_payload


WORKFLOW = ROOT / ".github/workflows/forge-platform-composition-catalog-release.yml"
LOCAL_RELEASE = ROOT / "scripts/run_local_composition_catalog_release.sh"


def load_script(name: str):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.removesuffix(".py"), path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load_script("prepare_composition_catalog_candidate.py")
FINALIZE = load_script("finalize_signed_composition_catalog.py")
VERIFY = load_script("verify_local_catalog_authorization.py")


class CompositionCatalogReleaseTests(unittest.TestCase):
    source_sha = "a" * 40
    key_id = "catalog-test-key"
    published_at = "2026-09-24T12:00:00Z"
    expires_at = "2026-10-24T12:00:00Z"

    @staticmethod
    def canonical(value: object) -> bytes:
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
        ).encode("utf-8")

    def write_inputs(self, root: Path) -> tuple[Path, Path]:
        capabilities = (
            "catalog-component-set/v1",
            "composition/v1",
            "managed-python-runtime/v1",
            "provider-gate/v1",
            "system-launchdaemon/v1",
        )
        manifest = manifest_payload(capabilities=capabilities)
        manifest_path = root / "composition.json"
        manifest_path.write_bytes(self.canonical(manifest) + b"\n")
        manifest_digest = "sha256:" + sha256(manifest_path.read_bytes()).hexdigest()
        manifest_url = (
            "https://github.com/autonomous-engineering-system/forge-platform/releases/download/"
            "forge-platform-composition-catalog-v1/ForgePlatformComposition-1.json"
        )
        index = {
            "schema": "forge-platform.component-combination-catalog/v1",
            "sequence": 1,
            "channel": "stable",
            "published_at": self.published_at,
            "expires_at": self.expires_at,
            "compositions": [{
                "composition_id": manifest["composition_id"],
                "selection_sequence": 1,
                "channel": "stable",
                "manifest": {"url": manifest_url, "digest": manifest_digest},
                "components": [{
                    "identity": "engineering-platform-server",
                    "requires_capabilities": ["composition/v1"],
                }],
                "requires_installer": {
                    "minimum_version": "1.0.0",
                    "capabilities": list(capabilities),
                },
                "upgrade_from": list(manifest["upgrade_from"]),
            }],
        }
        index_path = root / "index.json"
        index_path.write_bytes(self.canonical(index) + b"\n")
        return manifest_path, index_path

    def generate_key_and_trust(self, root: Path) -> tuple[Path, bytes]:
        private_key = root / "private.pem"
        public_der = root / "public.der"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private_key)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "openssl", "pkey", "-in", str(private_key), "-pubout",
                "-outform", "DER", "-out", str(public_der),
            ],
            check=True,
            capture_output=True,
        )
        raw_public = public_der.read_bytes()[-32:]
        public_base64 = base64.b64encode(raw_public).decode("ascii")
        tokens = [
            "forge-platform-installer-composition-catalog-trust-v1",
            "schema_version=1",
            "installer_release_trust_configuration_sha256=" + ("b" * 64),
            "signature_threshold=1",
            "ed25519_public_key_count=1",
            "ed25519_public_key_id=" + self.key_id,
            "ed25519_public_key_base64=" + public_base64,
        ]
        trust = {
            "schema_version": 1,
            "configuration_sha256": sha256("\0".join(tokens).encode("utf-8")).hexdigest(),
            "installer_release_trust_configuration_sha256": "b" * 64,
            "signature_threshold": 1,
            "ed25519_public_keys": [{
                "key_id": self.key_id,
                "public_key_base64": public_base64,
            }],
        }
        trust_path = root / "catalog-trust.json"
        trust_path.write_text(json.dumps(trust, sort_keys=True) + "\n", encoding="utf-8")
        return private_key, raw_public

    def sign_candidate(self, root: Path, candidate_directory: Path) -> tuple[Path, bytes]:
        private_key, raw_public = self.generate_key_and_trust(root)
        signature_raw = root / "signature.bin"
        subprocess.run(
            [
                "openssl", "pkeyutl", "-sign", "-inkey", str(private_key), "-rawin",
                "-in", str(candidate_directory / "composition-catalog-unsigned.json"),
                "-out", str(signature_raw),
            ],
            check=True,
            capture_output=True,
        )
        envelope = {
            "algorithm": "ed25519",
            "key_id": self.key_id,
            "signature": base64.urlsafe_b64encode(signature_raw.read_bytes()).decode("ascii").rstrip("="),
        }
        envelope_path = root / "signature.json"
        envelope_path.write_text(json.dumps(envelope) + "\n", encoding="utf-8")
        return envelope_path, raw_public

    def prepare(self, root: Path) -> tuple[Path, dict[str, object]]:
        manifest_path, index_path = self.write_inputs(root)
        candidate_directory = root / "candidate"
        candidate = PREPARE.prepare(
            manifest_path=manifest_path,
            index_path=index_path,
            output_directory=candidate_directory,
            source_sha=self.source_sha,
            sequence=1,
            published_at=self.published_at,
            expires_at=self.expires_at,
            manifest_asset_name="ForgePlatformComposition-1.json",
            index_asset_name="ForgePlatformComponentCombinationCatalog-1.json",
            key_ids=(self.key_id,),
        )
        return candidate_directory, dict(candidate)

    def test_exact_inputs_prepare_sign_and_verify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_directory, candidate = self.prepare(root)
            self.assertEqual(candidate["sequence"], 1)
            envelope_path, raw_public = self.sign_candidate(root, candidate_directory)
            output = root / "release"
            self.assertEqual(FINALIZE.main([
                "--candidate-directory", str(candidate_directory),
                "--signature", str(envelope_path),
                "--catalog-trust", str(root / "catalog-trust.json"),
                "--output-directory", str(output),
                "--workflow-run-id", "123",
                "--workflow-run-attempt", "1",
            ]), 0)
            operation = json.loads((output / "composition-catalog-operation.json").read_text())
            self.assertEqual(operation["state"], "QUALIFIED")
            catalog = CompositionCatalog.from_signed_bytes(
                (output / "ForgePlatformInstallerCompositionCatalog.json").read_bytes(),
                FINALIZE._OpenSSLVerifier({self.key_id: raw_public}),
                signature_policy=SignatureThresholdPolicy(
                    algorithm="ed25519", trusted_key_ids=frozenset({self.key_id}), threshold=1
                ),
            )
            self.assertEqual(catalog.sequence, 1)
            self.assertEqual(catalog.entries[0].composition_id, candidate["composition_id"])

    def test_prepare_command_line_covers_exact_success_and_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path, index_path = self.write_inputs(root)
            arguments = [
                "--manifest", str(manifest_path),
                "--component-index", str(index_path),
                "--output-directory", str(root / "candidate"),
                "--source-sha", self.source_sha,
                "--sequence", "1",
                "--published-at", self.published_at,
                "--expires-at", self.expires_at,
                "--manifest-asset-name", "ForgePlatformComposition-1.json",
                "--index-asset-name", "ForgePlatformComponentCombinationCatalog-1.json",
                "--key-id", self.key_id,
            ]
            self.assertEqual(PREPARE.main(arguments), 0)
            arguments[arguments.index(self.source_sha)] = "not-a-sha"
            arguments[arguments.index(str(root / "candidate"))] = str(root / "rejected")
            self.assertEqual(PREPARE.main(arguments), 1)

    def test_prepare_rejects_index_manifest_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path, index_path = self.write_inputs(root)
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["compositions"][0]["manifest"]["digest"] = "sha256:" + ("f" * 64)
            index_path.write_bytes(self.canonical(index) + b"\n")
            with self.assertRaisesRegex(ValueError, "does not exactly bind"):
                PREPARE.prepare(
                    manifest_path=manifest_path,
                    index_path=index_path,
                    output_directory=root / "candidate",
                    source_sha=self.source_sha,
                    sequence=1,
                    published_at=self.published_at,
                    expires_at=self.expires_at,
                    manifest_asset_name="ForgePlatformComposition-1.json",
                    index_asset_name="ForgePlatformComponentCombinationCatalog-1.json",
                    key_ids=(self.key_id,),
                )

    def test_finalize_rejects_changed_unsigned_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_directory, _ = self.prepare(root)
            unsigned = candidate_directory / "composition-catalog-unsigned.json"
            unsigned.write_bytes(unsigned.read_bytes() + b"\n")
            self.generate_key_and_trust(root)
            envelope_path = root / "signature.json"
            envelope_path.write_text(
                json.dumps({
                    "algorithm": "ed25519",
                    "key_id": self.key_id,
                    "signature": "A" * 86,
                }) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "candidate digest"):
                FINALIZE.finalize(
                    candidate_directory=candidate_directory,
                    signature_paths=(envelope_path,),
                    catalog_trust_path=root / "catalog-trust.json",
                    output_directory=root / "release",
                    workflow_run_id=123,
                    workflow_run_attempt=1,
                )

    def test_workflow_is_exact_protected_main_and_credentialless(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        for guard in (
            "github.repository == 'autonomous-engineering-system/forge-platform'",
            "github.ref == 'refs/heads/main'",
            "github.ref_protected",
            "github.sha == inputs.source_sha",
            "github.workflow_sha == inputs.source_sha",
        ):
            self.assertIn(guard, workflow)
        self.assertIn("group: forge-platform-build", workflow)
        self.assertIn("labels: forge-platform-build", workflow)
        self.assertIn("catalog-signing-key-visible", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("contents: write", workflow)
        authorization = workflow.split("  authorize-local-catalog-signing:\n", 1)[1]
        self.assertIn("name: forge-platform-installer-signing", authorization)
        self.assertIn('"result": "AUTHORIZED_FOR_LOCAL_CATALOG_SIGNER"', authorization)

    def test_local_catalog_release_owns_keys_publication_and_readback(self) -> None:
        local = LOCAL_RELEASE.read_text(encoding="utf-8")
        for required in (
            "verify_local_catalog_authorization.py",
            "OfflineCompositionCatalogKeyTool.swift",
            "exclusive-offline-signing",
            "git rev-parse origin/main",
            "finalize_signed_composition_catalog.py",
            "stable-catalog-sequence-regression",
            "stable-catalog-same-sequence-different-bytes",
            "gh release upload",
            "gh release download",
            "LOCAL_COMPOSITION_CATALOG_RELEASE=PASS",
        ):
            self.assertIn(required, local)
        self.assertNotIn("security export", local)
        self.assertNotIn("set-key-partition-list", local)

    def test_catalog_and_installer_share_one_exclusive_signing_lock(self) -> None:
        installer = (ROOT / "scripts/run_local_macos_installer_release.sh").read_text(encoding="utf-8")
        catalog = LOCAL_RELEASE.read_text(encoding="utf-8")
        self.assertIn('LOCK="$STATE_ROOT/locks/exclusive-offline-signing"', installer)
        self.assertIn('LOCK="$STATE_ROOT/locks/exclusive-offline-signing"', catalog)

    def authorization_fixture(self, root: Path) -> tuple[Path, Path, Path]:
        root.mkdir(parents=True, exist_ok=True)
        candidate_directory, candidate = self.prepare(root)
        candidate_path = candidate_directory / "composition-catalog-candidate.json"
        candidate_digest = "sha256:" + sha256(candidate_path.read_bytes()).hexdigest()
        authorization = {
            "schema": "forge-platform.local-catalog-signing-authorization/v1",
            "repository": "autonomous-engineering-system/forge-platform",
            "ref": "refs/heads/main",
            "source_sha": self.source_sha,
            "workflow_sha": self.source_sha,
            "workflow": "Forge Platform composition catalog release framework",
            "run_id": 123,
            "run_attempt": 1,
            "environment": "forge-platform-installer-signing",
            "candidate_artifact": f"forge-platform-composition-catalog-candidate-1-{self.source_sha}",
            "candidate_digest": candidate_digest,
            "unsigned_catalog_digest": candidate["unsigned_catalog_digest"],
            "catalog_sequence": 1,
            "requested_by": "pcvantol",
            "result": "AUTHORIZED_FOR_LOCAL_CATALOG_SIGNER",
        }
        authorization_path = root / "authorization.json"
        authorization_path.write_text(json.dumps(authorization) + "\n", encoding="utf-8")
        metadata = {
            "databaseId": 123,
            "headBranch": "main",
            "headSha": self.source_sha,
            "event": "workflow_dispatch",
            "conclusion": "success",
            "workflowName": "Forge Platform composition catalog release framework",
            "url": "https://github.com/autonomous-engineering-system/forge-platform/actions/runs/123",
            "jobs": [
                {"name": "Build unsigned composition catalog candidate", "conclusion": "success"},
                {"name": "Authorize exact local catalog signing handoff", "conclusion": "success"},
            ],
        }
        metadata_path = root / "run.json"
        metadata_path.write_text(json.dumps(metadata) + "\n", encoding="utf-8")
        return authorization_path, metadata_path, candidate_directory

    def test_local_authorization_exact_success_and_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authorization, metadata, candidate = self.authorization_fixture(root)
            result = VERIFY.verify(
                authorization_path=authorization,
                run_metadata_path=metadata,
                candidate_directory=candidate,
                source_sha=self.source_sha,
                run_id=123,
            )
            self.assertEqual(result["catalog_sequence"], 1)
            self.assertEqual(VERIFY.main([
                "--authorization", str(authorization),
                "--run-metadata", str(metadata),
                "--candidate-directory", str(candidate),
                "--source-sha", self.source_sha,
                "--run-id", "123",
            ]), 0)

    def test_local_authorization_rejects_job_candidate_and_source_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authorization, metadata, candidate = self.authorization_fixture(root)
            changed_metadata = json.loads(metadata.read_text())
            changed_metadata["jobs"][1]["conclusion"] = "failure"
            metadata.write_text(json.dumps(changed_metadata))
            with self.assertRaisesRegex(ValueError, "did not succeed"):
                VERIFY.verify(
                    authorization_path=authorization,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha=self.source_sha,
                    run_id=123,
                )

            _, metadata, _ = self.authorization_fixture(root / "second")
            candidate_file = candidate / "composition-catalog-unsigned.json"
            candidate_file.write_bytes(candidate_file.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "unsigned catalog bytes"):
                VERIFY.verify(
                    authorization_path=authorization,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha=self.source_sha,
                    run_id=123,
                )
            with self.assertRaisesRegex(ValueError, "source SHA"):
                VERIFY.verify(
                    authorization_path=authorization,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha="invalid",
                    run_id=123,
                )


if __name__ == "__main__":
    unittest.main()
