#!/usr/bin/env python3
"""Static safety checks for the installer release workflow and local signer handoff."""
from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/forge-platform-installer-release.yml"
LOCAL_RELEASE = ROOT / "scripts/run_local_macos_installer_release.sh"
OFFLINE_RELEASE = ROOT / "scripts/ci/offline_macos_installer_sign_and_notarize.sh"


class InstallerReleaseWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.local_release = LOCAL_RELEASE.read_text(encoding="utf-8")
        self.offline_release = OFFLINE_RELEASE.read_text(encoding="utf-8")

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
        self.assertIn("--product forge-platform-installer-helper", self.workflow)
        self.assertIn("--helper-executable", self.workflow)
        self.assertIn("scripts/build_installer_product_worker.py", self.workflow)
        self.assertIn("--product-worker release-input/forge-platform-product-worker.pyz", self.workflow)
        self.assertLess(
            self.workflow.index("scripts/build_installer_product_worker.py"),
            self.workflow.index("--product-worker release-input/forge-platform-product-worker.pyz"),
        )
        self.assertIn("Contents/Resources/forge-platform-product-worker.pyz", self.workflow)
        self.assertIn("Contents/Library/LaunchDaemons/com.autonomous-engineering-system.forge-platform-installer.helper.plist", self.workflow)
        self.assertIn("scripts/prepare_offline_installer_resources.py", self.workflow)
        self.assertIn("--sealed-release-trust-resource", self.workflow)
        self.assertIn("--sealed-release-provenance-resource", self.workflow)
        self.assertIn("--sealed-composition-catalog-trust-resource", self.workflow)
        self.assertIn("scripts/package_macos_installer_archive.py", self.workflow)
        self.assertIn('"packaging": "UNSIGNED_APP_CANDIDATE"', self.workflow)
        self.assertIn("scripts/prepare_installer_release_candidate.py", self.workflow)
        self.assertIn("installer-release-preparation.json", self.workflow)

    def test_corrected_forge_controller_and_release_receipt_are_sealed_before_archiving(self) -> None:
        controller = "e4b99a249845a547fd6b8e7e11d22467b2d0886d"
        release_source = "0a3d6e35b01da93bb5a674ae7795558655c16c7d"
        self.assertIn(
            f"raw.githubusercontent.com/pcvantol/forge/{controller}/scripts/update_installed_forge.py",
            self.workflow,
        )
        self.assertIn(
            f"forge-release-complete-2.7.38-{release_source}.json",
            self.workflow,
        )
        self.assertIn("--forge-update-controller release-input/forge-update-controller.py", self.workflow)
        self.assertIn(
            "--forge-release-complete-receipt release-input/forge-release-complete-2.7.38.json",
            self.workflow,
        )
        self.assertIn("read_forge_update_resources(worker)", self.workflow)
        self.assertLess(
            self.workflow.index("read_forge_update_resources(worker)"),
            self.workflow.index("scripts/package_macos_installer_archive.py"),
        )

    def test_239_published_resources_are_required_on_every_release_path(self) -> None:
        source = "ebc43dc12da27353f85c991a26da9852aa790f05"
        self.assertIn(
            f"raw.githubusercontent.com/pcvantol/forge/{source}/scripts/update_installed_forge.py",
            self.workflow,
        )
        self.assertIn(f"forge-release-complete-2.7.39-{source}.json", self.workflow)
        self.assertIn("--forge-239-update-controller release-input/forge-update-controller-2.7.39.py", self.workflow)
        self.assertIn("--forge-239-release-complete-receipt release-input/forge-release-complete-2.7.39.json", self.workflow)
        for script in (self.workflow, self.offline_release, self.local_release):
            self.assertIn("read_forge_239_update_resources(worker)", script)
        self.assertLess(
            self.workflow.index("read_forge_239_update_resources(worker)"),
            self.workflow.index("scripts/package_macos_installer_archive.py"),
        )
        self.assertLess(
            self.offline_release.index("read_forge_239_update_resources(worker)"),
            self.offline_release.index("codesign --force"),
        )
        self.assertLess(
            self.local_release.index("read_forge_239_update_resources(worker)"),
            self.local_release.index("codesign --force"),
        )
        for name in ("FORGE_PLATFORM_FORGE_239_UPDATE_CONTROLLER", "FORGE_PLATFORM_FORGE_239_RELEASE_COMPLETE_RECEIPT"):
            self.assertIn(name, self.offline_release)

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
        self.assertIn("unsigned-helper-missing", self.local_release)
        self.assertIn("unsigned-product-worker-missing", self.local_release)
        self.assertIn(
            '--identifier "com.autonomous-engineering-system.forge-platform-installer.helper"',
            self.local_release,
        )
        self.assertIn("signed-helper-identity-invalid", self.local_release)
        self.assertIn("final-archive-helper-identity-invalid", self.local_release)
        self.assertNotIn("DESCRIPTOR_SIGNING_KEY_PATHS", self.local_release)
        self.assertLess(
            self.local_release.index("read_forge_update_resources(worker)"),
            self.local_release.index("codesign --force"),
        )

    def test_signed_resources_remain_readable_after_root_owned_install(self) -> None:
        signer = self.local_release
        self.assertIn('"$APP/Contents/_CodeSignature/CodeResources" "$APP/Contents/CodeResources"', signer)
        self.assertIn('"$CARRIER_APP/Contents/_CodeSignature/CodeResources" "$CARRIER_APP/Contents/CodeResources"', signer)
        self.assertIn('! -e "$code_resource" && ! -L "$code_resource"', signer)
        self.assertIn('test -f "$code_resource" && test ! -L "$code_resource"', signer)
        self.assertIn('chmod 644 "$code_resource"', signer)
        self.assertIn('signed-code-resource-mode-invalid', signer)
        self.assertIn('final-archive-code-resource-mode-invalid', signer)
        self.assertLess(signer.index('chmod 644 "$code_resource"'), signer.index('codesign --verify --strict --deep "$APP"'))
        self.assertLess(signer.index('final-archive-code-resource-mode-invalid'), signer.index('xcrun stapler validate -v "$CARRIER_APP"'))

    def test_local_signer_resolves_symlinked_macos_temp_directory(self) -> None:
        work_assignment = next(
            line for line in self.local_release.splitlines() if line.startswith('WORK=')
        )
        with tempfile.TemporaryDirectory() as temporary:
            real = Path(temporary) / 'real'
            real.mkdir()
            alias = Path(temporary) / 'alias'
            alias.symlink_to(real, target_is_directory=True)
            result = subprocess.run(
                ['bash', '-c', work_assignment + '\nprintf "%s" "$WORK"'],
                env={**os.environ, 'TMPDIR': str(alias)},
                capture_output=True, text=True, check=True,
            )
            work = Path(result.stdout)
            self.assertEqual(work.parent, real.resolve())
            self.assertTrue(work.is_dir())
            work.rmdir()

    def test_offline_signer_packages_worker_before_apple_signing(self) -> None:
        builder = self.offline_release.index("scripts/build_installer_product_worker.py")
        packager = self.offline_release.index("--product-worker \"$product_worker\"")
        signing = self.offline_release.index("codesign --force")
        self.assertLess(builder, packager)
        self.assertLess(packager, signing)
        self.assertIn("product-worker-not-packaged", self.offline_release)
        self.assertIn("FORGE_PLATFORM_FORGE_UPDATE_CONTROLLER", self.offline_release)
        self.assertIn("FORGE_PLATFORM_FORGE_RELEASE_COMPLETE_RECEIPT", self.offline_release)
        self.assertLess(
            self.offline_release.index("read_forge_update_resources(worker)"),
            signing,
        )


if __name__ == "__main__":
    unittest.main()
