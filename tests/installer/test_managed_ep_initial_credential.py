from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from forge_platform.ep_consumer_registration import (
    EPConsumerRegistrationError, EPInitialConsumerRegistrationAdapter,
)
from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.ep_credential_recovery import (
    EPCredentialMetadata, EPCredentialRecoveryAdapter,
)
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentRegistry,
    ManagedPeerBinding,
)
from forge_platform.managed_ep_initial_credential import (
    ManagedEPInitialCredentialCoordinator, ManagedEPInitialCredentialError,
)
from forge_platform.managed_install_flow import InstallerMutationCurrencyGuard


DOMAIN = b"engineering-platform.local-api.fingerprint.v1\0"
REFERENCE = "keychain://forge.ep/deployment-a"
TOKEN_A = "A" * 48
TOKEN_B = "B" * 48
ID_A = "production-" + "a" * 32
ID_B = "production-" + "b" * 32


def fingerprint(token: str) -> str:
    return sha256(DOMAIN + token.encode()).hexdigest()


class Store:
    def __init__(self) -> None:
        self.material: str | None = None
        self.owner: str | None = None
        self.clear_count = 0
        self.verify = True

    def fingerprint(self, reference: str, operation_id: str) -> str | None:
        assert reference == REFERENCE
        return fingerprint(self.material) if self.material is not None else None

    def clear_owned(self, reference: str, operation_id: str) -> None:
        assert reference == REFERENCE
        if self.owner not in {None, operation_id}:
            raise ValueError("wrong owner")
        self.material = None
        self.owner = None
        self.clear_count += 1

    def put_verified(self, reference: str, operation_id: str, material: str) -> bool:
        assert reference == REFERENCE
        self.material = material
        self.owner = operation_id
        return self.verify


class InitialCredentialTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "operations"
        self.deployment = ManagedDeployment(
            "deployment-a", 1, "A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep"),
            ),
        )
        self.reviewed_fingerprint = "sha256:" + sha256(json.dumps(
            asdict(self.deployment), sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()
        self.registry = Mock(spec=ManagedDeploymentRegistry)
        self.registry.load.return_value = self.deployment
        self.guard = Mock(spec=InstallerMutationCurrencyGuard)
        self.registration = Mock(spec=EPInitialConsumerRegistrationAdapter)
        self.registration.consumer = Mock()
        self.registration.consumer.scope = EPConsumerScope("consumer-a", "project-a")
        self.registration.consumer.provisioner.target.instance_id = "ep-a"
        self.registration.consumer.status.return_value = {
            "status": "ACTIVE", "consumer_id": "consumer-a", "project_id": "project-a",
            "disabled_at": None, "revoked_at": None,
        }
        self.registration.register.return_value = "ep-consumer-register:sha256:" + "a" * 64
        self.recovery = Mock(spec=EPCredentialRecoveryAdapter)
        self.recovery.consumer = self.registration.consumer
        self.credentials: list[EPCredentialMetadata] = []
        self.recovery.status.side_effect = lambda: tuple(self.credentials)
        self.store = Store()
        self.issued = 0

        def issue(action: str) -> dict[str, str]:
            self.assertEqual(action, "credential-issue")
            self.issued += 1
            identifier, token = (ID_A, TOKEN_A) if self.issued == 1 else (ID_B, TOKEN_B)
            self.credentials.append(EPCredentialMetadata(
                identifier, fingerprint(token), "2026-10-01 00:00:00", None, None, True,
            ))
            return {
                "credential_id": identifier, "consumer_id": "consumer-a",
                "project_id": "project-a", "purpose": "PRODUCTION_CONSUMER",
                "created_at": "2026-10-01 00:00:00", "credential": token,
            }

        self.registration.consumer._command.side_effect = issue

        def revoke(identifier: str) -> None:
            self.credentials = [
                replace(item, active=False, revoked_at="2026-10-01 00:01:00")
                if item.credential_id == identifier else item
                for item in self.credentials
            ]

        self.recovery.revoke_exact.side_effect = revoke
        self.coordinator = ManagedEPInitialCredentialCoordinator(
            operations_root=self.root, registry=self.registry,
            currency_guard=self.guard, registration=self.registration,
            recovery=self.recovery, store=self.store,
            scope_claims={"deployment-a": EPConsumerScope("consumer-a", "project-a")},
            reference_claims={"deployment-a": REFERENCE},
            expected_owner_uid=os.getuid(),
        )

    def issue(self, **changes):
        return self.coordinator.issue(**({
            "operation_id": "install-a", "reviewed_current": self.deployment,
            "reviewed_fingerprint": self.reviewed_fingerprint,
            "credential_reference": REFERENCE,
        } | changes))

    def test_issue_terminal_replay_and_secret_free_journal(self) -> None:
        first = self.issue()
        self.assertEqual(first.state, "COMPLETE")
        self.assertEqual(first.credential_fingerprint, fingerprint(TOKEN_A))
        self.assertEqual(self.issue(), first)
        self.assertEqual(self.issued, 1)
        self.registration.register.assert_called_once_with(recovering=False)
        self.assertNotIn(TOKEN_A, (self.root / "install-a.json").read_text())
        self.assertEqual(self.store.material, TOKEN_A)
        self.assertGreaterEqual(self.guard.require_current.call_count, 3)
        paired = replace(self.deployment, peer_binding=ManagedPeerBinding(
            "forge-a", "ep-a", "receipt:pairing",
        ))
        self.assertEqual(self.coordinator.read_terminal(
            operation_id="install-a", deployment=paired,
        ), first)
        self.assertEqual(self.coordinator.read_terminal(
            operation_id=None, deployment=paired,
        ), first)
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "another operation"):
            self.issue(operation_id="different-install")
        self.registry.load.return_value = None
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "deployment changed"):
            self.issue()

    def test_lost_registration_response_replays_only_same_journal(self) -> None:
        self.registration.register.side_effect = ValueError("lost")
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "response is unavailable"):
            self.issue()
        self.registration.register.side_effect = None
        record = self.issue()
        self.assertEqual(record.state, "COMPLETE")
        self.registration.register.assert_called_with(recovering=True)
        self.assertEqual(self.issued, 1)

    def test_ensure_reuses_exact_terminal_credential_and_rejects_other_pending_operation(self) -> None:
        arguments = {
            "reviewed_current": self.deployment,
            "reviewed_fingerprint": self.reviewed_fingerprint,
            "credential_reference": REFERENCE,
        }
        first = self.coordinator.ensure(operation_id="install-a", **arguments)
        self.assertEqual(
            self.coordinator.ensure(operation_id="install-b", **arguments), first,
        )
        self.assertEqual(self.issued, 1)

        (self.root / "install-a.json").unlink()
        self.store.material = None
        self.credentials = []
        self.registration.register.side_effect = ValueError("lost")
        with self.assertRaises(ManagedEPInitialCredentialError):
            self.coordinator.ensure(operation_id="install-a", **arguments)
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "another operation"):
            self.coordinator.ensure(operation_id="install-b", **arguments)

    def test_preexisting_or_malformed_registration_blocks_replay(self) -> None:
        self.registration.register.side_effect = EPConsumerRegistrationError("already exists")
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "receipt is unsafe"):
            self.issue()
        self.registration.register.side_effect = None
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "blocked"):
            self.issue()
        self.assertEqual(self.issued, 0)

    def test_lost_issue_response_revokes_uncertain_product_credential(self) -> None:
        original = self.registration.consumer._command.side_effect

        def lost(action: str):
            original(action)
            raise ValueError("response lost")

        self.registration.consumer._command.side_effect = lost
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "response is unavailable"):
            self.issue()
        self.registration.consumer._command.side_effect = original
        complete = self.issue()
        self.assertEqual(complete.credential_id, ID_B)
        self.assertFalse(self.credentials[0].active)
        self.assertTrue(self.credentials[1].active)
        self.recovery.revoke_exact.assert_called_once_with(ID_A)
        self.assertEqual(self.registration.register.call_count, 1)

    def test_crash_after_store_write_clears_and_reissues(self) -> None:
        from forge_platform import managed_ep_initial_credential as module

        original = module._write
        writes = 0

        def interrupted(path, record):
            nonlocal writes
            writes += 1
            if writes == 3:
                raise OSError("interrupted")
            return original(path, record)

        with patch.object(module, "_write", side_effect=interrupted):
            with self.assertRaisesRegex(ManagedEPInitialCredentialError, "secure readback"):
                self.issue()
        self.assertEqual(self.store.material, TOKEN_A)
        complete = self.issue()
        self.assertEqual(complete.credential_id, ID_B)
        self.assertGreaterEqual(self.store.clear_count, 2)

    def test_target_currency_and_store_drift_fail_closed(self) -> None:
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "target changed"):
            self.issue(credential_reference="keychain://forge.ep/wrong")
        self.registry.load.return_value = None
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "deployment changed"):
            self.issue()
        self.registry.load.return_value = self.deployment
        self.store.material = TOKEN_B
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "occupied"):
            self.issue()
        self.store.material = None
        self.guard.require_current.side_effect = ValueError("stale")
        with self.assertRaisesRegex(ValueError, "stale"):
            self.issue()
        self.registration.register.assert_not_called()

    def test_invalid_issue_receipt_and_terminal_readback_fail_closed(self) -> None:
        original = self.registration.consumer._command.side_effect

        def wrong(action: str):
            return {**original(action), "consumer_id": "other"}

        self.registration.consumer._command.side_effect = wrong
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "secure readback"):
            self.issue()
        self.registration.consumer._command.side_effect = original
        complete = self.issue()
        self.assertEqual(complete.credential_id, ID_B)
        self.store.material = None
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "terminal initial"):
            self.coordinator.read_terminal(
                operation_id="install-a", deployment=self.deployment,
            )

    def test_journal_tamper_symlink_and_wrong_terminal_target(self) -> None:
        self.issue()
        wrong = replace(self.deployment, deployment_id="deployment-b")
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "target changed"):
            self.coordinator.read_terminal(operation_id="install-a", deployment=wrong)
        wrong_peer = replace(self.deployment, peer_binding=ManagedPeerBinding(
            "forge-a", "ep-a", "receipt:pairing",
        ))
        object.__setattr__(wrong_peer, "peer_binding", ManagedPeerBinding(
            "other", "ep-a", "receipt:wrong",
        ))
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "target changed"):
            self.coordinator.read_terminal(operation_id="install-a", deployment=wrong_peer)
        path = self.root / "install-a.json"
        path.write_text('{"tampered":true}')
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "journal is invalid"):
            self.issue()
        path.write_text('{"state":"COMPLETE","state":"PREPARED"}')
        with self.assertRaisesRegex(ManagedEPInitialCredentialError, "journal is invalid"):
            self.issue()
        path.unlink()
        path.symlink_to(self.root / "missing.json")
        with self.assertRaises(ManagedEPInitialCredentialError):
            self.issue()

    def test_cross_deployment_claims_and_constructor_fail_closed(self) -> None:
        with self.assertRaises(ValueError):
            ManagedEPInitialCredentialCoordinator(
                operations_root=self.root, registry=self.registry,
                currency_guard=self.guard, registration=self.registration,
                recovery=self.recovery, store=self.store,
                scope_claims={"deployment-a": EPConsumerScope("consumer-a", "project-a"),
                              "deployment-b": EPConsumerScope("consumer-a", "project-a")},
                reference_claims={"deployment-a": REFERENCE,
                                  "deployment-b": "keychain://forge.ep/other"},
                expected_owner_uid=os.getuid(),
            )
        with self.assertRaises(TypeError):
            ManagedEPInitialCredentialCoordinator(
                operations_root=Path("relative"), registry=self.registry,
                currency_guard=self.guard, registration=self.registration,
                recovery=self.recovery, store=self.store,
                scope_claims={"deployment-a": EPConsumerScope("consumer-a", "project-a")},
                reference_claims={"deployment-a": REFERENCE},
            )
