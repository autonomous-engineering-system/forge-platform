#!/usr/bin/env python3
"""Behavioural checks for the deterministic unsigned macOS app bundler."""

from __future__ import annotations

import base64
import hashlib
import json
import plistlib
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package_macos_installer_app.py"
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
from forge_platform.composition_catalog_trust import (  # noqa: E402
    canonical_composition_catalog_trust_configuration_sha256,
)
from forge_platform.macos_platform_contract import thin_arm64_macho_test_bytes  # noqa: E402
from package_macos_installer_app import (  # noqa: E402
    SealedCompositionCatalogTrustResource,
    SealedReleaseProvenanceResource,
    SealedReleaseTrustResource,
    package,
)
_PUBLIC_V2_DIGEST = "5988f1dd473caef0a2963f3a6cec06099007e740eced84e3a03fc0e04f343b19"
_PUBLIC_PROVENANCE_DIGEST = "d36b26ac88066121531841dab8bf0c2b8f0ab005d099e6c74b836540d555d935"

_INSTALLER_MANIFEST = json.loads((ROOT / "installer-version.json").read_text(encoding="utf-8"))
_INSTALLER_VERSION = _INSTALLER_MANIFEST["version"]
_INSTALLER_CAPABILITIES = _INSTALLER_MANIFEST["capabilities"]


class PackageMacOSInstallerAppTests(unittest.TestCase):
    def test_builds_a_minimal_unsigned_app_bundle_with_version_projection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            cli_executable = self._cli_executable(workspace)
            app_bundle = workspace / "ForgePlatformInstaller.app"

            result = self._run(executable, app_bundle)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("INSTALLER_APP_BUNDLE=PASS", result.stdout)
            self.assertIn("sealed_release_trust=ABSENT_FAIL_CLOSED", result.stdout)
            self.assertIn("sealed_release_provenance=ABSENT_FAIL_CLOSED", result.stdout)
            self.assertIn("sealed_composition_catalog_trust=ABSENT_FAIL_CLOSED", result.stdout)
            self.assertEqual(
                (app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller").read_bytes(),
                executable.read_bytes(),
            )
            self.assertTrue(
                (app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller").stat().st_mode
                & stat.S_IXUSR
            )
            self.assertEqual(
                (app_bundle / "Contents" / "MacOS" / "forge-platform-installer").read_bytes(),
                cli_executable.read_bytes(),
            )
            self.assertTrue(
                (app_bundle / "Contents" / "MacOS" / "forge-platform-installer").stat().st_mode
                & stat.S_IXUSR
            )
            with (app_bundle / "Contents" / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleExecutable"], "ForgePlatformInstaller")
            self.assertEqual(info["CFBundleIdentifier"], "com.example.forge-platform-installer")
            self.assertEqual(info["CFBundleShortVersionString"], _INSTALLER_VERSION)
            self.assertEqual(info["CFBundleVersion"], _INSTALLER_VERSION)
            self.assertEqual(info["CFBundlePackageType"], "APPL")
            self.assertEqual(info["LSMinimumSystemVersion"], "26.0")
            self.assertFalse(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseTrust.json").exists()
            )
            self.assertFalse(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseProvenance.json").exists()
            )
            self.assertFalse(
                (
                    app_bundle
                    / "Contents"
                    / "Resources"
                    / "ForgePlatformInstallerCompositionCatalogTrust.json"
                ).exists()
            )

    def test_copies_an_explicit_validated_v2_resource_verbatim_from_paths_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, trust_bytes = self._release_trust_resource(workspace)
            provenance_resource, _ = self._release_provenance_resource(
                workspace,
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            app_bundle = workspace / "Forge Platform Installer.app"

            result = self._run(
                executable,
                app_bundle,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sealed_release_trust=PACKAGED_V2", result.stdout)
            self.assertEqual(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseTrust.json").read_bytes(),
                trust_bytes,
            )

    def test_copies_an_explicit_validated_v1_provenance_verbatim_from_paths_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, _ = self._release_trust_resource(workspace)
            provenance_resource, provenance_bytes = self._release_provenance_resource(
                workspace,
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            app_bundle = workspace / "Forge Platform Installer.app"

            result = self._run(
                executable,
                app_bundle,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sealed_release_provenance=PACKAGED_V1", result.stdout)
            self.assertEqual(
                (app_bundle / "Contents" / "Resources" / "ForgePlatformInstallerReleaseProvenance.json").read_bytes(),
                provenance_bytes,
            )

    def test_copies_an_explicit_catalog_trust_policy_verbatim_only_with_its_matched_release_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, _ = self._release_trust_resource(workspace)
            provenance_resource, _ = self._release_provenance_resource(
                workspace,
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            catalog_trust_resource, catalog_trust_bytes = self._catalog_trust_resource(workspace)
            app_bundle = workspace / "Forge Platform Installer.app"

            result = self._run(
                executable,
                app_bundle,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
                catalog_trust_resource=catalog_trust_resource,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("sealed_composition_catalog_trust=PACKAGED_V1", result.stdout)
            self.assertEqual(
                (
                    app_bundle
                    / "Contents"
                    / "Resources"
                    / "ForgePlatformInstallerCompositionCatalogTrust.json"
                ).read_bytes(),
                catalog_trust_bytes,
            )

    def test_rejects_catalog_trust_without_matched_release_resources_or_a_matching_v2_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, _ = self._release_trust_resource(workspace)
            provenance_resource, _ = self._release_provenance_resource(
                workspace,
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            catalog_trust_resource, _ = self._catalog_trust_resource(workspace)

            catalog_only_output = workspace / "catalog-only.app"
            result = self._run(
                executable,
                catalog_only_output,
                catalog_trust_resource=catalog_trust_resource,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("catalog trust resource requires both sealed release trust and provenance", result.stderr)
            self.assertFalse(catalog_only_output.exists())

            mismatched_catalog_resource, _ = self._catalog_trust_resource(
                workspace,
                installer_release_trust_configuration_sha256="f" * 64,
            )
            mismatched_output = workspace / "mismatched-catalog.app"
            result = self._run(
                executable,
                mismatched_output,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
                catalog_trust_resource=mismatched_catalog_resource,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("catalog trust resource release trust configuration digest does not match", result.stderr)
            self.assertFalse(mismatched_output.exists())

            malformed_catalog_resource = workspace / "malformed catalog policy.json"
            malformed_payload = self._catalog_trust_payload()
            malformed_payload["catalog_url"] = "https://never-accepted.example.invalid/catalog.json"
            self._write_payload(malformed_catalog_resource, malformed_payload)
            malformed_output = workspace / "malformed-catalog.app"
            result = self._run(
                executable,
                malformed_output,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
                catalog_trust_resource=malformed_catalog_resource,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported or missing fields", result.stderr)
            self.assertFalse(malformed_output.exists())

            symlinked_catalog_resource = workspace / "symlinked catalog policy.json"
            symlinked_catalog_resource.symlink_to(catalog_trust_resource)
            symlinked_output = workspace / "symlinked-catalog.app"
            result = self._run(
                executable,
                symlinked_output,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
                catalog_trust_resource=symlinked_catalog_resource,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not be selected through a symlink", result.stderr)
            self.assertFalse(symlinked_output.exists())

    def test_v2_canonical_digest_matches_the_public_cross_language_vector(self) -> None:
        self.assertEqual(
            self._release_trust_digest(self._public_keys(), signature_threshold=2),
            _PUBLIC_V2_DIGEST,
        )

    def test_v1_provenance_canonical_digest_matches_the_public_vector(self) -> None:
        self.assertEqual(
            self._release_provenance_digest(self._release_provenance_payload()),
            _PUBLIC_PROVENANCE_DIGEST,
        )

    def test_rejects_missing_malformed_duplicate_or_nonfinite_resources_before_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)

            missing_output = workspace / "missing.app"
            missing = self._run(
                executable,
                missing_output,
                trust_resource=workspace / "does-not-exist.json",
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("does not exist", missing.stderr)
            self.assertFalse(missing_output.exists())

            malformed_resource = workspace / "malformed.json"
            malformed_resource.write_bytes(b'{"schema_version": 2')
            malformed_output = workspace / "malformed.app"
            malformed = self._run(executable, malformed_output, trust_resource=malformed_resource)
            self.assertNotEqual(malformed.returncode, 0)
            self.assertIn("strict UTF-8 JSON", malformed.stderr)
            self.assertFalse(malformed_output.exists())

            invalid_utf8_resource = workspace / "invalid-utf8.json"
            invalid_utf8_resource.write_bytes(b"\xff")
            invalid_utf8_output = workspace / "invalid-utf8.app"
            invalid_utf8 = self._run(executable, invalid_utf8_output, trust_resource=invalid_utf8_resource)
            self.assertNotEqual(invalid_utf8.returncode, 0)
            self.assertIn("strict UTF-8 JSON", invalid_utf8.stderr)
            self.assertFalse(invalid_utf8_output.exists())

            oversized_resource = workspace / "oversized.json"
            oversized_resource.write_bytes(b" " * ((32 * 1024) + 1))
            oversized_output = workspace / "oversized.app"
            oversized = self._run(executable, oversized_output, trust_resource=oversized_resource)
            self.assertNotEqual(oversized.returncode, 0)
            self.assertIn("exceeds its maximum size", oversized.stderr)
            self.assertFalse(oversized_output.exists())

            duplicate_resource = workspace / "duplicate-fields.json"
            duplicate_resource.write_text(
                self._duplicate_field_json(self._release_trust_payload()),
                encoding="utf-8",
            )
            duplicate_output = workspace / "duplicate.app"
            duplicate = self._run(executable, duplicate_output, trust_resource=duplicate_resource)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn("strict UTF-8 JSON", duplicate.stderr)
            self.assertFalse(duplicate_output.exists())

            nonfinite_resource = workspace / "nonfinite.json"
            nonfinite_resource.write_text('{"signature_threshold":NaN}', encoding="utf-8")
            nonfinite_output = workspace / "nonfinite.app"
            nonfinite = self._run(executable, nonfinite_output, trust_resource=nonfinite_resource)
            self.assertNotEqual(nonfinite.returncode, 0)
            self.assertIn("strict UTF-8 JSON", nonfinite.stderr)
            self.assertFalse(nonfinite_output.exists())

    def test_rejects_private_fields_and_symlinked_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            valid_resource, _ = self._release_trust_resource(workspace)

            private_resource = workspace / "unexpected-private-key.json"
            payload = self._release_trust_payload()
            payload["private_key"] = "never-accepted"
            self._write_payload(private_resource, payload)
            private_output = workspace / "private-key.app"
            private_result = self._run(executable, private_output, trust_resource=private_resource)
            self.assertNotEqual(private_result.returncode, 0)
            self.assertIn("unsupported or missing fields", private_result.stderr)
            self.assertFalse(private_output.exists())

            symlink = workspace / "symlinked-release-trust.json"
            symlink.symlink_to(valid_resource)
            symlink_output = workspace / "symlink.app"
            symlink_result = self._run(executable, symlink_output, trust_resource=symlink)
            self.assertNotEqual(symlink_result.returncode, 0)
            self.assertIn("must not be selected through a symlink", symlink_result.stderr)
            self.assertFalse(symlink_output.exists())

    def test_rejects_noncanonical_provenance_bytes_before_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            valid_resource, _ = self._release_provenance_resource(workspace)

            duplicate = workspace / "duplicate provenance.json"
            duplicate.write_text(
                self._duplicate_field_json(self._release_provenance_payload(), field="provenance_sha256"),
                encoding="utf-8",
            )
            result = self._run(executable, workspace / "duplicate.app", provenance_resource=duplicate)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("strict UTF-8 JSON", result.stderr)

            malformed = workspace / "malformed provenance.json"
            payload = self._release_provenance_payload()
            payload["capabilities"] = ["provider-gate/v1", "composition/v1", "system-launchdaemon/v1"]
            self._write_payload(malformed, payload)
            result = self._run(executable, workspace / "unsorted.app", provenance_resource=malformed)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sorted, unique", result.stderr)

            mismatched = workspace / "mismatched provenance.json"
            payload = self._release_provenance_payload()
            payload["provenance_sha256"] = "f" * 64
            self._write_payload(mismatched, payload)
            result = self._run(executable, workspace / "mismatched.app", provenance_resource=mismatched)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match its fields", result.stderr)

            private = workspace / "private provenance.json"
            payload = self._release_provenance_payload()
            payload["url"] = "https://never-accepted.example.invalid/"
            self._write_payload(private, payload)
            result = self._run(executable, workspace / "private.app", provenance_resource=private)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported or missing fields", result.stderr)

            linked = workspace / "linked provenance.json"
            linked.symlink_to(valid_resource)
            result = self._run(executable, workspace / "linked.app", provenance_resource=linked)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not be selected through a symlink", result.stderr)

            overflow = workspace / "overflow provenance.json"
            self._write_payload(
                overflow,
                self._release_provenance_payload(release_sequence=(1 << 64)),
            )
            result = self._run(executable, workspace / "overflow.app", provenance_resource=overflow)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sequence is invalid", result.stderr)

            trust_resource, _ = self._release_trust_resource(workspace)
            result = self._run(executable, workspace / "partial.app", trust_resource=trust_resource)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires both sealed release trust and provenance", result.stderr)

            result = self._run(
                executable,
                workspace / "mismatched-trust.app",
                trust_resource=trust_resource,
                provenance_resource=valid_resource,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match the bundled release trust resource", result.stderr)

            result = self._run(
                executable,
                workspace / "provenance-only.app",
                provenance_resource=valid_resource,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires both sealed release trust and provenance", result.stderr)

    def test_rejects_release_resources_that_do_not_bind_the_packaged_app_projection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, _ = self._release_trust_resource(workspace)

            wrong_version, _ = self._release_provenance_resource(
                workspace,
                installer_version="1.2.3",
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            result = self._run(
                executable,
                workspace / "wrong-version.app",
                trust_resource=trust_resource,
                provenance_resource=wrong_version,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("installer version does not match", result.stderr)

            wrong_channel, _ = self._release_provenance_resource(
                workspace,
                channel="candidate",
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            result = self._run(
                executable,
                workspace / "wrong-channel.app",
                trust_resource=trust_resource,
                provenance_resource=wrong_channel,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("channel does not match", result.stderr)

            wrong_capabilities, _ = self._release_provenance_resource(
                workspace,
                capabilities=["composition/v1"],
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            result = self._run(
                executable,
                workspace / "wrong-capabilities.app",
                trust_resource=trust_resource,
                provenance_resource=wrong_capabilities,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("capabilities do not match", result.stderr)

            mismatched_bundle_trust, _ = self._release_trust_resource(
                workspace,
                bundle_identifier="com.example.other-installer",
            )
            other_bundle_configuration = self._release_trust_payload(
                bundle_identifier="com.example.other-installer"
            )["configuration_sha256"]
            assert isinstance(other_bundle_configuration, str)
            other_bundle_provenance, _ = self._release_provenance_resource(
                workspace,
                release_trust_configuration_sha256=other_bundle_configuration,
            )
            result = self._run(
                executable,
                workspace / "wrong-bundle.app",
                trust_resource=mismatched_bundle_trust,
                provenance_resource=other_bundle_provenance,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("bundle identifier does not match", result.stderr)

    def test_public_packager_api_revalidates_manually_constructed_resources_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            output = workspace / "direct-api.app"
            forged_trust = SealedReleaseTrustResource(
                source=workspace / "not-a-real-trust.json",
                contents=b"not-json-trust",
                configuration_sha256="a" * 64,
                repository="example-owner/example-installer",
                release_descriptor_locator="github-release-asset-v1",
                release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
                expected_bundle_identifier="com.example.forge-platform-installer",
                expected_team_identifier="AB12CD34EF",
                signature_threshold=1,
                signature_key_ids=("release-key-001",),
            )
            forged_provenance = SealedReleaseProvenanceResource(
                source=workspace / "not-a-real-provenance.json",
                contents=b"not-json-provenance",
                provenance_sha256="b" * 64,
                installer_version=_INSTALLER_VERSION,
                channel="stable",
                release_sequence=1,
                source_revision="a" * 40,
                policy_revision="forge-platform-installer-release-v1",
                capabilities=("composition/v1",),
                release_trust_configuration_sha256="a" * 64,
            )

            with self.assertRaisesRegex(ValueError, "strict UTF-8 JSON"):
                package(
                    executable=executable,
                    cli_executable=self._cli_executable(workspace),
                    output=output,
                    bundle_identifier="com.example.forge-platform-installer",
                    sealed_release_trust=forged_trust,
                    sealed_release_provenance=forged_provenance,
                )
            self.assertFalse(output.exists())

    def test_public_packager_api_revalidates_a_manually_constructed_catalog_policy_before_pair_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            output = workspace / "forged-catalog-policy.app"
            forged_catalog_trust = SealedCompositionCatalogTrustResource(
                source=workspace / "not-a-real-catalog-policy.json",
                contents=b"not-json-catalog-policy",
                configuration_sha256="a" * 64,
                installer_release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
                signature_threshold=1,
                signature_key_ids=("catalog-key-001",),
            )

            with self.assertRaisesRegex(ValueError, "strict UTF-8 JSON"):
                package(
                    executable=executable,
                    cli_executable=self._cli_executable(workspace),
                    output=output,
                    bundle_identifier="com.example.forge-platform-installer",
                    sealed_composition_catalog_trust=forged_catalog_trust,
                )
            self.assertFalse(output.exists())

    def test_public_packager_api_revalidates_executable_output_and_bundle_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            symlinked_executable = workspace / "symlinked-installer"
            symlinked_executable.symlink_to(executable)
            symlink_output = workspace / "symlink-rejected.app"

            with self.assertRaisesRegex(ValueError, "must not be selected through a symlink"):
                package(
                    executable=symlinked_executable,
                    cli_executable=self._cli_executable(workspace),
                    output=symlink_output,
                    bundle_identifier="com.example.forge-platform-installer",
                )
            self.assertFalse(symlink_output.exists())

            invalid_identifier_output = workspace / "invalid-identifier.app"
            with self.assertRaisesRegex(ValueError, "bundle identifier is invalid"):
                package(
                    executable=executable,
                    cli_executable=self._cli_executable(workspace),
                    output=invalid_identifier_output,
                    bundle_identifier="not a bundle identifier",
                )
            self.assertFalse(invalid_identifier_output.exists())

    def test_rejects_noncanonical_key_ids_public_keys_order_and_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            public_keys = self._public_keys()

            uppercase_id = [("Descriptor-key-a", public_keys[0][1]), public_keys[1]]
            uppercase_resource = workspace / "uppercase-key-id.json"
            self._write_payload(uppercase_resource, self._release_trust_payload(keys=uppercase_id))
            uppercase = self._run(executable, workspace / "uppercase.app", trust_resource=uppercase_resource)
            self.assertNotEqual(uppercase.returncode, 0)
            self.assertIn("public key ID is invalid", uppercase.stderr)

            unordered_resource = workspace / "unordered-key-ids.json"
            self._write_payload(unordered_resource, self._release_trust_payload(keys=list(reversed(public_keys))))
            unordered = self._run(executable, workspace / "unordered.app", trust_resource=unordered_resource)
            self.assertNotEqual(unordered.returncode, 0)
            self.assertIn("strictly ordered", unordered.stderr)

            duplicate_resource = workspace / "duplicate-key-id.json"
            duplicate_keys = [(public_keys[0][0], public_keys[0][1]), (public_keys[0][0], public_keys[1][1])]
            self._write_payload(duplicate_resource, self._release_trust_payload(keys=duplicate_keys))
            duplicate = self._run(executable, workspace / "duplicate-key.app", trust_resource=duplicate_resource)
            self.assertNotEqual(duplicate.returncode, 0)
            self.assertIn("public keys must be unique", duplicate.stderr)

            invalid_base64_resource = workspace / "noncanonical-public-key.json"
            noncanonical_keys = [(public_keys[0][0], public_keys[0][1] + "\n"), public_keys[1]]
            self._write_payload(invalid_base64_resource, self._release_trust_payload(keys=noncanonical_keys))
            invalid_base64 = self._run(
                executable,
                workspace / "noncanonical-key.app",
                trust_resource=invalid_base64_resource,
            )
            self.assertNotEqual(invalid_base64.returncode, 0)
            self.assertIn("public key is invalid", invalid_base64.stderr)

            threshold_resource = workspace / "threshold-too-large.json"
            self._write_payload(
                threshold_resource,
                self._release_trust_payload(keys=public_keys, signature_threshold=3),
            )
            threshold = self._run(executable, workspace / "threshold.app", trust_resource=threshold_resource)
            self.assertNotEqual(threshold.returncode, 0)
            self.assertIn("threshold exceeds public keys", threshold.stderr)

    def test_refuses_to_overwrite_an_existing_output_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            trust_resource, _ = self._release_trust_resource(workspace)
            provenance_resource, _ = self._release_provenance_resource(
                workspace,
                release_trust_configuration_sha256=_PUBLIC_V2_DIGEST,
            )
            app_bundle = workspace / "ForgePlatformInstaller.app"
            app_bundle.mkdir()
            sentinel = app_bundle / "must-not-change"
            sentinel.write_bytes(b"existing output must be preserved")

            result = self._run(
                executable,
                app_bundle,
                trust_resource=trust_resource,
                provenance_resource=provenance_resource,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not already exist", result.stderr)
            self.assertEqual(sentinel.read_bytes(), b"existing output must be preserved")

    def test_bundle_metadata_is_deterministic_for_the_same_version_and_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            first = workspace / "first" / "ForgePlatformInstaller.app"
            second = workspace / "second" / "ForgePlatformInstaller.app"

            self.assertEqual(self._run(executable, first).returncode, 0)
            self.assertEqual(self._run(executable, second).returncode, 0)

            self.assertEqual(
                (first / "Contents" / "Info.plist").read_bytes(),
                (second / "Contents" / "Info.plist").read_bytes(),
            )
            self.assertEqual(
                (first / "Contents" / "MacOS" / "ForgePlatformInstaller").read_bytes(),
                (second / "Contents" / "MacOS" / "ForgePlatformInstaller").read_bytes(),
            )

    def test_rejects_x86_64_and_universal_executables_before_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            fixtures = (
                ("x86_64", bytes.fromhex("cffaedfe070000010300000002000000") + bytes(16)),
                ("universal", bytes.fromhex("cafebabe00000002") + bytes(24)),
            )
            for name, header in fixtures:
                executable = workspace / name
                executable.write_bytes(header)
                executable.chmod(0o755)
                output = workspace / f"{name}.app"

                result = self._run(executable, output)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("thin arm64 Mach-O executable", result.stderr)
                self.assertFalse(output.exists())

    def test_rejects_a_non_bundle_identifier_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            executable = self._executable(workspace)
            app_bundle = workspace / "ForgePlatformInstaller.app"

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--executable",
                    str(executable),
                    "--cli-executable",
                    str(self._cli_executable(workspace)),
                    "--output",
                    str(app_bundle),
                    "--bundle-identifier",
                    "not a bundle identifier",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("bundle identifier", result.stderr)
            self.assertFalse(app_bundle.exists())

    @staticmethod
    def _executable(workspace: Path) -> Path:
        executable = workspace / "ForgePlatformInstaller"
        executable.write_bytes(thin_arm64_macho_test_bytes(b"native installer candidate bytes\n"))
        executable.chmod(0o755)
        return executable

    @staticmethod
    def _cli_executable(workspace: Path) -> Path:
        executable = workspace / "forge-platform-installer"
        executable.write_bytes(thin_arm64_macho_test_bytes(b"native installer cli candidate bytes\n"))
        executable.chmod(0o755)
        return executable

    @staticmethod
    def _public_keys() -> list[tuple[str, str]]:
        return [
            ("descriptor-key-a", base64.b64encode(bytes(range(32))).decode("ascii")),
            ("descriptor-key-b", base64.b64encode(bytes(range(32, 64))).decode("ascii")),
        ]

    @staticmethod
    def _catalog_public_keys() -> list[tuple[str, str]]:
        return [
            ("catalog-key-a", base64.b64encode(bytes(range(32))).decode("ascii")),
            ("catalog-key-b", base64.b64encode(bytes(range(32, 64))).decode("ascii")),
        ]

    @classmethod
    def _release_trust_payload(
        cls,
        *,
        keys: list[tuple[str, str]] | None = None,
        signature_threshold: int = 2,
        bundle_identifier: str = "com.example.forge-platform-installer",
    ) -> dict[str, object]:
        selected_keys = keys if keys is not None else cls._public_keys()
        return {
            "schema_version": 2,
            "configuration_sha256": cls._release_trust_digest(
                selected_keys,
                signature_threshold=signature_threshold,
                bundle_identifier=bundle_identifier,
            ),
            "repository": "example-owner/example-installer",
            "release_descriptor_locator": "github-release-asset-v1",
            "release_descriptor_asset_name": "ForgePlatformInstallerReleaseDescriptor.json",
            "expected_bundle_identifier": bundle_identifier,
            "expected_team_identifier": "AB12CD34EF",
            "signature_threshold": signature_threshold,
            "ed25519_public_keys": [
                {"key_id": key_id, "public_key_base64": public_key_base64}
                for key_id, public_key_base64 in selected_keys
            ],
        }

    @classmethod
    def _release_trust_resource(
        cls,
        workspace: Path,
        *,
        bundle_identifier: str = "com.example.forge-platform-installer",
    ) -> tuple[Path, bytes]:
        contents = (
            json.dumps(
                cls._release_trust_payload(bundle_identifier=bundle_identifier),
                sort_keys=True,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
        resource = workspace / "caller supplied trust" / (
            "release-trust-" + hashlib.sha256(contents).hexdigest()[:16] + ".json"
        )
        resource.parent.mkdir(exist_ok=True)
        resource.write_bytes(contents)
        return resource, contents

    @classmethod
    def _catalog_trust_payload(
        cls,
        *,
        installer_release_trust_configuration_sha256: str = _PUBLIC_V2_DIGEST,
        keys: list[tuple[str, str]] | None = None,
        signature_threshold: int = 2,
    ) -> dict[str, object]:
        selected_keys = keys if keys is not None else cls._catalog_public_keys()
        return {
            "schema_version": 1,
            "configuration_sha256": canonical_composition_catalog_trust_configuration_sha256(
                installer_release_trust_configuration_sha256=(
                    installer_release_trust_configuration_sha256
                ),
                signature_threshold=signature_threshold,
                ed25519_public_keys=selected_keys,
            ),
            "installer_release_trust_configuration_sha256": (
                installer_release_trust_configuration_sha256
            ),
            "signature_threshold": signature_threshold,
            "ed25519_public_keys": [
                {"key_id": key_id, "public_key_base64": public_key_base64}
                for key_id, public_key_base64 in selected_keys
            ],
        }

    @classmethod
    def _catalog_trust_resource(
        cls,
        workspace: Path,
        *,
        installer_release_trust_configuration_sha256: str = _PUBLIC_V2_DIGEST,
    ) -> tuple[Path, bytes]:
        contents = (
            json.dumps(
                cls._catalog_trust_payload(
                    installer_release_trust_configuration_sha256=(
                        installer_release_trust_configuration_sha256
                    )
                ),
                sort_keys=True,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
        resource = workspace / "caller supplied catalog policy" / (
            "catalog-trust-" + hashlib.sha256(contents).hexdigest()[:16] + ".json"
        )
        resource.parent.mkdir(exist_ok=True)
        resource.write_bytes(contents)
        return resource, contents

    @staticmethod
    def _release_provenance_payload(
        *,
        installer_version: str = "1.2.3",
        channel: str = "stable",
        capabilities: list[str] | None = None,
        release_sequence: int = 42,
        release_trust_configuration_sha256: str = "b" * 64,
    ) -> dict[str, object]:
        selected_capabilities = (
            [
                "composition/v1",
                "managed-python-runtime/v1",
                "provider-gate/v1",
                "system-launchdaemon/v1",
            ]
            if capabilities is None
            else capabilities
        )
        return {
            "schema_version": 1,
            "provenance_sha256": PackageMacOSInstallerAppTests._release_provenance_digest({
                "installer_version": installer_version,
                "channel": channel,
                "release_sequence": release_sequence,
                "source_revision": "a" * 40,
                "policy_revision": "forge-platform-installer-release-v1",
                "release_trust_configuration_sha256": release_trust_configuration_sha256,
                "capabilities": selected_capabilities,
            }),
            "installer_version": installer_version,
            "channel": channel,
            "release_sequence": release_sequence,
            "source_revision": "a" * 40,
            "policy_revision": "forge-platform-installer-release-v1",
            "capabilities": selected_capabilities,
            "release_trust_configuration_sha256": release_trust_configuration_sha256,
        }

    @classmethod
    def _release_provenance_resource(
        cls,
        workspace: Path,
        *,
        installer_version: str = _INSTALLER_VERSION,
        channel: str = "stable",
        capabilities: list[str] | None = None,
        release_sequence: int = 42,
        release_trust_configuration_sha256: str = "b" * 64,
    ) -> tuple[Path, bytes]:
        if capabilities is None:
            capabilities = list(_INSTALLER_CAPABILITIES)
        contents = (
            json.dumps(
                cls._release_provenance_payload(
                    installer_version=installer_version,
                    channel=channel,
                    capabilities=capabilities,
                    release_sequence=release_sequence,
                    release_trust_configuration_sha256=release_trust_configuration_sha256
                ),
                sort_keys=True,
                indent=2,
            )
            + "\n"
        ).encode("utf-8")
        resource = workspace / "caller supplied provenance" / (
            "release-provenance-" + hashlib.sha256(contents).hexdigest()[:16] + ".json"
        )
        resource.parent.mkdir(exist_ok=True)
        resource.write_bytes(contents)
        return resource, contents

    @staticmethod
    def _write_payload(resource: Path, payload: dict[str, object]) -> None:
        resource.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")

    @staticmethod
    def _duplicate_field_json(payload: dict[str, object], *, field: str = "repository") -> str:
        canonical = json.dumps(payload, separators=(",", ":"))
        return canonical[:-1] + f',"{field}":{json.dumps(payload[field], separators=(",", ":"))}' + "}"

    @staticmethod
    def _release_trust_digest(
        keys: list[tuple[str, str]],
        *,
        signature_threshold: int,
        bundle_identifier: str = "com.example.forge-platform-installer",
    ) -> str:
        fields = [
            "forge-platform-installer-release-trust-v2",
            "schema_version=2",
            "repository=example-owner/example-installer",
            "release_descriptor_locator=github-release-asset-v1",
            "release_descriptor_asset_name=ForgePlatformInstallerReleaseDescriptor.json",
            f"expected_bundle_identifier={bundle_identifier}",
            "expected_team_identifier=AB12CD34EF",
            f"signature_threshold={signature_threshold}",
            f"ed25519_public_key_count={len(keys)}",
        ]
        for key_id, public_key_base64 in keys:
            fields.append(f"ed25519_public_key_id={key_id}")
            fields.append(f"ed25519_public_key_base64={public_key_base64}")
        return hashlib.sha256("\0".join(fields).encode("utf-8")).hexdigest()

    @staticmethod
    def _release_provenance_digest(payload: dict[str, object]) -> str:
        capabilities = payload["capabilities"]
        assert isinstance(capabilities, list)
        fields = [
            "forge-platform-installer-release-provenance-v1",
            "schema_version=1",
            f"installer_version={payload['installer_version']}",
            f"channel={payload['channel']}",
            f"release_sequence={payload['release_sequence']}",
            f"source_revision={payload['source_revision']}",
            f"policy_revision={payload['policy_revision']}",
            f"release_trust_configuration_sha256={payload['release_trust_configuration_sha256']}",
            f"capability_count={len(capabilities)}",
        ]
        fields.extend(f"capability={capability}" for capability in capabilities)
        return hashlib.sha256("\0".join(fields).encode("utf-8")).hexdigest()

    @staticmethod
    def _run(
        executable: Path,
        app_bundle: Path,
        *,
        trust_resource: Path | None = None,
        provenance_resource: Path | None = None,
        catalog_trust_resource: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        cli_executable = PackageMacOSInstallerAppTests._cli_executable(executable.parent)
        command = [
            sys.executable,
            str(SCRIPT),
            "--executable",
            str(executable),
            "--cli-executable",
            str(cli_executable),
            "--output",
            str(app_bundle),
            "--bundle-identifier",
            "com.example.forge-platform-installer",
        ]
        if trust_resource is not None:
            command.extend(("--sealed-release-trust-resource", str(trust_resource)))
        if provenance_resource is not None:
            command.extend(("--sealed-release-provenance-resource", str(provenance_resource)))
        if catalog_trust_resource is not None:
            command.extend(("--sealed-composition-catalog-trust-resource", str(catalog_trust_resource)))
        return subprocess.run(
            command,
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
