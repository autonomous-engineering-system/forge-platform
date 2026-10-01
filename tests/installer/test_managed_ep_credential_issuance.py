from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from forge_platform.ep_consumer_registration import EPConsumerRegistrationAdapter
from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.ep_credential_recovery import (
    EPCredentialMetadata, EPCredentialRecoveryAdapter,
)
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentRegistry,
    ManagedPeerBinding,
)
from forge_platform.managed_ep_credential_issuance import (
    ManagedEPCredentialIssuanceCoordinator, ManagedEPCredentialIssuanceError,
)
from forge_platform.managed_install_flow import InstallerMutationCurrencyGuard


DOMAIN = b"engineering-platform.local-api.fingerprint.v1\0"
REFERENCE = "keychain://forge.ep/deployment-A-new"
TOKEN_A = "A" * 48
TOKEN_B = "B" * 48
ID_A = "production-" + "a" * 32
ID_B = "production-" + "b" * 32


def fingerprint(token):
    return sha256(DOMAIN + token.encode()).hexdigest()


class Store:
    def __init__(self):
        self.material = None
        self.owner = None
        self.clear_count = 0
        self.verify = True

    def clear_owned(self, reference, operation_id):
        assert reference == REFERENCE
        if self.owner not in {None, operation_id}:
            raise ValueError("wrong owner")
        self.material = None
        self.owner = None
        self.clear_count += 1

    def put_verified(self, reference, operation_id, material):
        assert reference == REFERENCE
        self.material = material
        self.owner = operation_id
        return self.verify

    def fingerprint(self, reference, operation_id):
        assert reference == REFERENCE
        return fingerprint(self.material) if self.material is not None else None


class EPCredentialIssuanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / "operations"
        self.deployment = ManagedDeployment(
            "deployment-a", 1, "A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep"),
            ), ManagedPeerBinding("forge-a", "ep-a", "receipt:pairing"),
        )
        self.reviewed_fingerprint = "sha256:" + sha256(json.dumps(
            asdict(self.deployment), sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()
        self.registry = Mock(spec=ManagedDeploymentRegistry)
        self.registry.load.return_value = self.deployment
        self.guard = Mock(spec=InstallerMutationCurrencyGuard)
        self.registration = Mock(spec=EPConsumerRegistrationAdapter)
        self.registration.old = Mock()
        self.registration.new = Mock()
        self.registration.old.scope = EPConsumerScope("old-A", "project-A")
        self.registration.new.scope = EPConsumerScope("new-A", "project-A")
        self.registration.new.provisioner.target.instance_id = "ep-a"
        self.registration.old.status.return_value = {
            "status": "REVOKED", "revoked_at": "2026-09-30 11:00:00",
        }
        self.registration.new.status.return_value = {
            "status": "ACTIVE", "consumer_id": "new-A", "project_id": "project-A",
        }
        self.recovery = Mock(spec=EPCredentialRecoveryAdapter)
        self.recovery.consumer = self.registration.new
        self.credentials = []
        self.recovery.status.side_effect = lambda: tuple(self.credentials)
        self.store = Store()
        self.issued = 0

        def issue(action):
            self.assertEqual(action, "credential-issue")
            self.issued += 1
            identifier, token = (ID_A, TOKEN_A) if self.issued == 1 else (ID_B, TOKEN_B)
            self.credentials.append(EPCredentialMetadata(
                identifier, fingerprint(token), "2026-09-30 12:00:00", None, None, True,
            ))
            return {
                "credential_id": identifier, "consumer_id": "new-A",
                "project_id": "project-A", "purpose": "PRODUCTION_CONSUMER",
                "created_at": "2026-09-30 12:00:00", "credential": token,
            }

        self.registration.new._command.side_effect = issue

        def revoke(identifier):
            self.credentials = [
                replace(item, active=False, revoked_at="2026-09-30 12:01:00")
                if item.credential_id == identifier else item
                for item in self.credentials
            ]

        self.recovery.revoke_exact.side_effect = revoke
        self.coordinator = ManagedEPCredentialIssuanceCoordinator(
            operations_root=self.root, registry=self.registry,
            currency_guard=self.guard, registration=self.registration,
            recovery=self.recovery, store=self.store,
            scope_claims={"deployment-a": EPConsumerScope("new-A", "project-A")},
            reference_claims={"deployment-a": REFERENCE},
            expected_owner_uid=os.getuid(),
        )

    def run_issue(self, **changes):
        arguments = {
            "operation_id": "repair-A", "reviewed_current": self.deployment,
            "reviewed_fingerprint": self.reviewed_fingerprint,
            "credential_reference": REFERENCE,
        } | changes
        return self.coordinator.issue(**arguments)

    def test_exact_issue_and_terminal_replay_keep_secret_out_of_journal(self):
        first = self.run_issue()
        self.assertEqual(first.state, "COMPLETE")
        self.assertEqual(first.credential_id, ID_A)
        self.assertEqual(first.credential_fingerprint, fingerprint(TOKEN_A))
        self.assertEqual(self.run_issue(), first)
        self.assertEqual(self.issued, 1)
        self.registration.register.assert_called_once()
        raw = (self.root / "repair-A.json").read_text()
        self.assertNotIn(TOKEN_A, raw)
        self.assertNotIn("credential\":", raw)
        self.assertEqual(self.store.material, TOKEN_A)
        self.assertGreaterEqual(self.guard.require_current.call_count, 3)

    def test_terminal_readback_survives_registry_commit_without_reissue(self):
        issued = self.run_issue()
        self.registry.load.return_value = None
        self.assertEqual(self.coordinator.read_terminal(
            operation_id="repair-A", reviewed_current=self.deployment,
            credential_reference=REFERENCE,
        ), issued)
        self.assertEqual(self.issued, 1)

    def test_terminal_readback_rejects_scope_store_and_journal_drift(self):
        self.run_issue()
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "selector"):
            self.coordinator.read_terminal(
                operation_id="repair-A", reviewed_current=self.deployment,
                credential_reference="keychain://forge.ep/other",
            )
        self.registration.old.status.return_value = {"status": "ACTIVE"}
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "consumer status"):
            self.coordinator.read_terminal(
                operation_id="repair-A", reviewed_current=self.deployment,
                credential_reference=REFERENCE,
            )
        self.registration.old.status.return_value = {
            "status": "REVOKED", "revoked_at": "2026-09-30 11:00:00",
        }
        self.store.material = TOKEN_B
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "secure store changed"):
            self.coordinator.read_terminal(
                operation_id="repair-A", reviewed_current=self.deployment,
                credential_reference=REFERENCE,
            )
        (self.root / "repair-A.json").write_text('{"changed":true}')
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "journal is invalid"):
            self.coordinator.read_terminal(
                operation_id="repair-A", reviewed_current=self.deployment,
                credential_reference=REFERENCE,
            )

    def test_lost_issue_response_revokes_uncertain_id_on_replay(self):
        original = self.registration.new._command.side_effect

        def lost(action):
            original(action)
            raise ValueError("secret response is unavailable")

        self.registration.new._command.side_effect = lost
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "response is unavailable") as failure:
            self.run_issue()
        self.assertNotIn("secret", str(failure.exception))
        self.registration.new._command.side_effect = original
        final = self.run_issue()
        self.assertEqual(final.credential_id, ID_B)
        self.assertFalse(self.credentials[0].active)
        self.assertTrue(self.credentials[1].active)
        self.recovery.revoke_exact.assert_called_once_with(ID_A)
        self.assertEqual(self.issued, 2)
        self.registration.register.assert_called_once()

    def test_crash_after_secure_store_put_cleans_and_reissues(self):
        from forge_platform import managed_ep_credential_issuance as module

        original = module._write
        calls = 0

        def interrupted(path, record):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("interrupted after secure store")
            return original(path, record)

        with patch.object(module, "_write", side_effect=interrupted):
            with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "secure readback"):
                self.run_issue()
        self.assertEqual(self.store.material, TOKEN_A)
        final = self.run_issue()
        self.assertEqual(final.credential_id, ID_B)
        self.assertEqual(self.store.material, TOKEN_B)
        self.assertFalse(self.credentials[0].active)
        self.assertGreaterEqual(self.store.clear_count, 2)

    def test_stale_registry_or_currency_blocks_product_mutation(self):
        self.registry.load.return_value = None
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "deployment changed"):
            self.run_issue()
        self.registry.load.return_value = self.deployment
        self.guard.require_current.side_effect = ValueError("stale")
        with self.assertRaisesRegex(ValueError, "stale"):
            self.run_issue()
        self.assertEqual(self.issued, 0)

    def test_wrong_review_or_occupied_store_blocks_issue(self):
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "target changed"):
            self.run_issue(reviewed_fingerprint="sha256:" + "0" * 64)
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "target changed"):
            self.run_issue(credential_reference="keychain://other bad")
        self.store.material = TOKEN_A
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "occupied"):
            self.run_issue()
        self.assertEqual(self.issued, 0)

    def test_cross_deployment_scope_or_reference_reuse_is_rejected(self):
        arguments = {
            "operations_root": self.root, "registry": self.registry,
            "currency_guard": self.guard, "registration": self.registration,
            "recovery": self.recovery, "store": self.store,
            "expected_owner_uid": os.getuid(),
        }
        for scopes, references in (
            ({"deployment-a": EPConsumerScope("new-A", "project-A"),
              "deployment-b": EPConsumerScope("new-A", "project-A")},
             {"deployment-a": REFERENCE, "deployment-b": "keychain://forge.ep/deployment-b"}),
            ({"deployment-a": EPConsumerScope("new-A", "project-A"),
              "deployment-b": EPConsumerScope("new-B", "project-A")},
             {"deployment-a": REFERENCE, "deployment-b": REFERENCE}),
        ):
            with self.subTest(scopes=scopes), self.assertRaisesRegex(ValueError, "exclusively owned"):
                ManagedEPCredentialIssuanceCoordinator(
                    **arguments, scope_claims=scopes, reference_claims=references,
                )
        self.coordinator.scope_claims["deployment-a"] = EPConsumerScope("other", "project-A")
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "target changed"):
            self.run_issue()
        self.assertEqual(self.issued, 0)

    def test_secure_store_diagnostic_is_redacted(self):
        self.store.fingerprint = Mock(side_effect=RuntimeError(TOKEN_A))
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "secure reference status") as failure:
            self.run_issue()
        self.assertNotIn(TOKEN_A, str(failure.exception))
        self.assertEqual(self.issued, 0)

    def test_unbounded_product_credential_history_blocks_before_issue(self):
        self.credentials = [EPCredentialMetadata(
            f"production-{number:032x}", "a" * 64,
            "2026-09-30 11:00:00", None, "2026-09-30 11:30:00", False,
        ) for number in range(65)]
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "history is unsafe"):
            self.run_issue()
        self.assertEqual(self.issued, 0)
        self.assertFalse((self.root / "repair-A.json").exists())

    def test_bad_disclosure_or_store_verification_leaves_recoverable_prepared(self):
        self.registration.new._command.side_effect = lambda action: {
            "credential_id": ID_A, "consumer_id": "wrong", "project_id": "project-A",
            "purpose": "PRODUCTION_CONSUMER", "created_at": "now",
            "credential": TOKEN_A,
        }
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "secure readback"):
            self.run_issue()
        self.assertEqual(self.issued, 0)
        self.registration.new._command.side_effect = None
        self.registration.new._command.return_value = {
            "credential_id": ID_A, "consumer_id": "new-A", "project_id": "project-A",
            "purpose": "PRODUCTION_CONSUMER", "created_at": "2026-09-30 12:00:00",
            "credential": TOKEN_A,
        }
        self.credentials = [EPCredentialMetadata(
            ID_A, fingerprint(TOKEN_A), "2026-09-30 12:00:00", None, None, True,
        )]
        self.store.verify = False
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "secure readback"):
            self.run_issue()

    def test_tampered_or_symlinked_journal_fails_closed(self):
        self.run_issue()
        path = self.root / "repair-A.json"
        path.write_text("{}")
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "journal is invalid"):
            self.run_issue()
        path.unlink()
        path.symlink_to(self.root / "elsewhere")
        with self.assertRaisesRegex(ManagedEPCredentialIssuanceError, "journal is invalid"):
            self.run_issue()


if __name__ == "__main__":
    unittest.main()
