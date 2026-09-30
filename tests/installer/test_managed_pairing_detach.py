from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingBinding
from forge_platform.forge_server_adapter import ForgeServerProductAdapter, ForgeServerTarget
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_pairing_detach import (
    ManagedPairingDetachCoordinator, ManagedPairingDetachError, _read,
)


ARTIFACT = QualifiedArtifact(
    "2.7.39", "ebc43dc12da27353f85c991a26da9852aa790f05",
    "https://example.invalid/forge-2.7.39.whl",
    "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
    "https://example.invalid/release-evidence",
)


class Guard:
    def __init__(self):
        self.calls = []
        self.fail = False

    def require_current(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail:
            raise RuntimeError("installer currency unavailable")
        return "currency:exact"


class ManagedPairingDetachTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.registry = ManagedDeploymentRegistry(self.root / "registry")
        self.current = ManagedDeployment(
            "deployment-a", 1, "A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge-a"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ), ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-a"),
        )
        self.sibling = ManagedDeployment(
            "deployment-b", 1, "B", (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
                ManagedComponentBinding("engineering-platform-server", "ep-b", "receipt:ep-b"),
            ), ManagedPeerBinding("forge-b", "ep-b", "receipt:pair-b"),
        )
        self.registry.create(self.current)
        self.registry.create(self.sibling)
        desired = ManagedDeployment(
            "deployment-a", 1, "A", (
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ),
        )
        self.plan = ManagedDeploymentPlanner.plan(self.current, desired)
        self.binding = ForgeEPProductPairingBinding(
            "binding-a", "http://127.0.0.1:9001", "ep-a", "consumer-a",
            "host-a", "project-a", "repo-a", "owner:repo",
            "keychain://forge/ep-a", "operator-a", True,
        )
        target = ForgeServerTarget(
            "forge-a", self.root / "instances/forge-a", self.root / "instances",
            "_forge_a", 9000, self.root / "credentials/forge-a.token",
        )
        self.adapter = ForgeServerProductAdapter(
            forge_executable=self.root / "bin/forge", target=target,
            installed_artifact=ARTIFACT, staged_artifacts={}, supervisor=object(),
        )
        self.guard = Guard()
        self.coordinator = ManagedPairingDetachCoordinator(
            operations_root=self.root / "operations", registry=self.registry,
            currency_guard=self.guard, expected_owner_uid=os.getuid(),
        )
        self.generation = (2, "sha256:" + "a" * 64)
        self.receipt = "sha256:" + "b" * 64
        self.status = {"receipt": {"receipt_digest": self.receipt}}

    def detach(self):
        return self.coordinator.detach(
            "remove-a", self.plan, reviewed_current=self.current,
            adapter=self.adapter, binding=self.binding,
        )

    def test_durable_exact_detach_and_idempotent_product_replay(self):
        with patch.object(
            ForgeServerProductAdapter, "read_peer_configuration_generation",
            return_value=self.generation,
        ) as generation, patch.object(
            self.adapter, "detach_ep_peer", return_value=self.status,
        ) as product:
            first = self.detach()
            self.assertEqual(first.state, "COMPLETE")
            self.assertEqual(first.receipt_digest, self.receipt)
            self.assertEqual(first.configuration_revision, 2)
            self.assertEqual(first.configuration_digest, self.generation[1])
            self.assertEqual(self.detach(), first)
            self.assertEqual(generation.call_count, 1)
            self.assertEqual(product.call_count, 2)
            self.assertEqual(product.call_args.kwargs["binding_id"], "binding-a")
            self.assertEqual(product.call_args.kwargs["revision"], 2)
            self.assertEqual(product.call_args.kwargs["operator_id"], "operator-a")
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)
        self.assertEqual(len(self.guard.calls), 2)
        saved = _read(self.root / "operations/remove-a.json", owner_uid=os.getuid())
        self.assertEqual(saved, first)
        self.assertEqual((self.root / "operations/remove-a.json").stat().st_mode & 0o777, 0o600)

    def test_lost_product_reply_resumes_same_journal_and_rejects_changed_receipt(self):
        with patch.object(
            ForgeServerProductAdapter, "read_peer_configuration_generation",
            return_value=self.generation,
        ) as generation, patch.object(
            self.adapter, "detach_ep_peer",
            side_effect=[RuntimeError("reply lost"), self.status, self.status],
        ) as product:
            with self.assertRaisesRegex(RuntimeError, "reply lost"):
                self.detach()
            prepared = _read(self.root / "operations/remove-a.json", owner_uid=os.getuid())
            self.assertEqual(prepared.state, "PREPARED")
            complete = self.detach()
            self.assertEqual(complete.state, "COMPLETE")
            self.assertEqual(generation.call_count, 1)
            self.assertEqual(product.call_args.kwargs["operation_id"], prepared.product_operation_id)
            with patch.object(
                self.adapter, "detach_ep_peer",
                return_value={"receipt": {"receipt_digest": "sha256:" + "c" * 64}},
            ):
                with self.assertRaisesRegex(ManagedPairingDetachError, "terminal Forge"):
                    self.detach()

    def test_stale_currency_and_reviewed_target_fail_before_product_mutation(self):
        self.guard.fail = True
        with patch.object(
            ForgeServerProductAdapter, "read_peer_configuration_generation",
            return_value=self.generation,
        ), patch.object(self.adapter, "detach_ep_peer") as product:
            with self.assertRaisesRegex(RuntimeError, "currency"):
                self.detach()
            product.assert_not_called()
            self.guard.fail = False
            changed_binding = replace(self.binding, consumer_id="consumer-other")
            with self.assertRaisesRegex(ManagedPairingDetachError, "operation identity"):
                self.coordinator.detach(
                    "remove-a", self.plan, reviewed_current=self.current,
                    adapter=self.adapter, binding=changed_binding,
                )
            product.assert_not_called()
            self.registry.remove("deployment-a", expected_revision=1)
            with self.assertRaisesRegex(ManagedPairingDetachError, "reviewed deployment"):
                self.detach()
            product.assert_not_called()
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)

    def test_corrupt_or_symlink_journal_fails_closed(self):
        with patch.object(
            ForgeServerProductAdapter, "read_peer_configuration_generation",
            return_value=self.generation,
        ), patch.object(self.adapter, "detach_ep_peer", side_effect=RuntimeError("reply lost")):
            with self.assertRaisesRegex(RuntimeError, "reply lost"):
                self.detach()
        path = self.root / "operations/remove-a.json"
        original = path.read_bytes()
        path.write_bytes(b'{"changed":true}')
        with patch.object(self.adapter, "detach_ep_peer") as product:
            with self.assertRaisesRegex(ManagedPairingDetachError, "journal is invalid"):
                self.detach()
            product.assert_not_called()
        path.unlink()
        target = self.root / "untrusted.json"
        target.write_bytes(original)
        path.symlink_to(target)
        with patch.object(self.adapter, "detach_ep_peer") as product:
            with self.assertRaisesRegex(ManagedPairingDetachError, "journal is invalid"):
                self.detach()
            product.assert_not_called()

    def test_inventory_drift_during_currency_check_blocks_detach(self):
        def drift(**_kwargs):
            self.registry.remove("deployment-a", expected_revision=1)
            return "currency:exact"

        with patch.object(
            ForgeServerProductAdapter, "read_peer_configuration_generation",
            return_value=self.generation,
        ), patch.object(self.guard, "require_current", side_effect=drift), patch.object(
            self.adapter, "detach_ep_peer",
        ) as product:
            with self.assertRaisesRegex(ManagedPairingDetachError, "before product detach"):
                self.detach()
            product.assert_not_called()
        self.assertEqual(self.registry.load("deployment-b"), self.sibling)


if __name__ == "__main__":
    unittest.main()
