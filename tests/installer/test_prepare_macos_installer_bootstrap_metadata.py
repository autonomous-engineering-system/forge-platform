from __future__ import annotations
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
import prepare_macos_installer_bootstrap_metadata as producer
from forge_platform.installer_release_trust import canonical_release_trust_configuration_sha256
from forge_platform.installer_release_provenance import canonical_release_provenance_sha256


class BootstrapMetadataTests(unittest.TestCase):
    def inputs(self, root, **changes):
        key = base64.b64encode(bytes(range(32))).decode("ascii")
        trust = dict(repository="autonomous-engineering-system/forge-platform",
            release_descriptor_locator="github-release-asset-v1",
            release_descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
            expected_bundle_identifier=producer.APP_IDENTIFIER,
            expected_team_identifier=producer.TEAM, signature_threshold=1,
            ed25519_public_keys=[("source-test", key)])
        trust.update(changes)
        digest = canonical_release_trust_configuration_sha256(**trust)
        trust["ed25519_public_keys"] = [dict(key_id=keyid, public_key_base64=value) for keyid, value in trust["ed25519_public_keys"]]
        trust.update(schema_version=2, configuration_sha256=digest)
        provenance = dict(installer_version="1.2.3", channel="stable", release_sequence=42,
            source_revision="a" * 40, policy_revision="source-test/v1",
            release_trust_configuration_sha256=digest, capabilities=["composition/v1"])
        provenance.update(provenance_sha256=canonical_release_provenance_sha256(**provenance), schema_version=1)
        tp, pp = root / "trust.json", root / "provenance.json"
        tp.write_bytes((json.dumps(trust, sort_keys=True) + "\n").encode())
        pp.write_bytes((json.dumps(provenance, sort_keys=True) + "\n").encode())
        return tp, pp

    def test_exact_public_bytes_fixed_mutual_requirements_and_no_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trust, provenance = self.inputs(root)
            output = root / "link-inputs"
            receipt = producer.prepare(trust=trust, provenance=provenance, output=output)
            info = plistlib.loads((output / "bootstrap-info.plist").read_bytes())
            self.assertEqual(base64.b64decode(info["FPIReleaseTrustResource"], validate=True), trust.read_bytes())
            self.assertEqual(base64.b64decode(info["FPIReleaseProvenanceResource"], validate=True), provenance.read_bytes())
            self.assertEqual(info["SMAuthorizedClients"], [producer.requirement(producer.APP_IDENTIFIER)])
            self.assertEqual(info["CFBundleIdentifier"], producer.LABEL)
            self.assertEqual(info["CFBundleVersion"], "1.2.3")
            self.assertEqual(plistlib.loads((output / "bootstrap-launchd.plist").read_bytes()),
                             {"Label": producer.LABEL, "MachServices": {producer.LABEL: True}})
            self.assertEqual(plistlib.loads((output / "application-requirements.plist").read_bytes()),
                             {"SMPrivilegedExecutables": {producer.LABEL: producer.requirement(producer.LABEL)}})
            self.assertEqual(receipt["status"], "UNSIGNED_LINK_INPUT_ONLY")
            self.assertFalse(receipt["production_admitted"])
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            for name, record in receipt["files"].items():
                data = (output / name).read_bytes()
                self.assertEqual(record, {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
                self.assertEqual((output / name).stat().st_mode & 0o777, 0o600)

    def test_valid_but_wrong_team_bundle_or_repository_fails_without_output(self):
        for changes in [dict(expected_team_identifier="OTHERTEAM1"), dict(expected_bundle_identifier="com.example.other"), dict(repository="example/other")]:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                trust, provenance = self.inputs(root, **changes)
                with self.assertRaises(ValueError): producer.prepare(trust=trust, provenance=provenance, output=root / "output")
                self.assertFalse((root / "output").exists())

    def test_mismatched_valid_provenance_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); trust, provenance = self.inputs(root)
            fields = json.loads(provenance.read_bytes())
            fields.pop("schema_version"); fields.pop("provenance_sha256")
            fields["release_trust_configuration_sha256"] = "b" * 64
            fields.update(provenance_sha256=canonical_release_provenance_sha256(**fields), schema_version=1)
            provenance.write_text(json.dumps(fields))
            with self.assertRaises(ValueError): producer.prepare(trust=trust, provenance=provenance, output=root / "output")
            self.assertFalse((root / "output").exists())

    def test_link_fifo_oversize_and_duplicate_json_fail_without_hanging(self):
        for kind in ["link", "fifo", "oversize", "duplicate"]:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); trust, provenance = self.inputs(root)
                if kind == "link":
                    trust.rename(root / "original.json"); trust.symlink_to(root / "original.json")
                elif kind == "fifo": trust.unlink(); os.mkfifo(trust)
                elif kind == "oversize": trust.write_bytes(b" " * (128 * 1024))
                else: trust.write_bytes(b'{"schema_version":2,"schema_version":2}')
                with self.assertRaises(ValueError): producer.prepare(trust=trust, provenance=provenance, output=root / "output")
                self.assertFalse((root / "output").exists())

    def test_existing_directory_or_symlink_is_never_overwritten(self):
        for linked in [False, True]:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); trust, provenance = self.inputs(root)
                retained = root / "retained"; retained.mkdir(); (retained / "marker").write_bytes(b"keep")
                output = root / "output"
                if linked: output.symlink_to(retained)
                else: output.mkdir(); (output / "marker").write_bytes(b"keep")
                with self.assertRaises(FileExistsError): producer.prepare(trust=trust, provenance=provenance, output=output)
                self.assertEqual((retained / "marker").read_bytes(), b"keep")
                self.assertTrue(output.exists())

    def test_sync_failure_retains_partial_inputs_without_success_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); trust, provenance = self.inputs(root)
            with patch.object(producer.os, "fsync", side_effect=OSError("sync failed")):
                with self.assertRaises(OSError): producer.prepare(trust=trust, provenance=provenance, output=root / "output")
            self.assertFalse((root / "output").exists())
            stages = list(root.glob(".fpi-bootstrap-metadata-*"))
            self.assertEqual(len(stages), 1)
            self.assertFalse((stages[0] / "receipt.json").exists())

    def test_competing_output_at_publication_is_preserved_and_not_acknowledged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); trust, provenance = self.inputs(root)
            output = root / "output"
            publish = producer._publish_exclusively
            def compete(source, destination):
                destination.mkdir(); (destination / "marker").write_bytes(b"keep")
                publish(source, destination)
            with patch.object(producer, "_publish_exclusively", side_effect=compete):
                with self.assertRaises(OSError): producer.prepare(trust=trust, provenance=provenance, output=output)
            self.assertEqual((output / "marker").read_bytes(), b"keep")
            self.assertFalse((output / "receipt.json").exists())

    def test_directory_swap_after_publication_is_never_acknowledged_or_deleted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); trust, provenance = self.inputs(root)
            output = root / "output"
            publish = producer._publish_exclusively
            def swap(source, destination):
                publish(source, destination)
                destination.rename(root / "retained")
                destination.mkdir(); (destination / "marker").write_bytes(b"keep")
            with patch.object(producer, "_publish_exclusively", side_effect=swap):
                with self.assertRaises(ValueError): producer.prepare(trust=trust, provenance=provenance, output=output)
            self.assertEqual((output / "marker").read_bytes(), b"keep")
            self.assertTrue((root / "retained" / "receipt.json").exists())

    @unittest.skipUnless(sys.platform == "darwin", "Apple linker qualification")
    def test_real_arm64_linker_preserves_both_exact_embedded_plists(self):
        # A harmless compile-only test executable, not a bootstrap helper or
        # signed/installed product. It is never executed or signed.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); trust, provenance = self.inputs(root)
            output = root / "inputs"
            producer.prepare(trust=trust, provenance=provenance, output=output)
            source = root / "link-test.c"; source.write_text("int main(void) { return 78; }\n")
            binary = root / "link-test"
            result = subprocess.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=26.0",
                str(source), "-o", str(binary),
                "-Wl,-sectcreate,__TEXT,__info_plist," + str(output / "bootstrap-info.plist"),
                "-Wl,-sectcreate,__TEXT,__launchd_plist," + str(output / "bootstrap-launchd.plist")],
                capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            data = binary.read_bytes()
            from forge_platform.macos_platform_contract import require_thin_arm64_macho_header
            require_thin_arm64_macho_header(data[:32], "compile-only linker qualification")
            commands = struct.unpack_from("<I", data, 16)[0]
            offset = 32; sections = {}
            for _ in range(commands):
                command, size = struct.unpack_from("<II", data, offset)
                self.assertGreaterEqual(size, 8); self.assertLessEqual(offset + size, len(data))
                if command == 0x19:
                    count = struct.unpack_from("<I", data, offset + 64)[0]
                    for index in range(count):
                        position = offset + 72 + index * 80
                        self.assertLessEqual(position + 80, offset + size)
                        name, segment, _, length, start = struct.unpack_from("<16s16sQQI", data, position)
                        name = name.rstrip(b"\0"); segment = segment.rstrip(b"\0")
                        if segment == b"__TEXT" and name in {b"__info_plist", b"__launchd_plist"}:
                            self.assertNotIn(name, sections)
                            self.assertLessEqual(start + length, len(data))
                            sections[name] = data[start:start + length]
                offset += size
            self.assertEqual(sections, {
                b"__info_plist": (output / "bootstrap-info.plist").read_bytes(),
                b"__launchd_plist": (output / "bootstrap-launchd.plist").read_bytes(),
            })

    def test_requirement_cannot_accept_arbitrary_identifiers(self):
        with self.assertRaises(ValueError): producer.requirement('com.example.other" or true')

if __name__ == "__main__": unittest.main()
