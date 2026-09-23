#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

from forge_platform.composition_catalog_trust import canonical_composition_catalog_trust_configuration_sha256
from forge_platform.installer_release_operation import INSTALLER_RELEASE_POLICY_REVISION
from forge_platform.installer_release_provenance import parse_installer_release_provenance_bytes
from forge_platform.installer_release_trust import canonical_release_trust_configuration_sha256
from prepare_offline_installer_resources import prepare


class PrepareOfflineInstallerResourcesTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, Path, Path]:
        keys = [
            ("descriptor-key-001", base64.b64encode(b"a" * 32).decode("ascii")),
            ("descriptor-key-002", base64.b64encode(b"b" * 32).decode("ascii")),
        ]
        trust_digest = canonical_release_trust_configuration_sha256(
            repository="pcvantol/forge-platform",
            release_descriptor_locator="github-release-asset-v1",
            release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
            expected_bundle_identifier="com.pcvantol.forge-platform-installer",
            expected_team_identifier="ABCDEFGHIJ",
            signature_threshold=2,
            ed25519_public_keys=keys,
        )
        identity = root / "identity.json"
        identity.write_text(json.dumps({
            "schema":"forge-platform.installer-release-identity/v1",
            "status":"READY",
            "identity":{
                "github_repository":"pcvantol/forge-platform",
                "bundle_identifier":"com.pcvantol.forge-platform-installer",
                "team_identifier":"ABCDEFGHIJ",
                "release_tag_prefix":"installer-v",
                "asset_prefix":"ForgePlatformInstaller-",
                "release_descriptor_asset_name":"ForgePlatformInstallerReleaseDescriptor.json",
                "release_trust_configuration_sha256":trust_digest,
            },
            "signing_key_policy":{
                "algorithm":"ed25519",
                "key_ids":["descriptor-key-001","descriptor-key-002"],
                "threshold":2,
            },
        }, sort_keys=True), encoding="utf-8")
        trust = root / "trust.json"
        trust.write_text(json.dumps({
            "schema_version":2,
            "configuration_sha256":trust_digest,
            "repository":"pcvantol/forge-platform",
            "release_descriptor_locator":"github-release-asset-v1",
            "release_descriptor_asset_name":"ForgePlatformInstallerReleaseDescriptor.json",
            "expected_bundle_identifier":"com.pcvantol.forge-platform-installer",
            "expected_team_identifier":"ABCDEFGHIJ",
            "signature_threshold":2,
            "ed25519_public_keys":[
                {"key_id":key_id,"public_key_base64":material} for key_id,material in keys
            ],
        }, sort_keys=True), encoding="utf-8")
        catalog_keys=[("catalog-key-001", base64.b64encode(b"c"*32).decode("ascii"))]
        catalog_digest=canonical_composition_catalog_trust_configuration_sha256(
            installer_release_trust_configuration_sha256=trust_digest,
            signature_threshold=1,
            ed25519_public_keys=catalog_keys,
        )
        catalog=root / "catalog.json"
        catalog.write_text(json.dumps({
            "schema_version":1,
            "configuration_sha256":catalog_digest,
            "installer_release_trust_configuration_sha256":trust_digest,
            "signature_threshold":1,
            "ed25519_public_keys":[
                {"key_id":"catalog-key-001","public_key_base64":catalog_keys[0][1]}
            ],
        }, sort_keys=True), encoding="utf-8")
        return identity, trust, catalog

    def source_root(self, root: Path) -> Path:
        source=root / "source"
        source.mkdir()
        (source/"installer-version.json").write_text(json.dumps({
            "schema":"forge-platform.installer-version/v1",
            "product":"forge-platform-installer",
            "version":"0.3.0",
            "channel":"stable",
            "capabilities":["composition/v1","installer-cli/v1"],
        }), encoding="utf-8")
        return source

    def test_generates_strict_provenance_bound_to_reviewed_identity_and_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            identity, trust, catalog=self.fixture(root)
            source=self.source_root(root)
            output=root/"private"/"ForgePlatformInstallerReleaseProvenance.json"
            value=prepare(
                root=source,
                release_identity=identity,
                release_trust_resource=trust,
                catalog_trust_resource=catalog,
                source_revision="a"*40,
                release_sequence=9,
                output=output,
            )
            restored=parse_installer_release_provenance_bytes(output.read_bytes())
            self.assertEqual(restored, value)
            self.assertEqual(value.policy_revision, INSTALLER_RELEASE_POLICY_REVISION)
            self.assertEqual(value.release_sequence, 9)
            self.assertEqual(value.capabilities, ("composition/v1","installer-cli/v1"))
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_rejects_trust_identity_or_catalog_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            identity, trust, catalog=self.fixture(root)
            source=self.source_root(root)
            payload=json.loads(catalog.read_text())
            payload["installer_release_trust_configuration_sha256"]="f"*64
            catalog.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "composition catalog trust"):
                prepare(
                    root=source,
                    release_identity=identity,
                    release_trust_resource=trust,
                    catalog_trust_resource=catalog,
                    source_revision="a"*40,
                    release_sequence=1,
                    output=root/"out.json",
                )

    def test_existing_different_output_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            identity, trust, catalog=self.fixture(root)
            source=self.source_root(root)
            output=root/"out.json"
            output.write_text("foreign", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "different bytes"):
                prepare(
                    root=source,
                    release_identity=identity,
                    release_trust_resource=trust,
                    catalog_trust_resource=catalog,
                    source_revision="a"*40,
                    release_sequence=1,
                    output=output,
                )
            self.assertEqual(output.read_text(), "foreign")


if __name__ == "__main__":
    unittest.main()
