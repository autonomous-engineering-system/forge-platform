"""Hostile publication checks for a local, unsigned helper package candidate."""
from hashlib import sha256
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import sys
import subprocess

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT))
import prepare_macos_helper_package as producer


class HelperPackageCandidateTests(unittest.TestCase):
    def test_complete_exclusive_publication_and_private_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root / "candidate.pkg", root / "final.pkg"
            source.write_bytes(b"complete unsigned candidate")
            digest, size = producer.publish_candidate(source, destination)
            self.assertEqual(digest, sha256(source.read_bytes()).hexdigest())
            self.assertEqual(size, source.stat().st_size)
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            source.unlink()
            self.assertEqual(destination.stat().st_nlink, 1)

    def test_existing_destination_and_symlink_are_not_overwritten(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, destination = root / "candidate.pkg", root / "final.pkg"
                source.write_bytes(b"candidate")
                retained = root / "retained"
                retained.write_bytes(b"original")
                if symlink:
                    destination.symlink_to(retained)
                else:
                    destination.write_bytes(b"original")
                with self.assertRaises(FileExistsError):
                    producer.publish_candidate(source, destination)
                self.assertEqual(destination.read_bytes(), b"original")
                self.assertEqual(retained.read_bytes(), b"original")

    def test_empty_large_linked_and_symlink_source_rejected(self):
        for kind in ("empty", "oversize", "hardlink", "symlink"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, destination = root / "candidate.pkg", root / "final.pkg"
                source.write_bytes(b"" if kind == "empty" else b"candidate")
                if kind == "hardlink":
                    os.link(source, root / "alias")
                if kind == "symlink":
                    source.rename(root / "original")
                    source.symlink_to(root / "original")
                limit = 1 if kind == "oversize" else producer.MAXIMUM_PACKAGE_BYTES
                with mock.patch.object(producer, "MAXIMUM_PACKAGE_BYTES", limit):
                    with self.assertRaises((OSError, ValueError)):
                        producer.publish_candidate(source, destination)
                self.assertFalse(os.path.lexists(destination))

    def test_candidate_write_drift_prevents_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, destination = root / "candidate.pkg", root / "final.pkg"
            source.write_bytes(b"candidate")
            real_read = os.read
            changed = False
            def changing_read(descriptor, count):
                nonlocal changed
                data = real_read(descriptor, count)
                if not changed:
                    changed = True
                    source.write_bytes(b"changed-candidate")
                return data
            with mock.patch.object(producer.os, "read", side_effect=changing_read):
                with self.assertRaises(ValueError):
                    producer.publish_candidate(source, destination)
            self.assertFalse(destination.exists())

    def test_parent_sync_failure_retains_unacknowledged_output_without_cleanup_race(self):
        for replaced in (False, True):
            with self.subTest(replaced=replaced), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, destination = root / "candidate.pkg", root / "final.pkg"
                source.write_bytes(b"candidate")
                real_sync = os.fsync
                real_unlink = Path.unlink
                calls = 0
                def failing_sync(descriptor):
                    nonlocal calls
                    calls += 1
                    if calls == 2:
                        if replaced:
                            real_unlink(destination)
                            destination.write_bytes(b"other writer")
                        raise OSError("simulated disk error")
                    return real_sync(descriptor)
                with mock.patch.object(producer.os, "fsync", side_effect=failing_sync), mock.patch.object(Path, "unlink", side_effect=AssertionError("publisher must not unlink a shared path")):
                    with self.assertRaises(OSError):
                        producer.publish_candidate(source, destination)
                if replaced:
                    self.assertEqual(destination.read_bytes(), b"other writer")
                else:
                    self.assertEqual(destination.read_bytes(), b"candidate")

    def test_local_metadata_removed_only_from_new_payload_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "retained"
            source.write_bytes(b"public artifact")
            payload = root / "payload"
            payload.mkdir()
            copied = payload / "copied"
            copied.write_bytes(source.read_bytes())
            for path in [source, payload, copied]:
                subprocess.run(["/usr/bin/xattr", "-w", "test.fpi.local-metadata", "test metadata", str(path)], check=True, capture_output=True)
            producer.strip_staged_metadata(payload)
            self.assertIn(b"test.fpi.local-metadata", subprocess.check_output(["/usr/bin/xattr", str(source)]))
            for path in [payload, copied]:
                attributes = set(subprocess.check_output(["/usr/bin/xattr", str(path)]).decode().splitlines())
                self.assertFalse(attributes - {"com.apple.provenance"})
            self.assertEqual(copied.read_bytes(), source.read_bytes())

    def test_metadata_normalization_refuses_links(self):
        for directory_link in (False, True):
            with self.subTest(directory_link=directory_link), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                outside = root / "outside"
                if directory_link:
                    outside.mkdir()
                else:
                    outside.write_bytes(b"retained")
                payload = root / "payload"
                payload.mkdir()
                (payload / "link").symlink_to(outside, target_is_directory=directory_link)
                with self.assertRaises(ValueError):
                    producer.strip_staged_metadata(payload)
                self.assertTrue(outside.exists())

    def test_machine_payload_cannot_relocate_into_operator_app(self):
        component = producer.package_components()[0]
        self.assertFalse(component["BundleIsRelocatable"])
        self.assertTrue(component["BundleHasStrictIdentifier"])
        daemon = producer.package_launchdaemon()
        self.assertEqual(daemon["ProgramArguments"], [producer.HELPER_PROGRAM])
        self.assertEqual(set(daemon["MachServices"]),
                         {producer.LABEL, producer.LABEL + ".product-operations",
                          producer.LABEL + ".released-route"})
        self.assertNotIn("BundleProgram", daemon)
        self.assertNotIn("EnvironmentVariables", daemon)

if __name__ == "__main__":
    unittest.main()
