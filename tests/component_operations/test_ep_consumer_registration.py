from __future__ import annotations

from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from forge_platform.ep_consumer_registration import (
    EPConsumerRegistrationAdapter, EPConsumerRegistrationError,
)
from forge_platform.ep_consumer_revocation import (
    EPConsumerRevocationAdapter, EPConsumerScope,
)


class EPConsumerRegistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.product = SimpleNamespace(target=SimpleNamespace(instance_id="ep-A"))
        self.old = Mock(spec=EPConsumerRevocationAdapter)
        self.new = Mock(spec=EPConsumerRevocationAdapter)
        self.old.provisioner = self.new.provisioner = self.product
        self.old.expected_artifact = self.new.expected_artifact = object()
        self.old.scope = EPConsumerScope("old-A", "project-A")
        self.new.scope = EPConsumerScope("new-A", "project-A")
        self.old.status.return_value = {
            "consumer_id": "old-A", "project_id": "project-A",
            "status": "REVOKED", "revoked_at": "2026-09-30 12:00:00",
            "active_production_credentials": 0,
        }
        self.new._command.return_value = {
            "consumer_id": "new-A", "project_id": "project-A",
            "status": "ACTIVE", "created_at": "2026-09-30 12:01:00",
            "updated_at": "2026-09-30 12:01:00", "idempotent": False,
        }
        self.new.status.return_value = {
            "consumer_id": "new-A", "project_id": "project-A",
            "status": "ACTIVE", "created_at": "2026-09-30 12:01:00",
            "updated_at": "2026-09-30 12:01:00", "disabled_at": None,
            "revoked_at": None, "active_production_credentials": 0,
        }

    def adapter(self) -> EPConsumerRegistrationAdapter:
        return EPConsumerRegistrationAdapter(old=self.old, new=self.new)

    def test_new_consumer_registers_with_exact_terminal_readback(self) -> None:
        adapter = self.adapter()
        evidence = adapter.register()
        self.assertRegex(evidence, r"^ep-consumer-register:sha256:[0-9a-f]{64}$")
        self.assertEqual(evidence, adapter.register())
        self.new._command.assert_called_with("consumer-register")
        self.assertEqual(self.old.status.call_count, 4)

    def test_wrong_instance_artifact_or_scope_blocks_before_mutation(self) -> None:
        for field, value in (
            ("provisioner", object()),
            ("expected_artifact", object()),
            ("scope", EPConsumerScope("new-A", "project-B")),
            ("scope", EPConsumerScope("old-A", "project-A")),
        ):
            with self.subTest(field=field, value=value):
                previous = getattr(self.new, field)
                setattr(self.new, field, value)
                with self.assertRaisesRegex(ValueError, "exact product"):
                    self.adapter()
                setattr(self.new, field, previous)
        self.new._command.assert_not_called()

    def test_concrete_product_adapter_is_required(self) -> None:
        with self.assertRaises(TypeError):
            EPConsumerRegistrationAdapter(old=object(), new=self.new)
        with self.assertRaises(TypeError):
            EPConsumerRegistrationAdapter(old=self.old, new=object())

    def test_old_consumer_must_be_terminal_before_registration(self) -> None:
        for value in ({"status": "ACTIVE"}, {"status": "REVOKED"}):
            self.old.status.return_value = value
            with self.subTest(value=value), self.assertRaises(EPConsumerRegistrationError):
                self.adapter().register()
        self.new._command.assert_not_called()

    def test_registration_receipt_must_be_exact(self) -> None:
        original = self.new._command.return_value
        changes = (
            {"consumer_id": "new-B"}, {"project_id": "project-B"},
            {"status": "REVOKED"}, {"created_at": ""},
            {"updated_at": None}, {"idempotent": "false"},
            {"extra": "unexpected"},
        )
        for change in changes:
            self.new._command.return_value = original | change
            with self.subTest(change=change), self.assertRaisesRegex(
                EPConsumerRegistrationError, "receipt"
            ):
                self.adapter().register()
        self.new._command.return_value = None
        with self.assertRaises(EPConsumerRegistrationError):
            self.adapter().register()
        self.new.status.assert_not_called()

    def test_new_or_old_status_drift_fails_closed(self) -> None:
        original = self.new.status.return_value
        for change in (
            {"status": "REVOKED"}, {"created_at": "wrong"},
            {"updated_at": "wrong"}, {"disabled_at": "now"},
            {"revoked_at": "now"}, {"active_production_credentials": 1},
        ):
            self.new.status.return_value = original | change
            with self.subTest(change=change), self.assertRaisesRegex(
                EPConsumerRegistrationError, "readback"
            ):
                self.adapter().register()
        self.new.status.return_value = original
        self.old.status.side_effect = [self.old.status.return_value, {"status": "ACTIVE"}]
        with self.assertRaisesRegex(EPConsumerRegistrationError, "readback"):
            self.adapter().register()


if __name__ == "__main__":
    unittest.main()
