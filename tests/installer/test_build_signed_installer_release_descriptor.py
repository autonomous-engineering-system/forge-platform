#!/usr/bin/env python3
from __future__ import annotations

import base64
from dataclasses import asdict
from hashlib import sha256
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))

from forge_platform.installer_release_operation import (
    INSTALLER_RELEASE_POLICY_REVISION,
    InstallerPreparationEvidence,
    InstallerReleaseIdentity,
    InstallerReleasePreparation,
)
from forge_platform.installer_release_trust import canonical_release_trust_configuration_sha256

SCRIPT=ROOT/"scripts"/"build_signed_installer_release_descriptor.py"
SOURCE="a"*40
PUBLIC=base64.b64encode(bytes(range(32))).decode("ascii")

class SignedDescriptorBuilderTests(unittest.TestCase):
    def test_builds_exact_threshold_signed_descriptor(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            inputs=self.write_inputs(root)
            result=self.run(inputs)
            self.assertEqual(result.returncode,0,result.stderr)
            descriptor=json.loads(inputs["output"].read_text())
            self.assertEqual(descriptor["sequence"],8)
            self.assertEqual(descriptor["github_release"]["tag"],"forge-platform-installer-v0.2.0")
            self.assertEqual(descriptor["installer"]["assets"][0]["digest"],"sha256:"+sha256(inputs["archive"].read_bytes()).hexdigest())
            self.assertEqual(descriptor["signatures"],[{
                "algorithm":"ed25519","key_id":"release-key-001","signature":"A"*86,
            }])
            calls=(root/"crypto-calls.txt").read_text()
            self.assertIn("sign --key-id release-key-001",calls)
            self.assertIn("verify --payload",calls)

    def test_rejects_signer_public_key_mismatch_and_bad_catalog_url(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td); inputs=self.write_inputs(root,public_key="wrong")
            result=self.run(inputs)
            self.assertNotEqual(result.returncode,0)
            self.assertIn("public trust",result.stderr)

        with tempfile.TemporaryDirectory() as td:
            root=Path(td);inputs=self.write_inputs(root)
            result=self.run(inputs,catalog_url="http://example.invalid/catalog.json")
            self.assertNotEqual(result.returncode,0)
            self.assertIn("HTTPS",result.stderr)

    def write_inputs(self,root:Path,public_key:str=PUBLIC):
        trust_digest=canonical_release_trust_configuration_sha256(
            repository="example/forge-platform",release_descriptor_locator="github-release-asset-v1",
            release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
            expected_bundle_identifier="com.example.forge-platform-installer",
            expected_team_identifier="ABCDE12345",signature_threshold=1,
            ed25519_public_keys=(("release-key-001",PUBLIC),),
        )
        identity=InstallerReleaseIdentity(
            "example/forge-platform","com.example.forge-platform-installer","ABCDE12345",
            "forge-platform-installer-v","ForgePlatformInstaller-macos-",
            "ForgePlatformInstallerReleaseDescriptor.json",trust_digest,"ed25519",
            ("release-key-001",),1,
        )
        preparation=InstallerReleasePreparation(
            "forge-platform-installer-0.2.0-"+"a"*40,"0.2.0","stable",8,SOURCE,
            INSTALLER_RELEASE_POLICY_REVISION,"b"*64,identity,
            ("composition/v2","provider-targets/v1"),
            InstallerPreparationEvidence("sha256:"+"c"*64,{"arm64":"sha256:"+"d"*64},"receipt:prepared"),
        )
        prep=root/"prep.json";prep.write_text(json.dumps(asdict(preparation),sort_keys=True))
        identity_path=root/"identity.json";identity_path.write_text(json.dumps({
            "schema":"forge-platform.installer-release-identity/v1","status":"READY",
            "identity":{
                "github_repository":identity.github_repository,"bundle_identifier":identity.bundle_identifier,
                "team_identifier":identity.team_identifier,"release_tag_prefix":identity.release_tag_prefix,
                "asset_prefix":identity.asset_prefix,"release_descriptor_asset_name":identity.release_descriptor_asset_name,
                "release_trust_configuration_sha256":trust_digest,
            },
            "signing_key_policy":{"algorithm":"ed25519","key_ids":["release-key-001"],"threshold":1},
        }))
        trust=root/"trust.json";trust.write_text(json.dumps({
            "schema_version":2,"configuration_sha256":trust_digest,
            "repository":identity.github_repository,"release_descriptor_locator":"github-release-asset-v1",
            "release_descriptor_asset_name":identity.release_descriptor_asset_name,
            "expected_bundle_identifier":identity.bundle_identifier,"expected_team_identifier":identity.team_identifier,
            "signature_threshold":1,
            "ed25519_public_keys":[{"key_id":"release-key-001","public_key_base64":PUBLIC}],
        },sort_keys=True,separators=(",",":")))
        archive=root/"ForgePlatformInstaller-macos-arm64.zip";archive.write_bytes(b"signed archive bytes")
        crypto=root/"ForgePlatformInstallerReleaseCrypto"
        crypto.write_text(
            "#!/usr/bin/env python3\n"
            "import json,sys,pathlib\n"
            "root=pathlib.Path(__file__).parent\n"
            "with (root/'crypto-calls.txt').open('a') as f:f.write(' '.join(sys.argv[1:])+'\\n')\n"
            "if sys.argv[1]=='sign': print(json.dumps({'algorithm':'ed25519','key_id':'release-key-001','public_key_base64':"
            +repr(public_key)+",'signature':'"+"A"*86+"'}));sys.exit(0)\n"
            "if sys.argv[1]=='verify': print('INSTALLER_RELEASE_ED25519=PASS');sys.exit(0)\n"
            "sys.exit(2)\n"
        )
        crypto.chmod(0o755)
        return {"prep":prep,"identity":identity_path,"trust":trust,"archive":archive,"crypto":crypto,"output":root/"descriptor.json"}

    @staticmethod
    def run(inputs,catalog_url="https://catalog.example.invalid/stable.json"):
        return subprocess.run([
            sys.executable,str(SCRIPT),"--preparation",str(inputs["prep"]),
            "--release-identity",str(inputs["identity"]),"--release-trust",str(inputs["trust"]),
            "--archive",str(inputs["archive"]),"--code-directory-sha256","e"*64,
            "--notarization-receipt-reference","receipt:apple-notary-001",
            "--composition-catalog-url",catalog_url,
            "--published-at","2026-09-23T07:00:00Z","--expires-at","2026-10-23T07:00:00Z",
            "--crypto-executable",str(inputs["crypto"].resolve()),"--output",str(inputs["output"]),
        ],cwd=ROOT,capture_output=True,text=True)

if __name__=="__main__":
    unittest.main()
