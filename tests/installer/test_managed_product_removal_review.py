#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import unittest

from forge_platform.managed_product_removal_review import (
    ManagedProductRemovalReviewError, ManagedProductRemovalReviewJournal,
)
import tests.installer.test_managed_product_removal_admission as admission_fixtures


class ManagedProductRemovalReviewTests(unittest.TestCase):
    def setUp(self):
        self.fixture = admission_fixtures.ManagedProductRemovalAdmissionTests(
            "test_exact_paired_component_removal_retains_ep_and_other_deployment"
        )
        self.fixture.setUp()
        self.payload = self.fixture.payload()
        self.admitted = self.fixture.admit(self.payload)
        self.root = self.fixture.root / "reviews"
        self.journal = ManagedProductRemovalReviewJournal(
            root=self.root, registry=self.fixture.registry,
            expected_owner_uid=self.fixture.root.stat().st_uid,
        )

    def tearDown(self):
        self.fixture.tearDown()

    def test_prepare_load_and_duplicate_bind_same_reviewed_snapshot(self):
        with self.assertRaisesRegex(ManagedProductRemovalReviewError, "root is unavailable"):
            self.journal.load(
                self.admitted.request, installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
            )
        first = self.journal.prepare(
            self.admitted, current_installer_release=self.fixture.release,
        )
        self.assertEqual(first.reviewed_current, self.fixture.paired)
        self.assertEqual(
            self.journal.load(
                self.admitted.request, installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
            ), first,
        )
        self.assertEqual(
            self.journal.prepare(
                self.admitted, current_installer_release=self.fixture.release,
            ), first,
        )
        self.assertEqual((self.root / "remove-a.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)

    def test_stale_registry_or_substituted_request_cannot_prepare_or_load(self):
        self.journal.prepare(self.admitted, current_installer_release=self.fixture.release)
        substituted = replace(
            self.admitted.request, request_fingerprint="0" * 64,
        )
        with self.assertRaises(ManagedProductRemovalReviewError):
            self.journal.load(
                substituted, installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
            )
        with self.assertRaises(ManagedProductRemovalReviewError):
            self.journal.load(
                self.admitted.request, installed_manifest=self.fixture.manifest,
                current_installer_release=replace(self.fixture.release, version="9.9.9"),
            )
        self.fixture.registry.replace(
            replace(self.fixture.paired, revision=2), expected_revision=1,
        )
        with self.assertRaises(Exception):
            self.journal.prepare(
                self.admitted, current_installer_release=self.fixture.release,
            )

    def test_tampered_or_symlinked_snapshot_fails_closed(self):
        self.journal.prepare(self.admitted, current_installer_release=self.fixture.release)
        path = self.root / "remove-a.json"
        original = path.read_bytes()
        path.write_bytes(original.replace(b"forge-a", b"forge-b"))
        with self.assertRaises(ManagedProductRemovalReviewError):
            self.journal.load(
                self.admitted.request, installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
            )
        path.unlink()
        path.symlink_to(self.fixture.root / "other.json")
        with self.assertRaises(OSError):
            self.journal.load(
                self.admitted.request, installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
            )

    def test_invalid_root_and_owner_fail_closed(self):
        with self.assertRaises(ValueError):
            ManagedProductRemovalReviewJournal(
                root=Path("relative"), registry=self.fixture.registry,
            )
        unsafe = self.fixture.root / "unsafe"
        unsafe.mkdir(mode=0o755)
        journal = ManagedProductRemovalReviewJournal(
            root=unsafe, registry=self.fixture.registry,
            expected_owner_uid=self.fixture.root.stat().st_uid,
        )
        with self.assertRaisesRegex(ManagedProductRemovalReviewError, "unsafe"):
            journal.prepare(
                self.admitted, current_installer_release=self.fixture.release,
            )


if __name__ == "__main__":
    unittest.main()
