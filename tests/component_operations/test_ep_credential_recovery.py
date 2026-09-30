from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from forge_platform.engineering_platform_system_adapter import ProductCommandResult
from forge_platform.ep_consumer_revocation import EPConsumerRevocationAdapter
from forge_platform.ep_credential_recovery import (
    EPCredentialRecoveryAdapter, EPCredentialRecoveryError,
)


ID = "production-" + "a" * 32
OTHER = "production-" + "b" * 32


def record(identifier=ID, *, active=True, revoked_at=None):
    return {
        "credential_id": identifier, "fingerprint": "a" * 64,
        "purpose": "PRODUCTION_CONSUMER", "created_at": "2026-09-30 12:00:00",
        "expires_at": None, "revoked_at": revoked_at, "active": active,
    }


class EPCredentialRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.consumer = Mock(spec=EPConsumerRevocationAdapter)
        self.consumer.status.return_value = {
            "status": "ACTIVE", "active_production_credentials": 1,
        }
        self.records = [record()]
        self.consumer._command.side_effect = lambda action: self.records
        self.consumer._authority.return_value = (
            Path("/ep/runtimes/current/bin/python"), Path("/ep/instances/A/data/epdata.sqlite"),
            501, 20,
        )
        self.consumer.runner = Mock()
        self.adapter = EPCredentialRecoveryAdapter(self.consumer)

    def test_exact_secret_free_inventory(self) -> None:
        result = self.adapter.status()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].credential_id, ID)
        self.assertTrue(result[0].active)
        self.assertFalse(hasattr(result[0], "credential"))
        self.consumer._command.assert_called_with("credential-status")

    def test_invalid_product_adapter_or_consumer_state_is_closed(self) -> None:
        with self.assertRaises(TypeError):
            EPCredentialRecoveryAdapter(object())
        self.consumer.status.return_value = {"status": "REVOKED"}
        with self.assertRaisesRegex(EPCredentialRecoveryError, "not active"):
            self.adapter.status()
        self.consumer._command.assert_not_called()

    def test_ambiguous_metadata_and_count_are_rejected(self) -> None:
        for records in (
            {}, [record(), record()], [record("wrong")],
            [record() | {"fingerprint": "bad"}],
            [record() | {"purpose": "QUALIFICATION"}],
            [record() | {"active": "true"}],
            [record() | {"revoked_at": "now"}],
            [record() | {"extra": "secret"}],
            [record() | {"created_at": ""}],
            [record() | {"expires_at": 4}],
        ):
            self.records = records
            with self.subTest(records=records), self.assertRaises(EPCredentialRecoveryError):
                self.adapter.status()
        self.records = []
        with self.assertRaisesRegex(EPCredentialRecoveryError, "count"):
            self.adapter.status()

    def test_revoke_exact_and_idempotent_repeat(self) -> None:
        def revoke(argv, **kwargs):
            self.assertEqual(argv[4], "credential-revoke")
            self.assertEqual(argv[-2:], ("--credential-id", ID))
            self.assertEqual(kwargs["database"], Path("/ep/instances/A/data/epdata.sqlite"))
            self.records = [record(active=False, revoked_at="2026-09-30 12:02:00")]
            self.consumer.status.return_value = {
                "status": "ACTIVE", "active_production_credentials": 0,
            }
            return ProductCommandResult(0, json.dumps({
                "credential_id": ID, "revoked": True, "changed": True,
            }), "")

        self.consumer.runner.run.side_effect = revoke
        result = self.adapter.revoke_exact(ID)
        self.assertFalse(result.active)
        self.assertEqual(result.revoked_at, "2026-09-30 12:02:00")
        self.assertEqual(self.adapter.revoke_exact(ID), result)
        self.consumer.runner.run.assert_called_once()

    def test_wrong_or_absent_credential_never_mutates(self) -> None:
        with self.assertRaises(ValueError):
            self.adapter.revoke_exact("production-wrong")
        with self.assertRaisesRegex(EPCredentialRecoveryError, "absent"):
            self.adapter.revoke_exact(OTHER)
        self.consumer.runner.run.assert_not_called()

    def test_bad_receipt_and_lost_response_fail_closed(self) -> None:
        for response in (
            ProductCommandResult(2, "", "secret diagnostic"),
            ProductCommandResult(0, "bad", ""),
            ProductCommandResult(0, json.dumps({"credential_id": OTHER, "revoked": True, "changed": True}), ""),
            ProductCommandResult(0, json.dumps({"credential_id": ID, "revoked": True, "changed": False}), ""),
        ):
            self.consumer.runner.run.return_value = response
            with self.subTest(response=response.returncode), self.assertRaisesRegex(
                EPCredentialRecoveryError, "receipt"
            ) as failure:
                self.adapter.revoke_exact(ID)
            self.assertNotIn("secret diagnostic", str(failure.exception))

    def test_lost_revoke_response_resumes_from_product_status(self) -> None:
        def lost(argv, **kwargs):
            self.records = [record(active=False, revoked_at="2026-09-30 12:02:00")]
            self.consumer.status.return_value = {
                "status": "ACTIVE", "active_production_credentials": 0,
            }
            return ProductCommandResult(2, "", "private diagnostic")

        self.consumer.runner.run.side_effect = lost
        with self.assertRaisesRegex(EPCredentialRecoveryError, "receipt") as failure:
            self.adapter.revoke_exact(ID)
        self.assertNotIn("private diagnostic", str(failure.exception))
        self.assertEqual(self.adapter.revoke_exact(ID).revoked_at, "2026-09-30 12:02:00")
        self.consumer.runner.run.assert_called_once()

    def test_terminal_target_or_sibling_drift_fails_closed(self) -> None:
        self.records = [record(), record(OTHER, active=False, revoked_at="earlier")]

        def revoke(argv, **kwargs):
            self.records = [
                record(active=False, revoked_at="now"),
                record(OTHER, active=False, revoked_at="changed"),
            ]
            self.consumer.status.return_value = {
                "status": "ACTIVE", "active_production_credentials": 0,
            }
            return ProductCommandResult(0, json.dumps({
                "credential_id": ID, "revoked": True, "changed": True,
            }), "")

        self.consumer.runner.run.side_effect = revoke
        with self.assertRaisesRegex(EPCredentialRecoveryError, "readback"):
            self.adapter.revoke_exact(ID)
        self.records = [record()]
        self.consumer.status.return_value = {"status": "ACTIVE", "active_production_credentials": 1}

        def unchanged(argv, **kwargs):
            return ProductCommandResult(0, json.dumps({
                "credential_id": ID, "revoked": True, "changed": True,
            }), "")

        self.consumer.runner.run.side_effect = unchanged
        with self.assertRaisesRegex(EPCredentialRecoveryError, "readback"):
            self.adapter.revoke_exact(ID)


if __name__ == "__main__":
    unittest.main()
