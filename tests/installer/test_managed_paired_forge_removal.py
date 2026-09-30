from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from forge_platform.component_operations import (
    ComponentOperationRequest, ProductInstallationReadback, ProductOperationReceipt,
    QualifiedArtifact,
)
from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedCompositionBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
    MANAGED_DEPLOYMENT_SCHEMA_V2,
)
from forge_platform.managed_paired_forge_removal import (
    ManagedPairedForgeComponentRemovalCoordinator, ManagedPairedForgeRemovalError,
)
from forge_platform.managed_pairing_revocation import (
    ManagedPairingRevocationCoordinator, ManagedPairingRevocationError,
)


FORGE_ARTIFACT = QualifiedArtifact(
    "2.7.37", "a78523603d6ea081d07875ea6b557e73b5d4fe63", "https://example.invalid/forge.whl",
    "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938", "https://example.invalid/forge-evidence",
)
EP_ARTIFACT = QualifiedArtifact(
    "2.3.106", "7b99b578153ae5d72372a09db194306b49ec9f9c", "https://example.invalid/ep.whl",
    "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694", "https://example.invalid/ep-evidence",
)
FORGE_RECEIPT = "forge-uninstall:sha256:" + "d" * 64
EP_RECEIPT = "ep-consumer-revoke:sha256:" + "e" * 64


class Guard:
    def __init__(self):
        self.calls = []

    def require_current(self, **kwargs):
        self.calls.append(kwargs)
        return "currency:exact"


class ForgeAdapter:
    def __init__(self):
        self.active = True
        self.calls = 0
        self.resumes = 0
        self.pending_once = False
        self.receipt = FORGE_RECEIPT

    def removal_support(self):
        return "SUPPORTED"

    def readback(self, request):
        if self.active:
            return ProductInstallationReadback(
                "forge-runtime", "forge-a", "ACTIVE", "runtime:forge",
                "executable:forge", "service:forge", "forge-a",
                request.artifact.correlation, "HEALTHY", "MACHINE_WIDE", "NONE",
                "forge-status:active", "forge-health:ready",
            )
        return ProductInstallationReadback(
            "forge-runtime", "forge-a", "ABSENT", None, None, None, None,
            None, "UNKNOWN", "MACHINE_WIDE", "NONE", self.receipt,
        )

    def assess_update(self, request):
        raise AssertionError("remove must not assess an update")

    def execute(self, request):
        self.calls += 1
        if self.pending_once:
            self.pending_once = False
            return ProductOperationReceipt(
                request.operation_id, "forge-runtime", "forge-a",
                request.artifact.correlation, "CLEANUP_PENDING",
                "forge-uninstall:pending", "forge-uninstall:cleanup",
            )
        self.active = False
        return ProductOperationReceipt(
            request.operation_id, "forge-runtime", "forge-a",
            request.artifact.correlation, "COMPLETED", self.receipt,
        )

    def resume(self, request, prior_receipt):
        self.resumes += 1
        return self.execute(request)


class EPAdapter:
    def __init__(self):
        self.ready = True

    def readback(self, request):
        return ProductInstallationReadback(
            "engineering-platform-server", "ep-a",
            "ACTIVE" if self.ready else "UNHEALTHY",
            "runtime:ep", "executable:ep", "service:ep", "ep-a",
            request.artifact.correlation,
            "HEALTHY" if self.ready else "UNHEALTHY",
            "MACHINE_WIDE", "NONE", "ep-status:exact", "ep-health:exact",
        )


class Revoker:
    def __init__(self, scope):
        self.scope = scope
        self.provisioner = SimpleNamespace(target=SimpleNamespace(instance_id="ep-a"))
        self.state = "ACTIVE"
        self.mutations = 0

    def status(self):
        return {
            "consumer_id": self.scope.consumer_id,
            "project_id": self.scope.project_id,
            "status": self.state,
            "revoked_at": "2026-09-27T00:00:00Z" if self.state == "REVOKED" else None,
        }

    def revoke(self):
        if self.state == "ACTIVE":
            self.mutations += 1
            self.state = "REVOKED"
        return EP_RECEIPT


class ManagedPairedForgeRemovalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
        self.registry = ManagedDeploymentRegistry(root / "registry")
        self.composition = ManagedCompositionBinding(
            "composition-a", "sha256:" + "c" * 64, "receipt:composition-a",
        )
        self.current = ManagedDeployment(
            "deployment-a", 1, "Paired A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge-a"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ), ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-a"),
            schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
            composition_binding=self.composition,
        )
        self.other = ManagedDeployment(
            "deployment-b", 1, "Forge B", (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
            ),
        )
        self.registry.create(self.current)
        self.registry.create(self.other)
        self.desired = ManagedDeployment(
            "deployment-a", 1, "Paired A", (
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ), schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
            composition_binding=self.composition,
        )
        self.plan = ManagedDeploymentPlanner.plan(self.current, self.desired)
        self.forge_request = ComponentOperationRequest(
            "forge-a-remove", "forge-runtime", "remove", FORGE_ARTIFACT,
            "forge-a", "server", {},
        )
        self.ep_request = ComponentOperationRequest(
            "ep-a-readback", "engineering-platform-server", "repair", EP_ARTIFACT,
            "ep-a", "server", {},
        )
        self.guard = Guard()
        self.scope = EPConsumerScope("consumer-a", "project-a")
        self.revoker = Revoker(self.scope)
        self.revocation = ManagedPairingRevocationCoordinator(
            operations_root=root / "revocation", registry=self.registry,
            currency_guard=self.guard,
            scope_claims={"deployment-a": self.scope},
            expected_owner_uid=root.stat().st_uid,
        )
        self.coordinator = ManagedPairedForgeComponentRemovalCoordinator(
            operations_root=root / "operations",
            component_operations_root=root / "components",
            registry=self.registry, currency_guard=self.guard,
            revocation=self.revocation,
        )
        self.forge = ForgeAdapter()
        self.ep = EPAdapter()

    def remove(self):
        return self.coordinator.remove(
            "deployment-a-remove", self.plan, reviewed_current=self.current,
            forge_request=self.forge_request, forge_adapter=self.forge,
            ep_readback_request=self.ep_request, ep_adapter=self.ep,
            revoker=self.revoker,
        )

    def test_exact_component_removal_and_duplicate_preserve_other_bytes(self):
        other_bytes = (self.registry.root / "deployment-b.json").read_bytes()
        first = self.remove()
        self.assertEqual(first.state, "COMPLETE")
        self.assertEqual(self.registry.load("deployment-a").revision, 2)
        self.assertEqual(set(self.registry.load("deployment-a").by_component), {"engineering-platform-server"})
        self.assertIsNone(self.registry.load("deployment-a").peer_binding)
        self.assertEqual(self.registry.load("deployment-a").schema, MANAGED_DEPLOYMENT_SCHEMA_V2)
        self.assertEqual(self.registry.load("deployment-a").composition_binding, self.composition)
        self.assertEqual((self.registry.root / "deployment-b.json").read_bytes(), other_bytes)
        self.assertEqual(self.remove(), first)
        self.assertEqual(self.forge.calls, 1)
        self.assertEqual(self.revoker.mutations, 1)

    def test_interrupted_forge_uninstall_resumes_exact_target(self):
        self.forge.pending_once = True
        first = self.remove()
        self.assertEqual(first.state, "RECOVERY_PENDING")
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        second = self.remove()
        self.assertEqual(second.state, "COMPLETE")
        self.assertEqual(self.forge.resumes, 1)
        self.assertEqual(self.revoker.mutations, 1)

    def test_retained_ep_readiness_failure_blocks_registry_commit(self):
        self.ep.ready = False
        with self.assertRaises(ManagedPairedForgeRemovalError):
            self.remove()
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        self.assertFalse(self.forge.active)
        self.ep.ready = True
        self.assertEqual(self.remove().state, "COMPLETE")

    def test_receipt_mismatch_blocks_registry_commit(self):
        self.forge.receipt = "forge-uninstall:sha256:" + "f" * 64
        original = self.forge.readback

        def inconsistent(request):
            result = original(request)
            if result.state == "ABSENT":
                return ProductInstallationReadback(
                    "forge-runtime", "forge-a", "ABSENT", None, None, None,
                    None, None, "UNKNOWN", "MACHINE_WIDE", "NONE", FORGE_RECEIPT,
                )
            return result

        self.forge.readback = inconsistent
        with self.assertRaises(ManagedPairedForgeRemovalError):
            self.remove()
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_stale_reviewed_target_fails_before_product_mutation(self):
        self.registry.replace(
            ManagedDeployment("deployment-a", 2, "Changed", self.current.components, self.current.peer_binding),
            expected_revision=1,
        )
        with self.assertRaises(ManagedPairedForgeRemovalError):
            self.remove()
        self.assertEqual(self.forge.calls, 0)
        self.assertEqual(self.revoker.mutations, 0)

    def test_wrong_forge_instance_or_ep_scope_fails_before_mutation(self):
        wrong_request = ComponentOperationRequest(
            "forge-b-remove", "forge-runtime", "remove", FORGE_ARTIFACT,
            "forge-b", "server", {},
        )
        with self.assertRaises(ManagedPairedForgeRemovalError):
            self.coordinator.remove(
                "deployment-a-remove", self.plan,
                reviewed_current=self.current,
                forge_request=wrong_request, forge_adapter=self.forge,
                ep_readback_request=self.ep_request, ep_adapter=self.ep,
                revoker=self.revoker,
            )
        self.revoker.scope = EPConsumerScope("consumer-b", "project-b")
        with self.assertRaises(ManagedPairingRevocationError):
            self.remove()
        self.assertEqual(self.forge.calls, 0)
        self.assertEqual(self.revoker.mutations, 0)

    def test_historical_or_digest_drifted_producer_fails_before_mutation(self):
        original_forge = self.forge_request
        original_ep = self.ep_request
        for artifact in (
            replace(FORGE_ARTIFACT, version="2.7.36"),
            replace(FORGE_ARTIFACT, digest="sha256:" + "0" * 64),
        ):
            self.forge_request = replace(original_forge, artifact=artifact)
            with self.subTest(artifact=artifact), self.assertRaises(ManagedPairedForgeRemovalError):
                self.remove()
        self.forge_request = original_forge
        for artifact in (
            replace(EP_ARTIFACT, version="2.3.103"),
            replace(EP_ARTIFACT, digest="sha256:" + "0" * 64),
        ):
            self.ep_request = replace(original_ep, artifact=artifact)
            with self.subTest(artifact=artifact), self.assertRaises(ManagedPairedForgeRemovalError):
                self.remove()
        self.assertEqual(self.forge.calls, 0)
        self.assertEqual(self.revoker.mutations, 0)

    def test_duplicate_with_changed_request_fingerprint_fails_closed(self):
        self.assertEqual(self.remove().state, "COMPLETE")
        self.forge_request = ComponentOperationRequest(
            "forge-a-other-operation", "forge-runtime", "remove", FORGE_ARTIFACT,
            "forge-a", "server", {},
        )
        with self.assertRaises(ManagedPairedForgeRemovalError):
            self.remove()
        self.assertEqual(self.forge.calls, 1)


if __name__ == "__main__":
    unittest.main()
