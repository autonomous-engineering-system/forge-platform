#!/usr/bin/env python3
"""Static safety checks for the installer release workflow and local signer handoff."""
from __future__ import annotations

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/forge-platform-installer-release.yml"
LOCAL_RELEASE = ROOT / "scripts/run_local_macos_installer_release.sh"


class InstallerReleaseWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.local_release = LOCAL_RELEASE.read_text(encoding="utf-8")

    def test_exact_protected_main_and_credentialless_org_runner_group(self) -> None:
        for guard in (
            "github.repository == 'autonomous-engineering-system/forge-platform'",
            "github.ref == 'refs/heads/main'",
            "github.ref_protected",
            "github.sha == inputs.source_sha",
            "github.workflow_sha == inputs.source_sha",
        ):
            self.assertIn(guard, self.workflow)
        self.assertIn("group: forge-platform-build", self.workflow)
        self.assertIn("labels: forge-platform-build", self.workflow)
        self.assertIn("BUILD_RUNNER_ISOLATION=FAIL", self.workflow)
        self.assertIn("persist-credentials: false", self.workflow)
        self.assertNotIn("forge-platform-signer", self.workflow)

    def test_native_tests_coverage_gui_cli_and_unsigned_candidate_are_mandatory(self) -> None:
        self.assertIn("coverage_base_sha:", self.workflow)
        self.assertIn("swift test --enable-code-coverage", self.workflow)
        self.assertIn("export_managed_installer_swift_coverage.sh", self.workflow)
        self.assertIn("$RUNNER_TEMP/forge-platform-installer-release-swift-coverage.json", self.workflow)
        self.assertNotIn("swift test --show-codecov-path", self.workflow)
        self.assertIn("check_managed_installer_swift_coverage.py", self.workflow)
        self.assertIn("--product ForgePlatformInstaller", self.workflow)
        self.assertIn("--product forge-platform-installer", self.workflow)
        self.assertIn("scripts/prepare_offline_installer_resources.py", self.workflow)
        self.assertIn("--sealed-release-trust-resource", self.workflow)
        self.assertIn("--sealed-release-provenance-resource", self.workflow)
        self.assertIn("--sealed-composition-catalog-trust-resource", self.workflow)
        self.assertIn("scripts/package_macos_installer_archive.py", self.workflow)
        self.assertIn('"packaging": "UNSIGNED_APP_CANDIDATE"', self.workflow)
        self.assertIn("scripts/prepare_installer_release_candidate.py", self.workflow)
        self.assertIn("installer-release-preparation.json", self.workflow)

    def test_protected_environment_emits_only_exact_non_secret_authorization(self) -> None:
        authorization = self.workflow.split("  authorize-local-signing:\n", 1)[1]
        self.assertIn("environment:\n      name: forge-platform-installer-signing", authorization)
        self.assertIn('"result": "AUTHORIZED_FOR_LOCAL_SIGNER"', authorization)
        self.assertIn('"workflow_sha": os.environ["GITHUB_WORKFLOW_SHA"]', authorization)
        self.assertIn('"archive_digest": os.environ["ARCHIVE_DIGEST"]', authorization)
        self.assertIn("contents: read", authorization)
        self.assertNotIn("secrets.", authorization)
        self.assertNotIn("notarytool", authorization)
        self.assertNotIn("codesign", authorization)
        self.assertNotIn("contents: write", authorization)

    def test_local_signer_owns_full_apple_and_github_release_chain(self) -> None:
        build_index = self.local_release.index("verify_local_signing_authorization.py")
        sign_index = self.local_release.index("codesign --force")
        notary_index = self.local_release.index("notarytool submit")
        staple_index = self.local_release.index("stapler staple")
        gatekeeper_index = self.local_release.index("spctl --assess")
        qualify_index = self.local_release.index("qualify_local_installer_release.py")
        draft_index = self.local_release.index("gh release create")
        readback_index = self.local_release.index("gh release download")
        publish_index = self.local_release.index("gh release edit")
        self.assertLess(build_index, sign_index)
        self.assertLess(sign_index, notary_index)
        self.assertLess(notary_index, staple_index)
        self.assertLess(staple_index, gatekeeper_index)
        self.assertLess(gatekeeper_index, qualify_index)
        self.assertLess(qualify_index, draft_index)
        self.assertLess(draft_index, readback_index)
        self.assertLess(readback_index, publish_index)
        self.assertIn("cmp ", self.local_release)
        self.assertIn("git rev-parse origin/main", self.local_release)
        self.assertIn("exclusive-offline-signing", self.local_release)
        self.assertIn("OfflineInstallerDescriptorKeyTool.swift", self.local_release)
        self.assertNotIn("DESCRIPTOR_SIGNING_KEY_PATHS", self.local_release)


if __name__ == "__main__":
    unittest.main()
