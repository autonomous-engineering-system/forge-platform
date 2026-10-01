from __future__ import annotations

from unittest import TestCase
from unittest.mock import Mock

from forge_platform.ep_consumer_registration import (
    EPConsumerRegistrationAdapter, EPConsumerRegistrationError,
    EPInitialConsumerRegistrationAdapter,
)
from forge_platform.ep_consumer_revocation import (
    EPConsumerRevocationAdapter, EPConsumerScope,
)


class EPInitialConsumerRegistrationTests(TestCase):
    def setUp(self) -> None:
        self.consumer = Mock(spec=EPConsumerRevocationAdapter)
        self.consumer.scope = EPConsumerScope("consumer-a", "project-a")
        self.consumer.provisioner = Mock()
        self.consumer.provisioner.target.instance_id = "ep-a"
        self.receipt = {
            "consumer_id": "consumer-a", "project_id": "project-a",
            "status": "ACTIVE", "created_at": "2026-10-01 00:00:00",
            "updated_at": "2026-10-01 00:00:00", "idempotent": False,
        }
        self.status = {
            **{key: value for key, value in self.receipt.items() if key != "idempotent"},
            "disabled_at": None, "revoked_at": None,
            "active_production_credentials": 0,
        }
        self.consumer._command.return_value = self.receipt
        self.consumer.status.return_value = self.status
        self.adapter = EPInitialConsumerRegistrationAdapter(self.consumer)

    def test_first_registration_requires_exact_product_receipt_and_readback(self) -> None:
        reference = self.adapter.register()
        self.assertRegex(reference, r"^ep-consumer-register:sha256:[0-9a-f]{64}$")
        self.consumer._command.assert_called_once_with("consumer-register")
        self.consumer.status.assert_called_once_with()

    def test_existing_scope_requires_durable_recovery_authority(self) -> None:
        self.consumer._command.return_value = {**self.receipt, "idempotent": True}
        with self.assertRaises(EPConsumerRegistrationError):
            self.adapter.register()
        self.assertRegex(
            self.adapter.register(recovering=True),
            r"^ep-consumer-register:sha256:[0-9a-f]{64}$",
        )
        with self.assertRaises(TypeError):
            self.adapter.register(recovering=1)  # type: ignore[arg-type]

    def test_wrong_scope_or_receipt_shape_fails_closed(self) -> None:
        for changed in (
            {**self.receipt, "consumer_id": "consumer-b"},
            {**self.receipt, "project_id": "project-b"},
            {**self.receipt, "status": "REVOKED"},
            {**self.receipt, "created_at": ""},
            {**self.receipt, "idempotent": "false"},
            {**self.receipt, "extra": "value"},
        ):
            with self.subTest(changed=changed):
                self.consumer._command.return_value = changed
                with self.assertRaises(EPConsumerRegistrationError):
                    self.adapter.register()

    def test_nonterminal_or_credentialed_readback_fails_closed(self) -> None:
        for changed in (
            {**self.status, "consumer_id": "consumer-b"},
            {**self.status, "created_at": "different"},
            {**self.status, "disabled_at": "2026-10-01 00:00:01"},
            {**self.status, "revoked_at": "2026-10-01 00:00:01"},
            {**self.status, "active_production_credentials": 1},
        ):
            with self.subTest(changed=changed):
                self.consumer.status.return_value = changed
                with self.assertRaises(EPConsumerRegistrationError):
                    self.adapter.register()

    def test_wrong_authority_is_rejected(self) -> None:
        with self.assertRaises(TypeError):
            EPInitialConsumerRegistrationAdapter(object())  # type: ignore[arg-type]


class EPReplacementConsumerRegistrationTests(TestCase):
    def setUp(self) -> None:
        self.old = Mock(spec=EPConsumerRevocationAdapter)
        self.new = Mock(spec=EPConsumerRevocationAdapter)
        authority = Mock()
        authority.target.instance_id = "ep-a"
        self.old.provisioner = self.new.provisioner = authority
        self.old.expected_artifact = self.new.expected_artifact = object()
        self.old.scope = EPConsumerScope("consumer-old", "project-a")
        self.new.scope = EPConsumerScope("consumer-new", "project-a")
        self.old.status.return_value = {
            "status": "REVOKED", "revoked_at": "2026-10-01 00:00:00",
        }
        self.receipt = {
            "consumer_id": "consumer-new", "project_id": "project-a",
            "status": "ACTIVE", "created_at": "2026-10-01 00:01:00",
            "updated_at": "2026-10-01 00:01:00", "idempotent": False,
        }
        self.new._command.return_value = self.receipt
        self.new.status.return_value = {
            **{key: value for key, value in self.receipt.items() if key != "idempotent"},
            "disabled_at": None, "revoked_at": None,
            "active_production_credentials": 0,
        }
        self.adapter = EPConsumerRegistrationAdapter(old=self.old, new=self.new)

    def test_exact_replacement_and_replay(self) -> None:
        first = self.adapter.register()
        self.assertRegex(first, r"^ep-consumer-register:sha256:[0-9a-f]{64}$")
        self.new._command.assert_called_with("consumer-register")
        self.new._command.return_value = {**self.receipt, "idempotent": True}
        self.assertEqual(self.adapter.register(), first)

    def test_old_consumer_must_be_revoked(self) -> None:
        self.old.status.return_value = {"status": "ACTIVE", "revoked_at": None}
        with self.assertRaises(EPConsumerRegistrationError):
            self.adapter.register()
        self.new._command.assert_not_called()

    def test_replacement_receipt_and_readback_must_be_exact(self) -> None:
        for changed in (
            {**self.receipt, "consumer_id": "wrong"},
            {**self.receipt, "project_id": "wrong"},
            {**self.receipt, "status": "REVOKED"},
            {**self.receipt, "created_at": ""},
            {**self.receipt, "updated_at": ""},
            {**self.receipt, "idempotent": "false"},
            {**self.receipt, "extra": 1},
        ):
            with self.subTest(changed=changed):
                self.new._command.return_value = changed
                with self.assertRaises(EPConsumerRegistrationError):
                    self.adapter.register()
        self.new._command.return_value = self.receipt
        original = self.new.status.return_value
        for changed in (
            {**original, "created_at": "wrong"},
            {**original, "disabled_at": "2026-10-01 00:02:00"},
            {**original, "active_production_credentials": 1},
        ):
            with self.subTest(changed=changed):
                self.new.status.return_value = changed
                with self.assertRaises(EPConsumerRegistrationError):
                    self.adapter.register()
        self.new.status.return_value = original
        self.old.status.side_effect = [
            {"status": "REVOKED", "revoked_at": "2026-10-01 00:00:00"},
            {"status": "ACTIVE", "revoked_at": None},
        ]
        with self.assertRaises(EPConsumerRegistrationError):
            self.adapter.register()

    def test_replacement_authorities_must_match(self) -> None:
        with self.assertRaises(TypeError):
            EPConsumerRegistrationAdapter(old=object(), new=self.new)  # type: ignore[arg-type]
        other = Mock(spec=EPConsumerRevocationAdapter)
        other.provisioner = Mock()
        other.expected_artifact = self.new.expected_artifact
        other.scope = self.old.scope
        with self.assertRaises(ValueError):
            EPConsumerRegistrationAdapter(old=other, new=self.new)
