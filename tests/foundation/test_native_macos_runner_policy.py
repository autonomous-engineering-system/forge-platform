#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOSTED = ROOT / ".github/workflows/macos-installer-validation.yml"
NATIVE = ROOT / ".github/workflows/macos-installer-native-integration.yml"
RELEASE = ROOT / ".github/workflows/forge-platform-installer-release.yml"
BUILD_BOOTSTRAP = ROOT / "scripts/ci/bootstrap_macos_build_runner.sh"
BUILD_SERVICE = ROOT / "scripts/ci/install_macos_build_runner_launchdaemon.sh"
BUILD_REBOOT = ROOT / "scripts/ci/verify_macos_build_runner_reboot.sh"
SIGNER_REBOOT = ROOT / "scripts/ci/verify_macos_offline_signer_reboot.sh"
OLD_BOOTSTRAP = ROOT / "scripts/ci/bootstrap_macos_signing_runner.sh"
READINESS = ROOT / "scripts/ci/verify_macos_offline_signing_host.sh"
OLD_READINESS = ROOT / "scripts/ci/verify_macos_signing_runner.sh"
LOCAL_RELEASE = ROOT / "scripts/run_local_macos_installer_release.sh"
IDENTITY = ROOT / "installer-release-identity.json"
RELEASE_TRUST = ROOT / "release-trust/ForgePlatformInstallerReleaseTrust.json"
CATALOG_TRUST = ROOT / "release-trust/ForgePlatformInstallerCompositionCatalogTrust.json"
DESCRIPTOR_KEY_TOOL = ROOT / "scripts/ci/OfflineInstallerDescriptorKeyTool.swift"
CATALOG_KEY_TOOL = ROOT / "scripts/ci/OfflineCompositionCatalogKeyTool.swift"


class NativeMacRunnerPolicyTests(unittest.TestCase):
    def test_untrusted_pull_request_validation_stays_on_github_hosted_macos(self) -> None:
        text = HOSTED.read_text(encoding="utf-8")
        foundation = (ROOT / ".github/workflows/foundation-validation.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_call:", text)
        self.assertIn("pull_request:", foundation)
        self.assertIn("uses: ./.github/workflows/macos-installer-validation.yml", foundation)
        self.assertIn("runs-on: macos-26", text)
        self.assertNotIn("self-hosted", text)

    def test_macmini_workflow_is_manual_exact_main_and_build_only(self) -> None:
        text = NATIVE.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request:", text)
        self.assertIn("github.repository == 'autonomous-engineering-system/forge-platform'", text)
        self.assertIn("github.ref_protected", text)
        self.assertIn("github.workflow_sha == inputs.source_sha", text)
        self.assertIn("group: forge-platform-build", text)
        self.assertIn("labels: forge-platform-build", text)
        self.assertIn("BUILD_RUNNER_ISOLATION=PASS", text)
        self.assertIn("forge-platform-installer", text)
        self.assertNotIn("forge-platform-signer", text)
        self.assertNotIn("signing-readiness:", text)
        self.assertNotIn("FORGE_PLATFORM_CODESIGN_IDENTITY", text)

    def test_local_signer_readiness_never_exports_or_weakens_private_keys(self) -> None:
        text = READINESS.read_text(encoding="utf-8")
        self.assertIn("actions-runner-context-forbidden", text)
        self.assertIn("security find-identity -v -p codesigning", text)
        self.assertIn("Developer ID Application:", text)
        self.assertIn("codesign --verify --strict --deep", text)
        self.assertIn('"-R=$requirement"', text)
        self.assertIn("xcrun --find stapler", text)
        self.assertNotIn("stapler --help", text)
        self.assertIn("command -v codesign", text)
        self.assertNotIn("codesign --version", text)
        self.assertIn("FORGE_PLATFORM_SIGNER_ACCOUNT", text)
        self.assertIn("mode=offline-local", text)
        self.assertNotIn("RUNNER_NAME=", text)
        forbidden = (
            "security export",
            "find-generic-password -w",
            "find-internet-password -w",
            "set-key-partition-list",
            "base64.*p12",
            "--insecure-storage",
        )
        for pattern in forbidden:
            self.assertNotRegex(text, re.compile(pattern, re.IGNORECASE))

    def test_legacy_signer_runner_entrypoints_fail_closed(self) -> None:
        self.assertIn("credential-bearing-actions-runner-prohibited", OLD_BOOTSTRAP.read_text())
        self.assertIn("actions-signer-prohibited", OLD_READINESS.read_text())

    def test_build_runner_bootstrap_is_org_group_scoped_and_credentialless(self) -> None:
        text = BUILD_BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn('RUNNER_VERSION="2.335.0"', text)
        self.assertIn('RUNNER_SHA256="a1b382dda2cbb00a5e78fc21e7dbf4dbcf35edf44d6fd8686c8302e6f15cd065"', text)
        self.assertIn("https://github.com/autonomous-engineering-system", text)
        self.assertIn('RUNNER_GROUP="${FORGE_PLATFORM_RUNNER_GROUP:-forge-platform-build}"', text)
        self.assertIn("--runnergroup", text)
        self.assertIn("--no-default-labels", text)
        self.assertIn("developer-id-visible-in-build-account", text)
        self.assertIn("notary-profile-must-not-enter-build-account", text)
        self.assertNotIn("forge-platform-signer", text)
        self.assertNotIn("/releases/latest/", text)
        self.assertIn("per-user-launchagent-must-not-be-installed", text)
        self.assertNotIn("./svc.sh install", text)

    def test_build_runner_uses_a_no_login_system_launchdaemon(self) -> None:
        bootstrap = BUILD_BOOTSTRAP.read_text(encoding="utf-8")
        service = BUILD_SERVICE.read_text(encoding="utf-8")
        reboot = BUILD_REBOOT.read_text(encoding="utf-8")
        for text in (service, reboot):
            self.assertIn("org.autonomous-engineering-system.forge-platform.build-runner", text)
            self.assertIn("automatic-login-must-be-disabled", text)
            self.assertIn("build-user-must-not-be-admin", text)
            self.assertIn("developer-id-visible-in-build-account", text)
            self.assertIn('launchctl print "system/$SERVICE_LABEL"', text)
            self.assertIn("Runner.Listener", text)
        self.assertIn('PLIST_PATH="/Library/LaunchDaemons/${SERVICE_LABEL}.plist"', service)
        self.assertIn('LOG_ROOT="/var/log/$SERVICE_LABEL"', service)
        self.assertIn('SAFE_RUNNER_PATH="/opt/homebrew/bin:', service)
        self.assertIn('install -o "$BUILD_USER" -g staff -m 0600 "$path_tmp" "$RUNNER_ROOT/.path"', service)
        self.assertIn("runner-path-must-not-be-symlink", service)
        self.assertIn('launchctl bootout system "$PLIST_PATH"', service)
        self.assertIn("launchdaemon-reload-required", service)
        self.assertIn("service_start=restart-loaded", service)
        self.assertNotIn("/Users/pcvantol", service)
        self.assertNotIn('$build_home/Library/Logs', service)
        self.assertIn("<key>UserName</key><string>$BUILD_USER</string>", service)
        self.assertIn("<key>RunAtLoad</key><true/>", service)
        self.assertNotIn("LaunchAgents", reboot)
        for text in (bootstrap, service, reboot):
            self.assertIn('open(', text)
            self.assertIn('encoding="utf-8-sig"', text)

    def test_offline_signer_reboot_evidence_rechecks_every_local_credential(self) -> None:
        text = SIGNER_REBOOT.read_text(encoding="utf-8")
        for required in (
            "usage-record-or-verify",
            "source-not-exact-current-main",
            "verify_macos_offline_signing_host.sh",
            "OfflineInstallerDescriptorKeyTool.swift",
            "OfflineCompositionCatalogKeyTool.swift",
            "OFFLINE_DESCRIPTOR_KEY",
            "OFFLINE_CATALOG_KEY",
            "host-has-not-rebooted",
            "OFFLINE_SIGNER_REBOOT_READINESS=PASS",
        ):
            self.assertIn(required, text)
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", DESCRIPTOR_KEY_TOOL.read_text())
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", CATALOG_KEY_TOOL.read_text())
        self.assertNotIn("security export", text)
        self.assertNotIn("set-key-partition-list", text)

    def test_release_workflow_only_authorizes_the_local_signer(self) -> None:
        text = RELEASE.read_text(encoding="utf-8")
        self.assertIn("Authorize exact local signing handoff", text)
        self.assertIn("name: forge-platform-installer-signing", text)
        self.assertIn('"result": "AUTHORIZED_FOR_LOCAL_SIGNER"', text)
        self.assertIn('"workflow_sha": os.environ["GITHUB_WORKFLOW_SHA"]', text)
        self.assertIn("group: forge-platform-build", text)
        self.assertNotIn("forge-platform-signer", text)
        authorization = text.split("  authorize-local-signing:\n", 1)[1]
        self.assertNotIn("FORGE_PLATFORM_NOTARYTOOL_PROFILE", authorization)
        self.assertNotIn("FORGE_PLATFORM_CODESIGN_IDENTITY", authorization)
        self.assertNotIn("permissions:\n      contents: write", text)

    def test_local_release_contains_the_full_native_and_remote_readback_chain(self) -> None:
        text = LOCAL_RELEASE.read_text(encoding="utf-8")
        for command in (
            "verify_local_signing_authorization.py",
            "verify_macos_offline_signing_host.sh",
            "codesign --force --options runtime --timestamp",
            "notarytool submit",
            "stapler staple",
            "stapler validate",
            "spctl --assess",
            "qualify_local_installer_release.py",
            "verify_installer_release_evidence.py",
            "gh release create",
            "gh release upload",
            "gh release download",
            "record_local_installer_publication.py",
            "gh release edit",
        ):
            self.assertIn(command, text)
        self.assertIn("exclusive-installer-signing", text)
        self.assertIn("git rev-parse origin/main", text)
        self.assertNotIn("security export", text)
        self.assertNotIn("set-key-partition-list", text)
        self.assertIn("OfflineInstallerDescriptorKeyTool.swift", text)
        self.assertIn("descriptor-key-tool-signature-invalid", text)
        self.assertIn("--identifier \"$DESCRIPTOR_KEY_TOOL_IDENTIFIER\"", text)
        self.assertNotIn("DESCRIPTOR_SIGNING_KEY_PATHS", text)

    def test_live_ready_identity_exactly_binds_public_release_and_catalog_trust(self) -> None:
        identity = json.loads(IDENTITY.read_text(encoding="utf-8"))
        release = json.loads(RELEASE_TRUST.read_text(encoding="utf-8"))
        catalog = json.loads(CATALOG_TRUST.read_text(encoding="utf-8"))
        self.assertEqual(identity["status"], "READY")
        self.assertEqual(identity["identity"]["github_repository"], release["repository"])
        self.assertEqual(identity["identity"]["bundle_identifier"], release["expected_bundle_identifier"])
        self.assertEqual(identity["identity"]["team_identifier"], release["expected_team_identifier"])
        self.assertEqual(
            identity["identity"]["release_trust_configuration_sha256"],
            release["configuration_sha256"],
        )
        self.assertEqual(
            catalog["installer_release_trust_configuration_sha256"],
            release["configuration_sha256"],
        )
        self.assertEqual(
            identity["signing_key_policy"]["key_ids"],
            [key["key_id"] for key in release["ed25519_public_keys"]],
        )

    def test_descriptor_and_catalog_keys_are_separate_local_non_sync_keychain_items(self) -> None:
        descriptor = DESCRIPTOR_KEY_TOOL.read_text(encoding="utf-8")
        catalog = CATALOG_KEY_TOOL.read_text(encoding="utf-8")
        self.assertIn("installer-descriptor-signing-v1", descriptor)
        self.assertIn("composition-catalog-signing-v1", catalog)
        self.assertIn("kSecAttrSynchronizable", descriptor)
        self.assertIn("kSecAttrSynchronizable", catalog)
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", descriptor)
        self.assertIn("kSecAttrAccessibleWhenUnlockedThisDeviceOnly", catalog)
        self.assertNotEqual(
            re.search(r'let service = "([^"]+)"', descriptor).group(1),
            re.search(r'let service = "([^"]+)"', catalog).group(1),
        )
        for text in (descriptor, catalog):
            self.assertNotIn("security export", text)
            self.assertNotIn("set-key-partition-list", text)


if __name__ == "__main__":
    unittest.main()
