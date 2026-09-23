#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))

from forge_platform.composition_catalog_trust import canonical_composition_catalog_trust_configuration_sha256
from forge_platform.installer_release_provenance import canonical_release_provenance_sha256
from forge_platform.installer_release_trust import canonical_release_trust_configuration_sha256

SCRIPT=ROOT/"scripts"/"prepare_installer_public_resources.py"
SOURCE="a"*40
TEAM="ABCDE12345"
KEYS=(("release-key-001",base64.b64encode(bytes(range(32))).decode("ascii")),)

class PublicResourceTests(unittest.TestCase):
    def test_prepares_exact_cross_bound_public_resources(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            inputs=self.write_inputs(root)
            result=self.run(inputs)
            self.assertEqual(result.returncode,0,result.stderr)
            provenance=json.loads((root/"out"/"ForgePlatformInstallerReleaseProvenance.json").read_text())
            self.assertEqual(provenance["provenance_sha256"],inputs["provenance"])
            self.assertEqual(provenance["source_revision"],SOURCE)
            self.assertEqual(provenance["capabilities"],["composition/v2","provider-targets/v1"])
            self.assertEqual(
                (root/"out"/"ForgePlatformInstallerReleaseTrust.json").read_bytes(),
                inputs["release_trust"].read_bytes(),
            )

    def test_rejects_release_trust_identity_or_catalog_scope_drift(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); inputs=self.write_inputs(root)
            trust=json.loads(inputs["release_trust"].read_text())
            trust["expected_team_identifier"]="ZZZZZZZZZZ"
            inputs["release_trust"].write_text(json.dumps(trust))
            result=self.run(inputs)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("release trust",result.stderr)

        with tempfile.TemporaryDirectory() as td:
            root=Path(td); inputs=self.write_inputs(root)
            catalog=json.loads(inputs["catalog_trust"].read_text())
            catalog["installer_release_trust_configuration_sha256"]="f"*64
            inputs["catalog_trust"].write_text(json.dumps(catalog))
            result=self.run(inputs)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("catalog trust",result.stderr)

    def test_rejects_wrong_expected_provenance(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); inputs=self.write_inputs(root)
            inputs["provenance"]="0"*64
            result=self.run(inputs)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("provenance digest",result.stderr)

    @staticmethod
    def write_inputs(root):
        release_digest=canonical_release_trust_configuration_sha256(
            repository="example/forge-platform",
            release_descriptor_locator="github-release-asset-v1",
            release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
            expected_bundle_identifier="com.example.forge-platform-installer",
            expected_team_identifier=TEAM,
            signature_threshold=1,
            ed25519_public_keys=KEYS,
        )
        release_trust=root/"release-trust.json"
        release_trust.write_text(json.dumps({
            "schema_version":2,
            "configuration_sha256":release_digest,
            "repository":"example/forge-platform",
            "release_descriptor_locator":"github-release-asset-v1",
            "release_descriptor_asset_name":"ForgePlatformInstallerReleaseDescriptor.json",
            "expected_bundle_identifier":"com.example.forge-platform-installer",
            "expected_team_identifier":TEAM,
            "signature_threshold":1,
            "ed25519_public_keys":[{"key_id":k,"public_key_base64":v} for k,v in KEYS],
        },sort_keys=True,separators=(",",":")))
        catalog_digest=canonical_composition_catalog_trust_configuration_sha256(
            installer_release_trust_configuration_sha256=release_digest,
            signature_threshold=1,
            ed25519_public_keys=KEYS,
        )
        catalog_trust=root/"catalog-trust.json"
        catalog_trust.write_text(json.dumps({
            "schema_version":1,
            "configuration_sha256":catalog_digest,
            "installer_release_trust_configuration_sha256":release_digest,
            "signature_threshold":1,
            "ed25519_public_keys":[{"key_id":k,"public_key_base64":v} for k,v in KEYS],
        },sort_keys=True,separators=(",",":")))
        identity=root/"identity.json"
        identity.write_text(json.dumps({
            "schema":"forge-platform.installer-release-identity/v1","status":"READY",
            "identity":{
                "github_repository":"example/forge-platform",
                "bundle_identifier":"com.example.forge-platform-installer",
                "team_identifier":TEAM,
                "release_tag_prefix":"forge-platform-installer-v",
                "asset_prefix":"ForgePlatformInstaller-macos-",
                "release_descriptor_asset_name":"ForgePlatformInstallerReleaseDescriptor.json",
                "release_trust_configuration_sha256":release_digest,
            },
            "signing_key_policy":{"algorithm":"ed25519","key_ids":["release-key-001"],"threshold":1},
        },sort_keys=True))
        manifest=root/"installer-version.json"
        manifest.write_text(json.dumps({
            "schema":"forge-platform.installer-version/v1","product":"forge-platform-installer",
            "version":"0.2.0","channel":"stable",
            "capabilities":["composition/v2","provider-targets/v1"],
        },sort_keys=True))
        provenance=canonical_release_provenance_sha256(
            installer_version="0.2.0",channel="stable",release_sequence=9,
            source_revision=SOURCE,policy_revision="forge-platform-installer-release-v1",
            release_trust_configuration_sha256=release_digest,
            capabilities=("composition/v2","provider-targets/v1"),
        )
        return {"identity":identity,"release_trust":release_trust,"catalog_trust":catalog_trust,"manifest":manifest,"provenance":provenance}

    @staticmethod
    def run(inputs):
        return subprocess.run([
            sys.executable,str(SCRIPT),
            "--release-identity",str(inputs["identity"]),
            "--release-trust",str(inputs["release_trust"]),
            "--composition-catalog-trust",str(inputs["catalog_trust"]),
            "--installer-version-manifest",str(inputs["manifest"]),
            "--source-sha",SOURCE,"--release-sequence","9",
            "--expected-provenance-sha256",inputs["provenance"],
            "--output-directory",str(inputs["manifest"].parent/"out"),
        ],cwd=ROOT,capture_output=True,text=True)

if __name__=="__main__":
    unittest.main()
