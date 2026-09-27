"""Fail-closed durability checks for exact Forge updater coordination."""

from __future__ import annotations

from dataclasses import replace
import json
import os
from pathlib import Path
import tempfile
import unittest

from forge_platform.forge_update_intent import (
    ForgeUpdateIntent,
    ForgeUpdateIntentError,
    ForgeUpdateIntentStore,
)


class ForgeUpdateIntentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "private"
        self.root.mkdir(mode=0o700)
        self.store = ForgeUpdateIntentStore(self.root)
        self.intent = ForgeUpdateIntent(
            "forge-update-1", "a" * 64, "forge-instance-1",
            "sha256:" + "b" * 64, "sha256:" + "c" * 64,
            "forge-update-assess:sha256:" + "d" * 64,
        )
        self.receipt = "forge-update:sha256:" + "e" * 64

    def test_durable_exact_phase_progression_and_replay(self) -> None:
        self.assertIsNone(self.store.read(self.intent.operation_id))
        pending = self.store.prepare(self.intent)
        self.assertEqual(pending, self.store.prepare(self.intent))
        self.assertEqual((self.root / "forge-update-1.json").stat().st_mode & 0o777, 0o600)
        invoked = self.store.advance(pending, "UPDATER_INVOKED")
        self.assertEqual(self.store.prepare(self.intent), invoked)
        terminal = self.store.advance(invoked, "PRODUCT_COMPLETE", self.receipt)
        complete = self.store.advance(terminal, "COMPLETE")
        self.assertEqual(complete.product_receipt_reference, self.receipt)
        self.assertEqual(self.store.read(self.intent.operation_id), complete)

    def test_changed_selection_and_illegal_transitions_fail_closed(self) -> None:
        current = self.store.prepare(self.intent)
        for changed in (
            replace(self.intent, request_fingerprint="f" * 64),
            replace(self.intent, instance_id="other-instance"),
            replace(self.intent, candidate_artifact="sha256:" + "f" * 64),
            replace(self.intent, assessment_reference="forge-update-assess:sha256:" + "f" * 64),
        ):
            with self.assertRaisesRegex(ForgeUpdateIntentError, "identity changed"):
                self.store.prepare(changed)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "transition"):
            self.store.advance(current, "COMPLETE", self.receipt)
        invoked = self.store.advance(current, "UPDATER_INVOKED")
        with self.assertRaisesRegex(ForgeUpdateIntentError, "changed"):
            self.store.advance(current, "UPDATER_INVOKED")
        terminal = self.store.advance(invoked, "PRODUCT_COMPLETE", self.receipt)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "receipt changed"):
            self.store.advance(terminal, "COMPLETE", "forge-update:sha256:" + "f" * 64)

    def test_corrupt_foreign_or_unsafe_file_fails_closed(self) -> None:
        path = self.root / "forge-update-1.json"
        self.store.prepare(self.intent)
        original = path.read_bytes()
        for raw in (
            original[:-1],
            original.replace(b'"forge-instance-1"', b'""'),
            original.replace(b'"schema":', b'"schema":"duplicate","schema":'),
            b"{",
        ):
            path.write_bytes(raw)
            with self.assertRaises(ForgeUpdateIntentError):
                self.store.read(self.intent.operation_id)
        path.write_bytes(original)
        os.chmod(path, 0o644)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "unsafe"):
            self.store.read(self.intent.operation_id)
        os.chmod(path, 0o600)
        payload = json.loads(original)
        payload["operation_id"] = "foreign"
        path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")
        with self.assertRaisesRegex(ForgeUpdateIntentError, "filename"):
            self.store.read(self.intent.operation_id)

    def test_directory_symlink_mode_and_id_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "absolute"):
            ForgeUpdateIntentStore(Path("relative"))
        for unsafe in ("../escape", "..", "", "bad/name"):
            with self.assertRaises(ValueError):
                self.store.read(unsafe)
        os.chmod(self.root, 0o755)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "mode"):
            self.store.prepare(self.intent)
        os.chmod(self.root, 0o700)
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "unavailable"):
            ForgeUpdateIntentStore(link).read(self.intent.operation_id)

    def test_incomplete_values_cannot_claim_terminal_product_evidence(self) -> None:
        for changes in (
            {"operation_id": "../foreign"},
            {"request_fingerprint": "not-a-fingerprint"},
            {"installed_artifact": "fake"},
            {"assessment_reference": "forge-update-assess:unavailable"},
            {"phase": "COMPLETE"},
            {"phase": "PRODUCT_COMPLETE", "product_receipt_reference": "fake"},
            {"phase": "UPDATER_INVOKED", "product_receipt_reference": self.receipt},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                replace(self.intent, **changes)


if __name__ == "__main__":
    unittest.main()
