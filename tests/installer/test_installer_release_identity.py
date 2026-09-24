#!/usr/bin/env python3
"""Behavioural checks for reviewed installer release identity policy."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "installer_release_identity", ROOT / "scripts/validate_installer_release_identity.py"
)
assert SPEC and SPEC.loader
identity_policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identity_policy)


class InstallerReleaseIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "installer-release-identity.json"
        self.original_path = identity_policy.IDENTITY_PATH
        identity_policy.IDENTITY_PATH = self.path

    def tearDown(self) -> None:
        identity_policy.IDENTITY_PATH = self.original_path
        self.temporary.cleanup()

    def write(self, payload: dict[str, object]) -> None:
        self.path.write_text(json.dumps(payload), encoding="utf-8")

    def test_unconfigured_identity_is_visible_but_never_release_eligible(self) -> None:
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "UNCONFIGURED",
                "identity": None,
                "signing_key_policy": None,
            }
        )
        self.assertIsNone(identity_policy.load_identity())
        with self.assertRaisesRegex(RuntimeError, "publication is blocked"):
            identity_policy.load_identity(require_ready=True)

    def test_committed_ready_identity_and_public_trust_resources_are_exactly_bound(self) -> None:
        identity = identity_policy.load_identity(
            require_ready=True,
            path=ROOT / "installer-release-identity.json",
        )
        assert identity is not None
        identity_policy.validate_ready_resources(identity)

    def test_ready_identity_binds_public_app_repository_and_key_policy_facts(self) -> None:
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "READY",
                "identity": {
                    "github_repository": "example/forge-platform",
                    "bundle_identifier": "com.example.forge-platform-installer",
                    "team_identifier": "ABCDE12345",
                    "release_tag_prefix": "forge-platform-installer-v",
                    "asset_prefix": "ForgePlatformInstaller-macos-",
                    "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
                    "release_trust_configuration_sha256": "a" * 64,
                },
                "signing_key_policy": {
                    "algorithm": "ed25519",
                    "key_ids": ["release-key-001", "release-key-002"],
                    "threshold": 2,
                },
            }
        )
        identity = identity_policy.load_identity(require_ready=True)
        assert identity is not None
        self.assertEqual(identity.release_tag("1.2.3"), "forge-platform-installer-v1.2.3")
        self.assertEqual(identity.asset_name("arm64"), "ForgePlatformInstaller-macos-arm64.zip")
        self.assertEqual(identity.release_descriptor_asset_name, "ForgePlatformInstallerReleaseDescriptor.json")
        self.assertEqual(identity_policy._field(identity, "team_identifier"), "ABCDE12345")

    def test_partial_or_unapproved_identity_fails_closed(self) -> None:
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "UNCONFIGURED",
                "identity": {"github_repository": "example/forge-platform"},
                "signing_key_policy": None,
            }
        )
        with self.assertRaisesRegex(RuntimeError, "must not contain partial"):
            identity_policy.load_identity()

    def test_ready_identity_rejects_non_string_or_duplicate_signing_key_ids(self) -> None:
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "READY",
                "identity": {
                    "github_repository": "example/forge-platform",
                    "bundle_identifier": "com.example.forge-platform-installer",
                    "team_identifier": "ABCDE12345",
                    "release_tag_prefix": "forge-platform-installer-v",
                    "asset_prefix": "ForgePlatformInstaller-macos-",
                    "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
                    "release_trust_configuration_sha256": "a" * 64,
                },
                "signing_key_policy": {
                    "algorithm": "ed25519",
                    "key_ids": ["release-key-001", "release-key-001"],
                    "threshold": 1,
                },
            }
        )
        with self.assertRaisesRegex(RuntimeError, "identity is invalid"):
            identity_policy.load_identity(require_ready=True)
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "READY",
                "identity": {
                    "github_repository": "example/forge-platform",
                    "bundle_identifier": "com.example.forge-platform-installer",
                    "team_identifier": "ABCDE12345",
                    "release_tag_prefix": "forge-platform-installer-v",
                    "asset_prefix": "ForgePlatformInstaller-macos-",
                    "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
                    "release_trust_configuration_sha256": "a" * 64,
                },
                "signing_key_policy": {
                    "algorithm": "ed25519",
                    "key_ids": "release-key-001",
                    "threshold": 1,
                },
            }
        )
        with self.assertRaisesRegex(RuntimeError, "non-empty signing key ID list"):
            identity_policy.load_identity(require_ready=True)

    def test_ready_identity_prefixes_cannot_generate_unrepresentable_github_names(self) -> None:
        identity = {
            "github_repository": "example/forge-platform",
            "bundle_identifier": "com.example.forge-platform-installer",
            "team_identifier": "ABCDE12345",
            "release_tag_prefix": "r" * 69,
            "asset_prefix": "A" * 118,
            "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
            "release_trust_configuration_sha256": "a" * 64,
        }
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "READY",
                "identity": identity,
                "signing_key_policy": {"algorithm": "ed25519", "key_ids": ["release-key-001"], "threshold": 1},
            }
        )
        ready = identity_policy.load_identity(require_ready=True)
        assert ready is not None
        self.assertEqual(len(ready.release_tag("1.2.3")), 74)
        self.assertEqual(len(ready.asset_name("arm64")), 127)
        with self.assertRaisesRegex(ValueError, "architecture"):
            ready.asset_name("x86_64")

        identity["release_tag_prefix"] = "r" * 70
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "READY",
                "identity": identity,
                "signing_key_policy": {"algorithm": "ed25519", "key_ids": ["release-key-001"], "threshold": 1},
            }
        )
        with self.assertRaisesRegex(RuntimeError, "identity is invalid"):
            identity_policy.load_identity(require_ready=True)

        identity["release_tag_prefix"] = "r" * 69
        identity["asset_prefix"] = "A" * 119
        self.write(
            {
                "schema": identity_policy.SCHEMA,
                "status": "READY",
                "identity": identity,
                "signing_key_policy": {"algorithm": "ed25519", "key_ids": ["release-key-001"], "threshold": 1},
            }
        )
        with self.assertRaisesRegex(RuntimeError, "identity is invalid"):
            identity_policy.load_identity(require_ready=True)


if __name__ == "__main__":
    unittest.main()
