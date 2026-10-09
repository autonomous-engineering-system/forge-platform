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
    def test_v2_binding_snapshot_is_durable_and_exact_across_recovery(self) -> None:
        binding = tuple(sorted({
            "updater_executable": "/Applications/Installer.app/Contents/Resources/forge-update-controller.py",
            "qualification_receipt": "/Applications/Installer.app/Contents/Resources/forge-release-complete-2.7.38.json",
            "qualification_receipt_sha256": "sha256:" + "1" * 64,
            "controller_source": "2" * 40,
            "controller_sha256": "sha256:" + "3" * 64,
            "resolver": "/Library/Forge/bin/forge",
            "resolver_sha256": "sha256:" + "4" * 64,
            "runtime_root": "/Library/Forge/update-runtime",
            "runtime_id": "forge-instance-1",
            "installation_id": "installation-1",
            "peer_configuration_digest": "sha256:" + "5" * 64,
            "existing_interpreter": "/Library/Forge/bin/python3",
            "existing_version": "2.7.37",
            "base_python": "/Library/Forge/base/bin/python3",
            "intent_root": str(self.root),
        }.items()))
        intent = replace(self.intent, binding_snapshot=binding)
        pending = self.store.prepare(intent)
        self.assertEqual(self.store.read(intent.operation_id), pending)
        self.assertEqual(json.loads((self.root / "forge-update-1.json").read_bytes())["schema"],
                         "forge-platform.forge-update-intent/v2")
        invoked = self.store.advance(pending, "UPDATER_INVOKED")
        self.assertEqual(invoked.binding_snapshot, binding)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "identity changed"):
            self.store.prepare(replace(intent, binding_snapshot=tuple(sorted({
                **dict(binding), "peer_configuration_digest": "sha256:" + "6" * 64,
            }.items()))))
        terminal = self.store.advance(invoked, "PRODUCT_COMPLETE", self.receipt)
        self.assertEqual(self.store.advance(terminal, "COMPLETE").binding_snapshot, binding)
        path = self.root / "forge-update-1.json"
        original = path.read_bytes()
        payload = json.loads(original)
        payload["binding_snapshot"]["resolver"] = "../foreign"
        path.write_bytes((json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode())
        with self.assertRaises(ForgeUpdateIntentError):
            self.store.read(intent.operation_id)
        path.write_bytes(original)
        with self.assertRaises(ValueError):
            replace(intent, binding_snapshot=tuple(sorted({
                **dict(binding), "runtime_id": "foreign",
            }.items())))

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "private"
        self.root.mkdir(mode=0o700)
        self.store = ForgeUpdateIntentStore(self.root)
        self.intent = ForgeUpdateIntent(
            "forge-update-1", "a" * 64, "forge-instance-1",
            "sha256:" + "b" * 64, "sha256:" + "c" * 64,
            "forge-update-assess:sha256:" + "d" * 64,
        )
        self.receipt = "forge-update:sha256:" + "e" * 64

    def test_typed_maintenance_preparation_is_not_a_product_intent(self) -> None:
        proof = {"schema": "forge-platform.forge281-maintenance-preparation/v1", "state": "COMPLETE",
            "selection": {"operation_id": "maintenance-1",
                "installed_digest": "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
                "candidate_digest": "sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0"}}
        path = self.root / "maintenance-1.preparation.json"
        original = (json.dumps(proof,sort_keys=True,separators=(",",":"))+"\n").encode()
        path.write_bytes(original);path.chmod(0o600)
        self.assertEqual(self.store.prepare(self.intent).phase,"PREPARED")
        self.assertEqual(path.read_bytes(),original)

    def test_untyped_preparation_file_is_not_silently_skipped(self) -> None:
        path = self.root / "foreign.preparation.json"
        path.write_bytes(b'{"schema":"foreign"}\n');path.chmod(0o600)
        with self.assertRaises(ForgeUpdateIntentError):self.store.prepare(self.intent)
        self.assertIsNone(self.store.read(self.intent.operation_id))

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

    def test_pending_same_instance_blocks_new_operation_but_other_instance_isolated(self) -> None:
        first = self.store.prepare(self.intent)
        second = replace(self.intent, operation_id="forge-update-2", request_fingerprint="f" * 64)
        with self.assertRaisesRegex(ForgeUpdateIntentError, "another pending"):
            self.store.prepare(second)
        other = replace(second, operation_id="forge-update-other", instance_id="forge-instance-2")
        self.assertEqual(self.store.prepare(other), other)
        invoked = self.store.advance(first, "UPDATER_INVOKED")
        terminal = self.store.advance(invoked, "PRODUCT_COMPLETE", self.receipt)
        self.store.advance(terminal, "COMPLETE")
        self.assertEqual(self.store.prepare(second), second)

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
