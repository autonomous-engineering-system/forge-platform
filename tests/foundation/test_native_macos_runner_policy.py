#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

HOSTED = ROOT / ".github" / "workflows" / "macos-installer-validation.yml"
NATIVE = ROOT / ".github" / "workflows" / "macos-installer-native-integration.yml"
RELEASE = ROOT / ".github" / "workflows" / "forge-platform-installer-release.yml"
BOOTSTRAP = ROOT / "scripts" / "ci" / "bootstrap_macos_signing_runner.sh"
READINESS = ROOT / "scripts" / "ci" / "verify_macos_offline_signing_host.sh"
ACTIONS_SIGNER_GUARD = ROOT / "scripts" / "ci" / "verify_macos_signing_runner.sh"
OFFLINE_RELEASE = ROOT / "scripts" / "ci" / "offline_macos_installer_sign_and_notarize.sh"
DESCRIPTOR_KEY_TOOL = ROOT / "scripts" / "ci" / "OfflineInstallerDescriptorKeyTool.swift"


class NativeMacRunnerPolicyTests(unittest.TestCase):
    def test_untrusted_pull_request_validation_stays_on_github_hosted_macos(self) -> None:
        text = HOSTED.read_text(encoding="utf-8")
        self.assertIn("workflow_call:", text)
        foundation = ROOT / ".github" / "workflows" / "foundation-validation.yml"
        foundation_text = foundation.read_text(encoding="utf-8")
        self.assertIn("pull_request:", foundation_text)
        self.assertIn("uses: ./.github/workflows/macos-installer-validation.yml", foundation_text)
        self.assertIn("runs-on: macos-26", text)
        self.assertNotIn("self-hosted", text)
        self.assertNotIn("forge-platform-signer", text)
        self.assertNotIn("forge-platform-mini", text)

    def test_macmini_integration_is_manual_only_and_requires_exact_main(self) -> None:
        text = NATIVE.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request:", text)
        self.assertIn("runs-on: [self-hosted, macOS, ARM64, forge-platform-integration]", text)
        self.assertNotIn("forge-platform-signer", text)
        self.assertIn("forge-platform-installer-integration", text)
        self.assertIn("INTEGRATION_KEYCHAIN_ISOLATION=PASS", text)
        self.assertIn('test "$SOURCE_SHA" = "$(git rev-parse origin/main)"', text)
        self.assertIn("environment:", text)
        self.assertNotIn("forge-platform-installer-signing", text)

    def test_signer_readiness_never_exports_or_dumps_private_key_material(self) -> None:
        text = READINESS.read_text(encoding="utf-8")
        self.assertIn("security find-identity -v -p codesigning", text)
        self.assertIn("Developer ID Application:", text)
        self.assertIn("codesign --verify --strict --deep", text)
        self.assertIn("FORGE_PLATFORM_SIGNER_ACCOUNT", text)
        self.assertIn("github-actions-signing-forbidden", text)
        forbidden = (
            "security export",
            "find-generic-password -w",
            "find-internet-password -w",
            "base64.*p12",
            "--insecure-storage",
        )
        for pattern in forbidden:
            self.assertNotRegex(text, re.compile(pattern, re.IGNORECASE))

    def test_actions_signer_guard_is_terminal_and_contains_no_apple_probe(self) -> None:
        text = ACTIONS_SIGNER_GUARD.read_text(encoding="utf-8")
        self.assertIn("github-actions-signer-disabled-public-repository", text)
        self.assertIn("exit 1", text)
        self.assertNotIn("security find-identity", text)
        self.assertNotIn("notarytool", text)
        self.assertNotIn("codesign --sign", text)

    def test_descriptor_private_key_stays_in_local_data_protection_keychain(self) -> None:
        text = DESCRIPTOR_KEY_TOOL.read_text(encoding="utf-8")
        self.assertIn('environment["GITHUB_ACTIONS"] != "true"', text)
        self.assertIn('environment["RUNNER_NAME"] ?? "").isEmpty', text)
        self.assertIn("kSecUseDataProtectionKeychain", text)
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", text)
        self.assertIn("Curve25519.Signing.PrivateKey", text)
        self.assertIn("SecItemAdd", text)
        self.assertIn("SecItemCopyMatching", text)
        self.assertIn('"signature": signatureBase64URL(signature)', text)
        self.assertNotIn("security export", text)
        self.assertNotIn("find-generic-password", text)

    def test_offline_release_signs_notarizes_staples_and_revalidates_final_carrier(self) -> None:
        text = OFFLINE_RELEASE.read_text(encoding="utf-8")
        self.assertIn('[[ "${GITHUB_ACTIONS:-}" != "true" ]]', text)
        self.assertIn('[[ -z "${RUNNER_NAME:-}" ]]', text)
        self.assertIn("verify_macos_offline_signing_host.sh", text)
        self.assertIn('git rev-parse origin/main', text)
        self.assertIn("--require-version-advance", text)
        self.assertIn("--sealed-release-trust-resource", text)
        self.assertIn("--sealed-release-provenance-resource", text)
        self.assertIn("--sealed-composition-catalog-trust-resource", text)
        self.assertIn("codesign --force --options runtime --timestamp", text)
        self.assertIn("notarytool submit", text)
        self.assertIn("--wait --output-format json", text)
        self.assertGreaterEqual(text.count("stapler validate -v"), 2)
        self.assertGreaterEqual(text.count("spctl --assess --type execute"), 2)
        self.assertIn("package_macos_installer_archive.py", text)
        self.assertIn("final-archive-lost-stapled-ticket", text)
        self.assertIn('"publication":"NOT_PERFORMED"', text)
        self.assertNotIn("gh release create", text)
        self.assertNotIn("security export", text)

    def test_runner_bootstrap_pins_official_arm64_version_and_digest(self) -> None:
        text = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn('RUNNER_VERSION="2.335.0"', text)
        self.assertIn(
            'RUNNER_SHA256="a1b382dda2cbb00a5e78fc21e7dbf4dbcf35edf44d6fd8686c8302e6f15cd065"',
            text,
        )
        self.assertIn("actions-runner-osx-arm64-", text)
        self.assertIn('shasum -a 256 "$tmp/$RUNNER_ARCHIVE"', text)
        self.assertIn('FORGE_PLATFORM_RUNNER_ROLE', text)
        self.assertIn('RUNNER_LABELS="forge-platform-integration"', text)
        self.assertIn("credential-bearing-actions-signer-disabled-public-repository", text)
        self.assertNotIn('RUNNER_LABELS="forge-platform-signer"', text)
        self.assertIn('integration-and-signer-user-must-differ', text)
        self.assertNotIn("/releases/latest/", text)

    def test_release_workflow_never_allocates_a_credential_bearing_actions_signer(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertNotIn("forge-platform-signer", text)
        self.assertNotIn("verify_macos_signing_runner.sh", text)
        self.assertNotIn("FORGE_PLATFORM_CODESIGN_IDENTITY", text)
        self.assertNotIn("FORGE_PLATFORM_NOTARYTOOL_PROFILE", text)
        self.assertIn("offline-signing-handoff:", text)
        self.assertIn("offline-macmini-signing-required", text)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("exit 1", text)


if __name__ == "__main__":
    unittest.main()
