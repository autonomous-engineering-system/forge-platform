from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingBinding
from forge_platform.forge_server_adapter import ForgeServerProductAdapter, ForgeServerTarget
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_pairing_revocation import (
    ManagedPairingRevocationCoordinator, ManagedPairingRevocationError,
    ManagedPairingRepairRevocationCoordinator,
)
from forge_platform.managed_pairing_detach import ManagedPairingRepairDetachCoordinator


RECEIPT = "ep-consumer-revoke:sha256:" + sha256(json.dumps({
    "instance_id": "ep-a",
    "consumer_id": "consumer-a",
    "project_id": "project-a",
    "status": "REVOKED",
    "revoked_at": "2026-09-27T00:00:00Z",
}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Guard:
    def __init__(self):
        self.calls = []
        self.fail = False
        self.after_check = None

    def require_current(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail:
            raise RuntimeError("installer currency unavailable")
        if self.after_check is not None:
            self.after_check()
        return "currency:exact"


class Revoker:
    def __init__(self, scope, instance="ep-a"):
        self.scope = scope
        self.provisioner = SimpleNamespace(target=SimpleNamespace(instance_id=instance))
        self.state = "ACTIVE"
        self.calls = 0
        self.interrupt = False
        self.bad_receipt = False

    def status(self):
        return {
            "consumer_id": self.scope.consumer_id,
            "project_id": self.scope.project_id,
            "status": self.state,
            "revoked_at": "2026-09-27T00:00:00Z" if self.state == "REVOKED" else None,
        }

    def revoke(self):
        if self.state != "REVOKED":
            self.calls += 1
            self.state = "REVOKED"
            if self.interrupt:
                self.interrupt = False
                raise RuntimeError("interrupted after product mutation")
        if self.bad_receipt:
            return "wrong-receipt"
        evidence = {
            "instance_id": self.provisioner.target.instance_id,
            "consumer_id": self.scope.consumer_id,
            "project_id": self.scope.project_id,
            "status": "REVOKED",
            "revoked_at": "2026-09-27T00:00:00Z",
        }
        return "ep-consumer-revoke:sha256:" + sha256(json.dumps(
            evidence, sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()


class ManagedPairingRevocationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
        self.operations = root / "operations"
        self.registry = ManagedDeploymentRegistry(root / "registry")
        self.guard = Guard()
        self.scope = EPConsumerScope("consumer-a", "project-a")
        self.other_scope = EPConsumerScope("consumer-b", "project-b")
        self.current = ManagedDeployment(
            "deployment-a", 1, "Paired A",
            (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge-a"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ),
            ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-a"),
        )
        self.other = ManagedDeployment(
            "deployment-b", 1, "Paired B",
            (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
                ManagedComponentBinding("engineering-platform-server", "ep-b", "receipt:ep-b"),
            ),
            ManagedPeerBinding("forge-b", "ep-b", "receipt:pair-b"),
        )
        self.registry.create(self.current)
        self.registry.create(self.other)
        self.revoker = Revoker(self.scope)
        self.coordinator = ManagedPairingRevocationCoordinator(
            operations_root=self.operations, registry=self.registry,
            currency_guard=self.guard,
            scope_claims={"deployment-a": self.scope, "deployment-b": self.other_scope},
            expected_owner_uid=self.operations.parent.stat().st_uid,
        )
        self.full_plan = ManagedDeploymentPlanner.plan(self.current, None)
        self.ep_only = ManagedDeployment(
            "deployment-a", 1, "Paired A",
            (ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),),
        )
        self.component_plan = ManagedDeploymentPlanner.plan(self.current, self.ep_only)

    def run_revoke(self, plan=None, operation="remove-a"):
        return self.coordinator.revoke(
            operation, plan or self.full_plan,
            reviewed_current=self.current, revoker=self.revoker,
        )

    def repair_setup(self):
        desired = replace(
            self.current, revision=2,
            peer_binding=ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-new"),
        )
        plan = ManagedDeploymentPlanner.plan(
            self.current, desired,
            product_actions={"forge-runtime": "REPAIR", "engineering-platform-server": "NO_CHANGE"},
        )
        artifact = QualifiedArtifact(
            "2.7.39", "ebc43dc12da27353f85c991a26da9852aa790f05",
            "released-wheel",
            "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
            "release-complete",
        )
        root = self.operations.parent
        forge = ForgeServerProductAdapter(
            forge_executable=root / "bin/forge",
            target=ForgeServerTarget(
                "forge-a", root / "instances/forge-a", root / "instances",
                "_forge_a", 9000, root / "credentials/forge-a.token",
            ),
            installed_artifact=artifact, staged_artifacts={}, supervisor=object(),
        )
        binding = ForgeEPProductPairingBinding(
            "binding-a", "http://127.0.0.1:9001", "ep-a", "consumer-a",
            "host-a", "project-a", "repo-a", "owner:repo",
            "keychain://forge/ep-a", "operator-a", True,
        )
        detach = ManagedPairingRepairDetachCoordinator(
            operations_root=root / "repair-detach", registry=self.registry,
            currency_guard=self.guard, expected_owner_uid=root.stat().st_uid,
        )
        coordinator = ManagedPairingRepairRevocationCoordinator(
            operations_root=root / "repair-revoke", registry=self.registry,
            currency_guard=self.guard,
            scope_claims={"deployment-a": self.scope, "deployment-b": self.other_scope},
            expected_owner_uid=root.stat().st_uid,
        )
        return plan, forge, binding, detach, coordinator

    def test_repair_revoke_requires_terminal_detach_and_replays_exact_ep_receipt(self):
        plan, forge, binding, detach, coordinator = self.repair_setup()
        terminal = SimpleNamespace(state="COMPLETE", receipt_digest="sha256:" + "a" * 64)
        with patch.object(detach, "repair_detach", return_value=terminal) as prior:
            first = coordinator.repair_revoke(
                "repair-a", plan, reviewed_current=self.current,
                revoker=self.revoker, detach_coordinator=detach,
                forge_adapter=forge, old_binding=binding,
            )
            second = coordinator.repair_revoke(
                "repair-a", plan, reviewed_current=self.current,
                revoker=self.revoker, detach_coordinator=detach,
                forge_adapter=forge, old_binding=binding,
            )
        self.assertEqual(first, second)
        self.assertEqual(first.state, "COMPLETE")
        self.assertEqual(first.receipt_reference, RECEIPT)
        self.assertEqual(prior.call_count, 2)
        self.assertEqual(self.revoker.calls, 1)
        self.assertEqual(self.registry.load("deployment-b"), self.other)
        self.assertEqual(len(self.guard.calls), 1)
        self.assertNotIn("credential", (self.operations.parent / "repair-revoke/repair-a.json").read_text())

    def test_repair_revoke_lost_reply_and_stale_currency_fail_closed(self):
        plan, forge, binding, detach, coordinator = self.repair_setup()
        terminal = SimpleNamespace(state="COMPLETE", receipt_digest="sha256:" + "a" * 64)
        with patch.object(detach, "repair_detach", return_value=terminal):
            self.guard.fail = True
            with self.assertRaisesRegex(RuntimeError, "currency"):
                coordinator.repair_revoke(
                    "repair-a", plan, reviewed_current=self.current,
                    revoker=self.revoker, detach_coordinator=detach,
                    forge_adapter=forge, old_binding=binding,
                )
            self.assertEqual(self.revoker.calls, 0)
            self.guard.fail = False
            self.revoker.interrupt = True
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                coordinator.repair_revoke(
                    "repair-a", plan, reviewed_current=self.current,
                    revoker=self.revoker, detach_coordinator=detach,
                    forge_adapter=forge, old_binding=binding,
                )
            result = coordinator.repair_revoke(
                "repair-a", plan, reviewed_current=self.current,
                revoker=self.revoker, detach_coordinator=detach,
                forge_adapter=forge, old_binding=binding,
            )
        self.assertEqual(result.state, "COMPLETE")
        self.assertEqual(self.revoker.calls, 1)

    def test_repair_revoke_blocks_nonterminal_detach_or_wrong_old_scope(self):
        plan, forge, binding, detach, coordinator = self.repair_setup()
        with patch.object(detach, "repair_detach", return_value=SimpleNamespace(
            state="PREPARED", receipt_digest=None,
        )):
            with self.assertRaisesRegex(ManagedPairingRevocationError, "detach is not terminal"):
                coordinator.repair_revoke(
                    "repair-a", plan, reviewed_current=self.current,
                    revoker=self.revoker, detach_coordinator=detach,
                    forge_adapter=forge, old_binding=binding,
                )
        with patch.object(detach, "repair_detach") as prior:
            with self.assertRaisesRegex(ManagedPairingRevocationError, "target changed"):
                coordinator.repair_revoke(
                    "repair-a", plan, reviewed_current=self.current,
                    revoker=self.revoker, detach_coordinator=detach,
                    forge_adapter=forge,
                    old_binding=replace(binding, consumer_id="foreign"),
                )
            prior.assert_not_called()
        self.assertEqual(self.revoker.calls, 0)

    def test_full_remove_prepared_and_terminal_duplicate_are_exact(self):
        other_before = self.registry.load("deployment-b")
        other_bytes = (self.registry.root / "deployment-b.json").read_bytes()
        first = self.run_revoke()
        self.assertEqual(first.state, "COMPLETE")
        self.assertEqual(first.receipt_reference, RECEIPT)
        self.assertEqual(self.run_revoke(), first)
        self.assertEqual(self.revoker.calls, 1)
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        self.assertEqual(self.registry.load("deployment-b"), other_before)
        self.assertEqual((self.registry.root / "deployment-b.json").read_bytes(), other_bytes)
        self.assertEqual(self.guard.calls[0]["instance_id"], "ep-a")
        self.assertEqual(self.guard.calls[0]["mutation"], "pairing-consumer-revoke")
        raw = (self.operations / "remove-a.json").read_text()
        self.assertNotIn("credential", raw)
        self.assertNotIn("token", raw)

    def test_remove_forge_component_retains_ep(self):
        result = self.run_revoke(self.component_plan)
        self.assertEqual(result.forge_instance_id, "forge-a")
        self.assertEqual(result.ep_instance_id, "ep-a")
        self.assertEqual(result.state, "COMPLETE")
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_terminal_readback_binds_original_review_scope_and_revoked_status(self):
        self.run_revoke(self.component_plan, operation="preserve-a")
        fingerprint = "sha256:" + sha256(json.dumps(
            asdict(self.current), sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()
        selected = dict(
            operation_id="preserve-a", deployment_id="deployment-a",
            reviewed_deployment_fingerprint=fingerprint,
            forge_instance_id="forge-a", ep_instance_id="ep-a", revoker=self.revoker,
        )
        self.assertEqual(self.coordinator.read_terminal(**selected).state, "COMPLETE")
        for changed in (
            selected | {"forge_instance_id": "forge-b"},
            selected | {"reviewed_deployment_fingerprint": "sha256:" + "b" * 64},
            selected | {"operation_id": "preserve-b"},
            selected | {"revoker": Revoker(self.other_scope)},
        ):
            with self.assertRaises(ManagedPairingRevocationError):
                self.coordinator.read_terminal(**changed)
        self.revoker.state = "ACTIVE"
        with self.assertRaises(ManagedPairingRevocationError):
            self.coordinator.read_terminal(**selected)

    def test_interrupted_after_product_revoke_resumes_same_intent(self):
        self.revoker.interrupt = True
        with self.assertRaises(RuntimeError):
            self.run_revoke()
        self.assertIn('"PREPARED"', (self.operations / "remove-a.json").read_text())
        result = self.run_revoke()
        self.assertEqual(result.state, "COMPLETE")
        self.assertEqual(self.revoker.calls, 1)

    def test_stale_target_wrong_scope_or_instance_fails_before_mutation(self):
        wrong = Revoker(self.scope, instance="ep-b")
        with self.assertRaises(ManagedPairingRevocationError):
            self.coordinator.revoke("remove-a", self.full_plan, reviewed_current=self.current, revoker=wrong)
        wrong = Revoker(self.other_scope)
        with self.assertRaises(ManagedPairingRevocationError):
            self.coordinator.revoke("remove-a", self.full_plan, reviewed_current=self.current, revoker=wrong)
        self.registry.replace(
            ManagedDeployment("deployment-a", 2, "Changed", self.current.components, self.current.peer_binding),
            expected_revision=1,
        )
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke()
        self.assertEqual(self.revoker.calls, 0)

    def test_currency_failure_and_receipt_mismatch_remain_prepared(self):
        self.guard.fail = True
        with self.assertRaises(RuntimeError):
            self.run_revoke()
        self.assertEqual(self.revoker.calls, 0)
        self.guard.fail = False
        self.revoker.bad_receipt = True
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke()
        self.assertEqual(self.revoker.calls, 1)
        self.assertIn('"PREPARED"', (self.operations / "remove-a.json").read_text())

    def test_registry_drift_after_currency_check_blocks_product_mutation(self):
        self.guard.after_check = lambda: self.registry.replace(
            ManagedDeployment("deployment-a", 2, "Changed", self.current.components, self.current.peer_binding),
            expected_revision=1,
        )
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke()
        self.assertEqual(self.revoker.calls, 0)
        self.assertIn('"PREPARED"', (self.operations / "remove-a.json").read_text())

    def test_terminal_readback_mismatch_leaves_prepared_journal(self):
        original = self.revoker.status

        def stale():
            result = original()
            if self.revoker.state == "REVOKED":
                result["status"] = "ACTIVE"
            return result

        self.revoker.status = stale
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke()
        self.assertEqual(self.revoker.calls, 1)
        self.assertIn('"PREPARED"', (self.operations / "remove-a.json").read_text())

    def test_duplicate_operation_cannot_change_reviewed_plan(self):
        self.run_revoke()
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke(self.component_plan)

    def test_corrupt_journal_and_duplicate_scope_fail_closed(self):
        with self.assertRaises(ValueError):
            ManagedPairingRevocationCoordinator(
                operations_root=self.operations, registry=self.registry,
                currency_guard=self.guard,
                scope_claims={"deployment-a": self.scope, "deployment-b": self.scope},
            )
        self.operations.mkdir()
        journal = self.operations / "remove-a.json"
        journal.write_text("{}")
        journal.chmod(0o600)
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke()
        journal.unlink()
        journal.symlink_to(self.registry.root / "deployment-b.json")
        with self.assertRaises(ManagedPairingRevocationError):
            self.run_revoke()
        self.assertEqual(self.revoker.calls, 0)


if __name__ == "__main__":
    unittest.main()
