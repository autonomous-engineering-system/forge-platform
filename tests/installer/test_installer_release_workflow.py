#!/usr/bin/env python3
"""Static safety checks for the installer-specific release workflow framework."""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "forge-platform-installer-release.yml"
NATIVE_VALIDATION_WORKFLOW_PATH = ROOT / ".github" / "workflows" / "macos-installer-validation.yml"


class InstallerReleaseWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
        self.native_validation_workflow = NATIVE_VALIDATION_WORKFLOW_PATH.read_text(encoding="utf-8")

    def test_native_validation_uses_an_arm64_macos_26_hosted_image(self) -> None:
        self.assertIn("runs-on: macos-26", self.native_validation_workflow)
        self.assertIn('test "$(uname -m)" = "arm64"', self.native_validation_workflow)
        self.assertIn('sw_vers -productVersion', self.native_validation_workflow)
        self.assertIn("working-directory: macos/ForgePlatformInstaller", self.native_validation_workflow)
        self.assertIn("run: swift test", self.native_validation_workflow)

    def test_uses_a_separate_installer_tag_and_never_reuses_composition_flow_identity(self) -> None:
        self.assertIn("name: Forge Platform installer release framework", self.workflow)
        self.assertIn("group: forge-platform-installer-release", self.workflow)
        self.assertIn('TAG="$TAG_PREFIX$INSTALLER_VERSION"', self.workflow)
        self.assertIn('OPERATION_ID="forge-platform-installer-$INSTALLER_VERSION-$SOURCE_SHA"', self.workflow)
        self.assertNotIn("forge-platform-production-release", self.workflow)
        self.assertNotIn("forge_platform.release_operation", self.workflow)
        self.assertNotIn("composition_manifest", self.workflow)
        self.assertNotIn("com.pcvantol.forge-platform-installer", self.workflow)

    def test_qualifies_only_the_exact_current_main_candidate_and_builds_an_app_archive(self) -> None:
        self.assertIn('test "$SOURCE_SHA" = "$(git rev-parse HEAD)"', self.workflow)
        self.assertIn('test "$SOURCE_SHA" = "$(git rev-parse origin/main)"', self.workflow)
        self.assertIn("scripts/advance_installer_version.py", self.workflow)
        self.assertIn(
            "--verify-operation --require-operation --require-version-advance --candidate-head \"$SOURCE_SHA\"",
            self.workflow,
        )
        self.assertIn("scripts/validate_installer_release_identity.py --require-ready", self.workflow)
        self.assertIn("release_sequence:", self.workflow)
        self.assertIn("provenance_sha256:", self.workflow)
        self.assertIn("release_sequence must be a positive UInt64 decimal integer", self.workflow)
        self.assertIn("provenance_sha256 must be a raw lowercase SHA-256 identity", self.workflow)
        self.assertIn("INSTALLER_RELEASE_POLICY_REVISION", self.workflow)
        self.assertIn("git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main", self.workflow)
        self.assertIn('test "$GITHUB_REPOSITORY" = "$IDENTITY_REPOSITORY"', self.workflow)
        self.assertIn("runs-on: macos-26", self.workflow)
        self.assertIn('test "$(uname -m)" = "arm64"', self.workflow)
        self.assertIn('ARCHITECTURE="arm64"', self.workflow)
        self.assertNotIn("arm64|x86_64", self.workflow)
        self.assertIn("swift test", self.workflow)
        self.assertIn("swift build -c release --show-bin-path", self.workflow)
        self.assertIn("scripts/package_macos_installer_app.py", self.workflow)
        self.assertIn('--bundle-identifier "$BUNDLE_IDENTIFIER"', self.workflow)
        self.assertIn("release-input/ForgePlatformInstaller.app", self.workflow)
        self.assertIn('ARCHIVE="$ASSET_PREFIX$ARCHITECTURE.zip"', self.workflow)
        self.assertIn("scripts/package_macos_installer_archive.py", self.workflow)
        self.assertIn("--app-bundle release-input/ForgePlatformInstaller.app", self.workflow)
        self.assertIn('--output "release-input/$ARCHIVE"', self.workflow)
        self.assertNotIn("ditto -c -k --sequesterRsrc --keepParent", self.workflow)
        self.assertIn("shasum -a 256", self.workflow)
        self.assertIn('"packaging": "UNSIGNED_APP_CANDIDATE"', self.workflow)
        self.assertIn('"release_trust_configuration_sha256": os.environ["RELEASE_TRUST_CONFIGURATION_SHA256"]', self.workflow)
        self.assertIn('"provenance_sha256": os.environ["PROVENANCE_SHA256"]', self.workflow)
        self.assertIn("scripts/prepare_installer_release_candidate.py", self.workflow)
        self.assertIn("installer-release-preparation.json", self.workflow)
        self.assertIn('--preparation-receipt-reference "receipt:installer-preparation-$OPERATION_ID"', self.workflow)

    def test_public_actions_release_has_only_an_offline_signing_handoff(self) -> None:
        self.assertIn("offline-signing-handoff:", self.workflow)
        self.assertIn("name: Require offline Mac mini signer", self.workflow)
        self.assertIn("if: ${{ inputs.request_publication }}", self.workflow)
        self.assertIn("offline-macmini-signing-required", self.workflow)
        self.assertIn("credential-bearing signing inside GitHub Actions", self.workflow)
        self.assertNotIn("forge-platform-installer-signing", self.workflow)
        self.assertNotIn("forge-platform-installer-publication", self.workflow)
        self.assertNotIn("forge-platform-signer", self.workflow)
        self.assertNotIn("FORGE_PLATFORM_CODESIGN_IDENTITY", self.workflow)
        self.assertNotIn("FORGE_PLATFORM_NOTARYTOOL_PROFILE", self.workflow)
        self.assertNotIn("permissions:\n      contents: write", self.workflow)
        self.assertNotIn("secrets.", self.workflow)
        self.assertNotIn("gh release", self.workflow)

    def test_unsigned_candidate_remains_reproducible_but_not_publication_authority(self) -> None:
        candidate_index = self.workflow.index("build-unsigned-app-candidate:")
        handoff_index = self.workflow.index("offline-signing-handoff:")
        self.assertLess(candidate_index, handoff_index)
        self.assertIn("scripts/prepare_installer_release_candidate.py", self.workflow)
        self.assertIn("installer-release-preparation.json", self.workflow)
        self.assertIn('"packaging": "UNSIGNED_APP_CANDIDATE"', self.workflow)
        self.assertIn("actions/upload-artifact@", self.workflow)
        self.assertNotIn("scripts/verify_installer_release_evidence.py", self.workflow)
        self.assertNotIn("signed-release-input", self.workflow)
        self.assertNotIn("github-release", self.workflow.lower().split("offline-signing-handoff:", 1)[1])
        self.assertIn("exit 1", self.workflow.split("offline-signing-handoff:", 1)[1])


if __name__ == "__main__":
    unittest.main()
