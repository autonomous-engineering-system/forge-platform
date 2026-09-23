#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MacMiniCIContractTests(unittest.TestCase):
    def test_self_hosted_macmini_workflow_never_runs_on_pull_request(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "macmini-installer-integration.yml"
        ).read_text(encoding="utf-8")
        self.assertNotRegex(workflow, r"(?m)^\s*pull_request(?:_target)?:")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("branches: [main]", workflow)
        self.assertIn(
            "runs-on: [self-hosted, macOS, ARM64, forge-platform-macmini]",
            workflow,
        )
        self.assertIn("Refuse untrusted event classes", workflow)
        self.assertIn("scripts/macos/macmini_runner_readiness.sh", workflow)

    def test_release_signer_is_pinned_to_dedicated_macmini_runner(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "forge-platform-installer-release.yml"
        ).read_text(encoding="utf-8")
        signer = workflow.split("  sign-notarize-and-qualify:", 1)[1].split(
            "\n  verify-signed-evidence-and-publish:", 1
        )[0]
        self.assertIn(
            "runs-on: [self-hosted, macOS, ARM64, forge-platform-macmini]",
            signer,
        )
        self.assertIn("forge-platform-installer-signing", signer)
        self.assertIn("macmini_runner_readiness.sh", signer)

    def test_runner_bootstrap_uses_short_lived_registration_token_and_refuses_root(self) -> None:
        script = (
            ROOT / "scripts" / "macos" / "configure_forge_platform_actions_runner.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('"$(id -u)" -ne 0', script)
        self.assertIn("actions/runners/registration-token", script)
        self.assertIn("--labels", script)
        self.assertIn("forge-platform-macmini", script)
        self.assertIn("asset_digest", script)
        self.assertIn("shasum -a 256", script)
        self.assertIn("registration_token=\"\"", script)
        self.assertNotIn("echo $registration_token", script)
        self.assertNotIn("printf '%s' \"$registration_token\"", script)

    def test_readiness_probe_reports_identity_without_private_key_material(self) -> None:
        script = (
            ROOT / "scripts" / "macos" / "macmini_runner_readiness.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("security find-identity -v -p codesigning", script)
        self.assertIn("Developer ID Application:", script)
        self.assertIn("team_id", script)
        self.assertIn("xcrun notarytool help", script)
        forbidden = (
            "security export",
            "find-generic-password -w",
            "app-specific-password",
            "PRIVATE KEY",
        )
        for fragment in forbidden:
            self.assertNotIn(fragment, script)


if __name__ == "__main__":
    unittest.main()
