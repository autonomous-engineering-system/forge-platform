from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding, ForgeEPProductPairingExecutor,
)
from forge_platform.forge_server_adapter import ForgeServerProductAdapter
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_ep_credential_issuance import EPCredentialIssueRecord
from forge_platform.managed_pairing import ManagedPairingEvidence
from forge_platform.managed_pairing_detach import (
    ManagedPairingRepairDetachCoordinator, PairingDetachRecord,
)
from forge_platform.managed_pairing_repair_credential import ManagedPairingRepairCredentialCoordinator
from forge_platform.managed_pairing_repair_execution import (
    ManagedPairingRepairExecutionCoordinator, ManagedPairingRepairExecutionError,
)


def digest(value):
    return "sha256:" + sha256(json.dumps(
        asdict(value), sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode()).hexdigest()


DETACH_OPERATION = "peer-repair-detach-" + sha256(b"repair-a").hexdigest()[:40]


class RepairExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.current = ManagedDeployment(
            "deployment-a", 1, "Paired A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge-a"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ), ManagedPeerBinding("forge-a", "ep-a", "receipt:old"),
        )
        self.sibling = ManagedDeployment(
            "deployment-b", 1, "Paired B", (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
                ManagedComponentBinding("engineering-platform-server", "ep-b", "receipt:ep-b"),
            ), ManagedPeerBinding("forge-b", "ep-b", "receipt:other"),
        )
        self.registry = ManagedDeploymentRegistry(self.root / "registry")
        self.registry.create(self.current)
        self.registry.create(self.sibling)
        desired = replace(
            self.current, revision=2,
            peer_binding=ManagedPeerBinding("forge-a", "ep-a", "receipt:new"),
        )
        self.plan = ManagedDeploymentPlanner.plan(
            self.current, desired,
            product_actions={"forge-runtime": "REPAIR", "engineering-platform-server": "NO_CHANGE"},
        )
        self.old = ForgeEPProductPairingBinding(
            "old-binding", "http://127.0.0.1:9001", "ep-a", "old-consumer",
            "host-a", "project-a", "repo-a", "owner:repo",
            "keychain://forge.ep/old", "operator-a", True,
        )
        self.new = replace(
            self.old, binding_id="new-binding", consumer_id="new-consumer",
            credential_reference="keychain://forge.ep/new",
        )
        self.guard = Mock()
        self.guard.require_current.return_value = "currency:exact"
        self.credential = Mock(spec=ManagedPairingRepairCredentialCoordinator)
        self.credential.issuance = Mock()
        self.credential.issuance.registry = self.registry
        self.credential.issuance.currency_guard = self.guard
        self.credential.issuance.operations_root = self.root / "issue"
        self.credential.revocation = Mock()
        self.credential.revocation.operations_root = self.root / "revoke"
        self.credential.issue_after_revoke.return_value = EPCredentialIssueRecord(
            "repair-a", "deployment-a", "forge-a", "ep-a", "old-consumer",
            "new-consumer", "project-a", self.new.credential_reference,
            digest(self.current), (), "COMPLETE", "production-" + "a" * 32,
            "b" * 64, "2026-10-01T00:00:00Z",
        )
        self.credential.issuance.read_terminal.return_value = (
            self.credential.issue_after_revoke.return_value
        )
        self.detach = Mock(spec=ManagedPairingRepairDetachCoordinator)
        self.detach.registry = self.registry
        self.detach.currency_guard = self.guard
        self.detach.operations_root = self.root / "detach"
        self.detach.repair_detach.return_value = PairingDetachRecord(
            "repair-a", DETACH_OPERATION, "deployment-a", digest(self.plan),
            digest(self.current), "forge-a", "ep-a", "old-binding", "old-consumer",
            "operator-a", 3, "sha256:" + "c" * 64, "COMPLETE", "sha256:" + "d" * 64,
        )
        self.forge = Mock(spec=ForgeServerProductAdapter)
        self.forge.target = Mock()
        self.forge.target.instance_id = "forge-a"
        self.ep = Mock(spec=EngineeringPlatformSystemProvisionerAdapter)
        self.ep.target = Mock()
        self.ep.target.instance_id = "ep-a"
        self.artifact = QualifiedArtifact(
            "2.7.39", "a" * 40, "released-wheel", "sha256:" + "e" * 64, "qualified",
        )
        self.forge_request = ComponentOperationRequest(
            "read-forge", "forge-runtime", "repair", self.artifact,
            "forge-a", "server", {},
        )
        self.ep_request = ComponentOperationRequest(
            "read-ep", "engineering-platform-server", "repair", self.artifact,
            "ep-a", "server", {},
        )
        self.revoker = Mock()
        self.revoker.scope = EPConsumerScope("old-consumer", "project-a")
        self.evidence = ManagedPairingEvidence(
            "forge-a", "ep-a", "forge-peer-configuration:sha256:" + "1" * 64,
            "forge-peer-preflight:sha256:" + "2" * 64,
            "ep-status:sha256:" + "3" * 64,
        )
        self.forge.read_detach_ep_peer.return_value = {
            "current_peer_status": "DETACHED",
            "receipt": {"receipt_digest": "sha256:" + "d" * 64},
        }
        self.forge.read_historical_detach_ep_peer.return_value = {
            "current_peer_status": "CONFIGURED",
            "receipt": {"receipt_digest": "sha256:" + "d" * 64},
        }
        self.coordinator = ManagedPairingRepairExecutionCoordinator(
            operations_root=self.root / "repair", registry=self.registry,
            currency_guard=self.guard, credential=self.credential,
            detach=self.detach, expected_owner_uid=os.getuid(),
        )

    def run_replace(self, **changes):
        arguments = dict(
            operation_id="repair-a", plan=self.plan, reviewed_current=self.current,
            old_binding=self.old, new_binding=self.new, revoker=self.revoker,
            forge_adapter=self.forge, ep_adapter=self.ep,
            forge_request=self.forge_request, ep_request=self.ep_request,
            credential_reference=self.new.credential_reference,
        )
        return self.coordinator.replace_peer(**(arguments | changes))

    def read_terminal(self, **changes):
        arguments = dict(
            operation_id="repair-a", plan=self.plan, reviewed_current=self.current,
            old_binding=self.old, new_binding=self.new,
            forge_adapter=self.forge, ep_adapter=self.ep,
            forge_request=self.forge_request, ep_request=self.ep_request,
        )
        return self.coordinator.read_terminal(**(arguments | changes))

    def test_terminal_readback_survives_registry_change_without_configure(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            return_value=self.evidence,
        ) as configure, patch.object(
            ForgeEPProductPairingExecutor, "recover_after_product_replace",
            return_value=self.evidence,
        ) as recover:
            first = self.run_replace()
            self.registry.remove("deployment-a", expected_revision=1)
            self.assertEqual(self.read_terminal(), first)
            configure.assert_called_once()
            recover.assert_called_once()
            self.credential.issue_after_revoke.assert_called_once()

    def test_terminal_readback_rejects_changed_binding_or_evidence(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            return_value=self.evidence,
        ), patch.object(
            ForgeEPProductPairingExecutor, "recover_after_product_replace",
            return_value=replace(self.evidence, ep_readiness_reference="ep-status:changed"),
        ):
            self.run_replace()
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "identity changed"):
                self.read_terminal(new_binding=replace(self.new, binding_id="other"))
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "evidence changed"):
                self.read_terminal()

    def test_terminal_readback_rejects_changed_product_detach_receipt(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            return_value=self.evidence,
        ), patch.object(
            ForgeEPProductPairingExecutor, "recover_after_product_replace",
            return_value=self.evidence,
        ):
            self.run_replace()
            self.forge.read_historical_detach_ep_peer.return_value = {
                "current_peer_status": "CONFIGURED",
                "receipt": {"receipt_digest": "sha256:" + "0" * 64},
            }
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "detach receipt changed"):
                self.read_terminal()

    def test_exact_replace_and_terminal_readback_leave_registry_unchanged(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            return_value=self.evidence,
        ) as configure, patch.object(
            ForgeEPProductPairingExecutor, "recover_after_product_replace",
            return_value=self.evidence,
        ) as recover:
            first = self.run_replace()
            self.assertEqual(first.state, "COMPLETE")
            self.assertEqual(first.forge_configuration_reference, self.evidence.forge_configuration_reference)
            self.assertEqual(self.registry.load("deployment-a"), self.current)
            self.assertEqual(self.registry.load("deployment-b"), self.sibling)
            self.assertEqual(configure.call_count, 1)
            self.forge.read_detach_ep_peer.side_effect = RuntimeError("now configured")
            self.assertEqual(self.run_replace(), first)
            self.assertEqual(configure.call_count, 1)
            self.assertEqual(recover.call_count, 1)
        self.assertNotIn("keychain://", (self.root / "repair/repair-a.json").read_text())

    def test_lost_configure_response_recovers_without_duplicate_mutation(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            side_effect=RuntimeError("reply lost"),
        ) as configure, patch.object(
            ForgeEPProductPairingExecutor, "recover_after_product_replace",
            return_value=self.evidence,
        ) as recover:
            with self.assertRaisesRegex(RuntimeError, "reply lost"):
                self.run_replace()
            raw = (self.root / "repair/repair-a.json").read_text()
            self.assertIn('"state":"PREPARED"', raw)
            self.forge.read_detach_ep_peer.side_effect = RuntimeError("now configured")
            final = self.run_replace()
            self.assertEqual(final.state, "COMPLETE")
            configure.assert_called_once()
            recover.assert_called_once()

    def test_stale_or_cross_target_review_blocks_before_credential(self):
        for change in (
            {"operation_id": "bad id"},
            {"reviewed_current": self.sibling},
            {"new_binding": replace(self.new, expected_ep_instance_id="ep-b")},
            {"credential_reference": "keychain://forge.ep/other"},
            {"forge_request": replace(self.forge_request, installation_identity="forge-b")},
        ):
            with self.subTest(change=change), self.assertRaises(ManagedPairingRepairExecutionError):
                self.run_replace(**change)
        self.credential.issue_after_revoke.assert_not_called()

    def test_credential_or_detach_not_terminal_blocks_before_pairing(self):
        original = self.credential.issue_after_revoke.return_value
        self.credential.issue_after_revoke.return_value = replace(original, state="PREPARED")
        with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "credential"):
            self.run_replace()
        self.detach.repair_detach.assert_not_called()
        self.credential.issue_after_revoke.return_value = original
        self.detach.repair_detach.return_value = replace(
            self.detach.repair_detach.return_value, state="PREPARED", receipt_digest=None,
        )
        with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "detach"):
            self.run_replace()
        self.assertFalse((self.root / "repair").exists())

    def test_currency_or_registry_drift_blocks_configure(self):
        with patch.object(ForgeEPProductPairingExecutor, "pair_after_product_detach") as configure:
            self.guard.require_current.side_effect = RuntimeError("stale installer")
            with self.assertRaisesRegex(RuntimeError, "stale installer"):
                self.run_replace()
            configure.assert_not_called()
            self.guard.require_current.side_effect = None
            self.registry.remove("deployment-a", expected_revision=1)
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "deployment changed"):
                self.run_replace()
            configure.assert_not_called()
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)

    def test_ambiguous_or_changed_receipt_fails_closed(self):
        with patch.object(ForgeEPProductPairingExecutor, "pair_after_product_detach") as configure:
            self.forge.read_detach_ep_peer.return_value = {
                "current_peer_status": "DETACHED",
                "receipt": {"receipt_digest": "sha256:" + "0" * 64},
            }
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "receipt changed"):
                self.run_replace()
            self.forge.read_detach_ep_peer.return_value = {
                "current_peer_status": "UNKNOWN",
                "receipt": {"receipt_digest": "sha256:" + "d" * 64},
            }
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "ambiguous"):
                self.run_replace()
            configure.assert_not_called()

    def test_corrupt_journal_and_changed_target_fail_closed(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            return_value=self.evidence,
        ) as configure:
            self.run_replace()
            path = self.root / "repair/repair-a.json"
            original = path.read_bytes()
            path.write_bytes(b'{"changed":true}')
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "journal is invalid"):
                self.run_replace()
            path.write_bytes(original)
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "operation identity"):
                self.run_replace(new_binding=replace(self.new, binding_id="other-new"))
            self.assertEqual(configure.call_count, 1)

    def test_complete_replay_requires_configured_peer_and_same_evidence(self):
        with patch.object(
            ForgeEPProductPairingExecutor, "pair_after_product_detach",
            return_value=self.evidence,
        ), patch.object(
            ForgeEPProductPairingExecutor, "recover_after_product_replace",
            return_value=replace(self.evidence, ep_readiness_reference="ep-status:changed"),
        ):
            self.run_replace()
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "no longer configured"):
                self.run_replace()
            self.forge.read_detach_ep_peer.side_effect = RuntimeError("now configured")
            with self.assertRaisesRegex(ManagedPairingRepairExecutionError, "evidence changed"):
                self.run_replace()

    def test_constructor_rejects_authority_or_journal_reuse(self):
        for changes in (
            {"operations_root": self.root / "issue"},
            {"expected_owner_uid": -1},
            {"registry": Mock(spec=ManagedDeploymentRegistry)},
        ):
            with self.subTest(changes=changes), self.assertRaises(TypeError):
                ManagedPairingRepairExecutionCoordinator(**({
                    "operations_root": self.root / "repair-b", "registry": self.registry,
                    "currency_guard": self.guard, "credential": self.credential,
                    "detach": self.detach, "expected_owner_uid": os.getuid(),
                } | changes))


if __name__ == "__main__":
    unittest.main()
