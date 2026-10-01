from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_pairing import ManagedPairingEvidence
from forge_platform.managed_pairing_repair_commit import (
    ManagedPairingRepairCommitCoordinator, ManagedPairingRepairCommitError,
)
from forge_platform.managed_pairing_repair_execution import (
    ManagedPairingRepairExecutionCoordinator, PairingRepairExecutionRecord,
)


class RepairCommitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.registry = ManagedDeploymentRegistry(self.root / "registry")
        self.current = ManagedDeployment(
            "deployment-a", 1, "Paired A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep"),
            ), ManagedPeerBinding("forge-a", "ep-a", "receipt:old"),
        )
        self.sibling = ManagedDeployment(
            "deployment-b", 1, "Paired B", (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
                ManagedComponentBinding("engineering-platform-server", "ep-b", "receipt:ep-b"),
            ), ManagedPeerBinding("forge-b", "ep-b", "receipt:other"),
        )
        self.registry.create(self.current)
        self.registry.create(self.sibling)
        self.desired = replace(
            self.current, revision=2,
            peer_binding=ManagedPeerBinding("forge-a", "ep-a", "receipt:provisional"),
        )
        self.plan = ManagedDeploymentPlanner.plan(
            self.current, self.desired,
            product_actions={"forge-runtime": "REPAIR", "engineering-platform-server": "NO_CHANGE"},
        )
        self.execution = Mock(spec=ManagedPairingRepairExecutionCoordinator)
        self.execution.registry = self.registry
        self.evidence = ManagedPairingEvidence(
            "forge-a", "ep-a", "forge-peer-configuration:sha256:" + "1" * 64,
            "forge-peer-preflight:sha256:" + "2" * 64,
            "ep-status:sha256:" + "3" * 64,
        )
        self.terminal = PairingRepairExecutionRecord(
            "repair-a", "deployment-a", "sha256:" + "a" * 64,
            "sha256:" + "b" * 64, "sha256:" + "c" * 64,
            "sha256:" + "d" * 64, "production-" + "e" * 32,
            "f" * 64, "peer-repair-detach-" + sha256(b"repair-a").hexdigest()[:40], 3,
            "sha256:" + "0" * 64, "sha256:" + "1" * 64,
            "COMPLETE", self.evidence.forge_configuration_reference,
            self.evidence.forge_preflight_reference,
            self.evidence.ep_readiness_reference,
        )
        self.execution.replace_peer.return_value = self.terminal
        self.execution.read_terminal.return_value = self.terminal
        self.coordinator = ManagedPairingRepairCommitCoordinator(
            registry=self.registry, execution=self.execution,
        )
        self.old_binding = object()
        self.new_binding = Mock()
        self.new_binding.credential_reference = "keychain://forge.ep/new"

    def run_commit(self, **changes):
        arguments = dict(
            operation_id="repair-a", plan=self.plan, reviewed_current=self.current,
            old_binding=self.old_binding, new_binding=self.new_binding,
            revoker=object(), forge_adapter=object(), ep_adapter=object(),
            forge_request=object(), ep_request=object(),
        )
        return self.coordinator.commit(**(arguments | changes))

    def test_real_terminal_receipt_committed_then_crash_replay_is_read_only(self):
        committed = self.run_commit()
        self.assertEqual(committed.revision, 2)
        self.assertEqual(committed.peer_binding.receipt_reference, self.evidence.receipt_reference)
        self.assertNotEqual(committed.peer_binding.receipt_reference, "receipt:provisional")
        self.assertEqual(self.registry.load("deployment-a"), committed)
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)
        self.execution.replace_peer.assert_called_once()
        self.execution.read_terminal.assert_called_once()
        self.assertEqual(self.run_commit(), committed)
        self.execution.replace_peer.assert_called_once()
        self.assertEqual(self.execution.read_terminal.call_count, 2)

    def test_missing_or_changed_product_terminal_blocks_registry_commit(self):
        self.execution.read_terminal.side_effect = RuntimeError("product status unavailable")
        with self.assertRaisesRegex(RuntimeError, "unavailable"):
            self.run_commit()
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        self.execution.read_terminal.side_effect = None
        self.execution.read_terminal.return_value = replace(
            self.terminal, ep_readiness_reference="", 
        )
        with self.assertRaises(ValueError):
            self.run_commit()
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_stale_review_or_other_deployment_cannot_commit(self):
        for change in (
            {"reviewed_current": self.sibling},
            {"plan": ManagedDeploymentPlanner.plan(self.current, None)},
        ):
            with self.subTest(change=change), self.assertRaises(ManagedPairingRepairCommitError):
                self.run_commit(**change)
        self.execution.replace_peer.assert_not_called()
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)

    def test_registry_drift_after_product_terminal_fails_closed(self):
        def drift(*_args, **_kwargs):
            changed = replace(self.current, revision=2)
            self.registry.replace(changed, expected_revision=1)
            return self.terminal

        self.execution.read_terminal.side_effect = drift
        with self.assertRaisesRegex(ManagedPairingRepairCommitError, "changed before"):
            self.run_commit()
        self.assertNotEqual(self.registry.load("deployment-a").peer_binding.receipt_reference,
                            self.evidence.receipt_reference)
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)

    def test_constructor_rejects_unshared_registry(self):
        with self.assertRaises(TypeError):
            ManagedPairingRepairCommitCoordinator(
                registry=ManagedDeploymentRegistry(self.root / "other"),
                execution=self.execution,
            )


if __name__ == "__main__":
    unittest.main()
