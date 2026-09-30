from __future__ import annotations

from dataclasses import asdict
from hashlib import sha256
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_pairing_revocation import (
    ManagedPairingRevocationCoordinator, ManagedPairingRevocationError,
)


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
