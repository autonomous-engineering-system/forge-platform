#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from forge_platform.component_operations import (
    ComponentOperationRequest, ProductInstallationReadback, ProductOperationReceipt,
    QualifiedArtifact,
)
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_forge_removal import (
    ManagedForgeOnlyRemovalCoordinator, ManagedForgeRemovalError,
)


ARTIFACT = QualifiedArtifact(
    "2.7.35", "f" * 40, "https://example.invalid/forge.whl",
    "sha256:" + "a" * 64, "https://example.invalid/qualification",
)
RECEIPT = "forge-uninstall:sha256:" + "b" * 64


class Guard:
    def __init__(self, fail: bool = False):
        self.calls = []
        self.fail = fail

    def require_current(self, **kwargs):
        self.calls.append(kwargs)
        if self.fail:
            raise RuntimeError("installer currency unavailable")
        return "currency:verified"


class ForgeAdapter:
    def __init__(self, instance="forge-a", pending_once=False):
        self.instance = instance
        self.pending_once = pending_once
        self.active = True
        self.calls = 0
        self.resumes = 0
        self.receipt = RECEIPT

    def removal_support(self):
        return "SUPPORTED"

    def readback(self, request):
        if self.active:
            return ProductInstallationReadback(
                "forge-runtime", self.instance, "ACTIVE", "runtime:forge",
                "executable:forge", "service:forge", self.instance,
                request.artifact.correlation, "HEALTHY", "MACHINE_WIDE", "NONE",
                "forge-status:active", "forge-health:ready",
            )
        return ProductInstallationReadback(
            "forge-runtime", self.instance, "ABSENT", None, None, None, None,
            None, "UNKNOWN", "MACHINE_WIDE", "NONE", self.receipt,
        )

    def assess_update(self, request):
        raise AssertionError("remove never assesses an update")

    def execute(self, request):
        self.calls += 1
        if self.pending_once:
            self.pending_once = False
            return ProductOperationReceipt(
                request.operation_id, "forge-runtime", self.instance,
                request.artifact.correlation, "CLEANUP_PENDING",
                "forge-uninstall:pending", "forge-uninstall:cleanup",
            )
        self.active = False
        return ProductOperationReceipt(
            request.operation_id, "forge-runtime", self.instance,
            request.artifact.correlation, "COMPLETED", self.receipt,
        )

    def resume(self, request, prior_receipt):
        self.resumes += 1
        return self.execute(request)


class ManagedForgeOnlyRemovalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name).resolve()
        self.registry = ManagedDeploymentRegistry(root / "registry")
        self.guard = Guard()
        self.coordinator = ManagedForgeOnlyRemovalCoordinator(
            operations_root=root / "operations",
            component_operations_root=root / "components",
            registry=self.registry,
            currency_guard=self.guard,
        )
        self.current = ManagedDeployment(
            "deployment-a", 1, "Forge A",
            (ManagedComponentBinding("forge-runtime", "forge-a", "receipt:installed-a"),),
        )
        self.other = ManagedDeployment(
            "deployment-b", 1, "Forge B",
            (ManagedComponentBinding("forge-runtime", "forge-b", "receipt:installed-b"),),
        )
        self.registry.create(self.current)
        self.registry.create(self.other)
        self.plan = ManagedDeploymentPlanner.plan(self.current, None)
        self.request = ComponentOperationRequest(
            "forge-a-remove", "forge-runtime", "remove", ARTIFACT,
            "forge-a", "server", {},
        )
        self.adapter = ForgeAdapter()

    def tearDown(self):
        self.temporary.cleanup()

    def remove(self):
        return self.coordinator.remove(
            "deployment-a-remove", self.plan,
            request=self.request, adapter=self.adapter,
        )

    def test_exact_forge_only_remove_and_duplicate_preserve_other_deployment(self):
        before = self.registry.load("deployment-b")
        first = self.remove()
        self.assertEqual(first.state, "COMPLETE")
        self.assertEqual(first.registry_revision, 0)
        self.assertIsNone(self.registry.load("deployment-a"))
        self.assertEqual(self.registry.load("deployment-b"), before)
        self.assertEqual(self.adapter.calls, 1)
        second = self.remove()
        self.assertEqual(second, first)
        self.assertEqual(self.adapter.calls, 1)
        self.assertEqual(self.registry.load("deployment-b"), before)
        self.assertEqual(
            [item["mutation"] for item in self.guard.calls],
            ["product-remove", "deployment-remove"],
        )

    def test_interrupted_product_remove_resumes_same_operation(self):
        self.adapter.pending_once = True
        first = self.remove()
        self.assertEqual(first.state, "RECOVERY_PENDING")
        self.assertIsNotNone(self.registry.load("deployment-a"))
        second = self.remove()
        self.assertEqual(second.state, "COMPLETE")
        self.assertEqual(self.adapter.resumes, 1)
        self.assertEqual(self.adapter.calls, 2)
        self.assertIsNone(self.registry.load("deployment-a"))

    def test_stale_wrong_or_paired_target_fails_before_product_mutation(self):
        wrong = ComponentOperationRequest(
            "forge-b-remove", "forge-runtime", "remove", ARTIFACT,
            "forge-b", "server", {},
        )
        with self.assertRaisesRegex(ManagedForgeRemovalError, "reviewed target"):
            self.coordinator.remove(
                "deployment-a-remove", self.plan,
                request=wrong, adapter=self.adapter,
            )
        changed = ManagedDeployment(
            "deployment-a", 2, "Changed", self.current.components,
        )
        self.registry.replace(changed, expected_revision=1)
        with self.assertRaisesRegex(ManagedForgeRemovalError, "deployment changed"):
            self.remove()
        self.assertEqual(self.adapter.calls, 0)

        paired = ManagedDeployment(
            "deployment-a", 3, "Paired",
            self.current.components + (
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep"),
            ),
            ManagedPeerBinding("forge-a", "ep-a", "receipt:paired"),
        )
        self.registry.replace(paired, expected_revision=2)
        paired_plan = ManagedDeploymentPlanner.plan(paired, None)
        with self.assertRaisesRegex(ManagedForgeRemovalError, "Forge-only"):
            self.coordinator.remove(
                "deployment-a-remove", paired_plan,
                request=self.request, adapter=self.adapter,
            )
        self.assertEqual(self.adapter.calls, 0)

    def test_currency_and_product_support_fail_closed(self):
        self.guard.fail = True
        with self.assertRaisesRegex(RuntimeError, "currency unavailable"):
            self.remove()
        self.assertEqual(self.adapter.calls, 0)
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        self.guard.fail = False
        self.adapter.removal_support = lambda: "UNSUPPORTED"
        with self.assertRaisesRegex(ManagedForgeRemovalError, "unavailable"):
            self.remove()
        self.assertEqual(self.adapter.calls, 0)

    def test_lost_terminal_readback_and_unknown_prior_operation_fail_closed(self):
        self.remove()
        altered = ComponentOperationRequest(
            self.request.operation_id, "forge-runtime", "remove",
            QualifiedArtifact(
                "2.7.35", "f" * 40, "https://example.invalid/other.whl",
                "sha256:" + "c" * 64,
                "https://example.invalid/qualification",
            ),
            "forge-a", "server", {},
        )
        with self.assertRaisesRegex(ManagedForgeRemovalError, "terminal readback"):
            self.coordinator.remove(
                "deployment-a-remove", self.plan,
                request=altered, adapter=self.adapter,
            )
        self.adapter.receipt = "forge-uninstall:sha256:" + "c" * 64
        with self.assertRaisesRegex(ManagedForgeRemovalError, "terminal readback"):
            self.remove()
        self.assertEqual(self.adapter.calls, 1)
        other_request = ComponentOperationRequest(
            "new-remove", "forge-runtime", "remove", ARTIFACT,
            "forge-a", "server", {},
        )
        with self.assertRaisesRegex(ManagedForgeRemovalError, "prior operation"):
            self.coordinator.remove(
                "new-deployment-remove", self.plan,
                request=other_request, adapter=self.adapter,
            )
