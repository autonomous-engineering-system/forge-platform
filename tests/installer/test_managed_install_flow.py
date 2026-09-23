#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import (
    ComponentOperationRequest,
    ProductInstallationReadback,
    ProductOperationReceipt,
    QualifiedArtifact,
)
from forge_platform.managed_deployments import (
    ManagedComponentBinding,
    ManagedDeployment,
    ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from forge_platform.managed_install_flow import (
    ManagedForgeEPInstallationCoordinator,
    ManagedForgeEPInstallationError,
)
from forge_platform.managed_pairing import ManagedPairingEvidence


ARTIFACT = QualifiedArtifact(
    "1.0.0",
    "a" * 40,
    "https://example.invalid/component.whl",
    "sha256:" + "b" * 64,
    "https://example.invalid/qualification",
)


def binding(component: str, instance: str) -> ManagedComponentBinding:
    return ManagedComponentBinding(component, instance, f"receipt:{component}-{instance}")


def desired(deployment_id: str = "production") -> ManagedDeployment:
    return ManagedDeployment(
        deployment_id,
        1,
        "Production",
        (
            binding("forge-runtime", "forge-prod"),
            binding("engineering-platform-server", "ep-prod"),
        ),
    )


def request(component: str, instance: str, operation_id: str, kind: str = "install"):
    return ComponentOperationRequest(
        operation_id, component, kind, ARTIFACT, instance, "server", {}
    )


class Guard:
    def __init__(self, *, fail_mutation: str | None = None) -> None:
        self.calls = []
        self.fail_mutation = fail_mutation

    def require_current(
        self, *, deployment_id, mutation, component, instance_id, operation_id
    ):
        self.calls.append((deployment_id, mutation, component, instance_id, operation_id))
        if mutation == self.fail_mutation:
            raise RuntimeError("installer update required")
        return f"currency:{len(self.calls)}"


class Adapter:
    def __init__(self, component: str, instance: str, *, pending_once: bool = False):
        self.component = component
        self.instance = instance
        self.pending_once = pending_once
        self.active = False
        self.ready = True
        self.execute_calls = 0
        self.resume_calls = 0
        self.readback_calls = 0

    def readback(self, req):
        self.readback_calls += 1
        if not self.active:
            return ProductInstallationReadback(
                self.component, self.instance, "ABSENT",
                None, None, None, None, None,
                "UNKNOWN", "MACHINE_WIDE", "NONE",
                f"evidence:{self.component}:absent",
            )
        state = "ACTIVE" if self.ready else "UNHEALTHY"
        health = "HEALTHY" if self.ready else "UNHEALTHY"
        return ProductInstallationReadback(
            self.component,
            self.instance,
            state,
            f"runtime:{self.component}",
            f"exec:{self.component}",
            f"server:{self.component}",
            self.instance,
            req.artifact.correlation,
            health,
            "MACHINE_WIDE",
            "NONE",
            f"evidence:{self.component}:active",
            f"health:{self.component}:ready",
        )

    def assess_update(self, req):
        raise AssertionError("fresh-install tests do not assess update")

    def execute(self, req):
        self.execute_calls += 1
        if self.pending_once:
            self.pending_once = False
            return ProductOperationReceipt(
                req.operation_id, self.component, self.instance,
                req.artifact.correlation, "CLEANUP_PENDING",
                f"evidence:{self.component}:pending",
                f"cleanup:{self.component}:pending",
            )
        self.active = True
        return ProductOperationReceipt(
            req.operation_id, self.component, self.instance,
            req.artifact.correlation, "COMPLETED",
            f"evidence:{self.component}:complete",
        )

    def resume(self, req, prior_receipt):
        self.resume_calls += 1
        self.active = True
        return ProductOperationReceipt(
            req.operation_id, self.component, self.instance,
            req.artifact.correlation, "COMPLETED",
            f"evidence:{self.component}:complete",
        )


class Pairer:
    def __init__(self, *, forge="forge-prod", ep="ep-prod"):
        self.forge = forge
        self.ep = ep
        self.calls = 0

    def pair(
        self, *, operation_id, deployment, forge_request, ep_request,
        forge_adapter, ep_adapter,
    ):
        self.calls += 1
        return ManagedPairingEvidence(
            self.forge,
            self.ep,
            "evidence:forge-peer-config",
            "evidence:forge-preflight-pass",
            "evidence:ep-readiness-pass",
        )


class ManagedForgeEPInstallFlowTests(unittest.TestCase):
    def _fixture(self, directory, *, guard=None, pending_ep=False, deployment_id="production"):
        root = Path(directory).resolve()
        registry = ManagedDeploymentRegistry(root / "registry")
        guard = guard or Guard()
        coordinator = ManagedForgeEPInstallationCoordinator(
            operations_root=root / "flow",
            component_operations_root=root / "components",
            registry=registry,
            currency_guard=guard,
        )
        forge = Adapter("forge-runtime", "forge-prod")
        ep = Adapter("engineering-platform-server", "ep-prod", pending_once=pending_ep)
        adapters = {
            "forge-runtime": forge,
            "engineering-platform-server": ep,
        }
        reads = {
            "forge-runtime": request("forge-runtime", "forge-prod", "read-forge"),
            "engineering-platform-server": request(
                "engineering-platform-server", "ep-prod", "read-ep"
            ),
        }
        mutations = {
            "forge-runtime": request("forge-runtime", "forge-prod", "op-forge"),
            "engineering-platform-server": request(
                "engineering-platform-server", "ep-prod", "op-ep"
            ),
        }
        plan = ManagedDeploymentPlanner.plan(None, desired(deployment_id))
        return coordinator, registry, guard, forge, ep, adapters, reads, mutations, plan

    def test_fresh_forge_ep_route_commits_products_pairing_and_final_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            (coordinator, registry, guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory)
            pairer = Pairer()

            result = coordinator.execute(
                "install-1",
                plan,
                mutation_requests=mutations,
                readback_requests=reads,
                adapters=adapters,
                pairing_executor=pairer,
            )

            self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(result.registry_revision, 2)
            self.assertEqual(len(result.readiness_receipt_references), 2)
            self.assertEqual(pairer.calls, 1)
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(ep.execute_calls, 1)
            stored = registry.load("production")
            self.assertEqual(stored.revision, 2)
            self.assertEqual(stored.peer_binding.forge_instance_id, "forge-prod")
            self.assertEqual(stored.peer_binding.ep_instance_id, "ep-prod")
            mutations_seen = [call[1] for call in guard.calls]
            self.assertEqual(
                mutations_seen,
                [
                    "product-install",
                    "product-install",
                    "deployment-create",
                    "forge-ep-pairing",
                    "deployment-replace",
                ],
            )

    def test_currency_failure_before_second_product_prevents_that_mutation_and_registry_commit(self):
        class SecondProductGuard(Guard):
            def require_current(self, **kwargs):
                result = super().require_current(**kwargs)
                product_calls = [c for c in self.calls if c[1] == "product-install"]
                if len(product_calls) == 2:
                    raise RuntimeError("installer update required")
                return result

        with tempfile.TemporaryDirectory() as directory:
            guard = SecondProductGuard()
            (coordinator, registry, _guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory, guard=guard)
            with self.assertRaisesRegex(RuntimeError, "update required"):
                coordinator.execute(
                    "install-2", plan,
                    mutation_requests=mutations,
                    readback_requests=reads,
                    adapters=adapters,
                    pairing_executor=Pairer(),
                )
            # Alphabetical component order dispatches EP before Forge.
            self.assertEqual(ep.execute_calls, 1)
            self.assertEqual(forge.execute_calls, 0)
            self.assertIsNone(registry.load("production"))

    def test_currency_failure_before_pairing_keeps_components_but_no_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            guard = Guard(fail_mutation="forge-ep-pairing")
            (coordinator, registry, _guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory, guard=guard)
            pairer = Pairer()
            with self.assertRaisesRegex(RuntimeError, "update required"):
                coordinator.execute(
                    "install-3", plan,
                    mutation_requests=mutations,
                    readback_requests=reads,
                    adapters=adapters,
                    pairing_executor=pairer,
                )
            stored = registry.load("production")
            self.assertEqual(stored.revision, 1)
            self.assertIsNone(stored.peer_binding)
            self.assertEqual(pairer.calls, 0)

    def test_recovery_pending_resumes_same_product_operation_then_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            (coordinator, registry, guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory, pending_ep=True)
            pairer = Pairer()
            first = coordinator.execute(
                "install-4", plan,
                mutation_requests=mutations,
                readback_requests=reads,
                adapters=adapters,
                pairing_executor=pairer,
            )
            self.assertEqual(first.state, "RECOVERY_PENDING")
            self.assertIsNone(registry.load("production"))
            self.assertEqual(pairer.calls, 0)

            second = coordinator.execute(
                "install-4", plan,
                mutation_requests=mutations,
                readback_requests=reads,
                adapters=adapters,
                pairing_executor=pairer,
            )
            self.assertEqual(second.state, "COMPLETE")
            self.assertEqual(ep.execute_calls, 1)
            self.assertEqual(ep.resume_calls, 1)
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(pairer.calls, 1)

    def test_final_readiness_failure_never_claims_complete_and_can_recover_without_repairing(self):
        with tempfile.TemporaryDirectory() as directory:
            (coordinator, registry, guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory)
            pairer = Pairer()
            ep.ready = False
            first = coordinator.execute(
                "install-5", plan,
                mutation_requests=mutations,
                readback_requests=reads,
                adapters=adapters,
                pairing_executor=pairer,
            )
            self.assertEqual(first.state, "READINESS_FAILED")
            self.assertEqual(registry.load("production").revision, 2)
            self.assertEqual(pairer.calls, 1)

            ep.ready = True
            second = coordinator.execute(
                "install-5", plan,
                mutation_requests=mutations,
                readback_requests=reads,
                adapters=adapters,
                pairing_executor=pairer,
            )
            self.assertEqual(second.state, "COMPLETE")
            # Durable product operation and terminal pairing are reused.
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(ep.execute_calls, 1)
            self.assertEqual(pairer.calls, 1)

    def test_unrelated_deployment_is_not_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            (coordinator, registry, guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory)
            other = ManagedDeployment(
                "other", 1, "Other",
                (
                    binding("forge-runtime", "forge-other"),
                    binding("engineering-platform-server", "ep-other"),
                ),
            )
            registry.create(other)
            before = registry.load("other")
            result = coordinator.execute(
                "install-6", plan,
                mutation_requests=mutations,
                readback_requests=reads,
                adapters=adapters,
                pairing_executor=Pairer(),
            )
            self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(registry.load("other"), before)

    def test_wrong_pairing_target_is_rejected_before_peer_registry_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            (coordinator, registry, guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory)
            with self.assertRaisesRegex(
                ManagedForgeEPInstallationError, "different instances"
            ):
                coordinator.execute(
                    "install-7", plan,
                    mutation_requests=mutations,
                    readback_requests=reads,
                    adapters=adapters,
                    pairing_executor=Pairer(forge="forge-wrong"),
                )
            stored = registry.load("production")
            self.assertEqual(stored.revision, 1)
            self.assertIsNone(stored.peer_binding)

    def test_route_rejects_incomplete_readiness_bindings_and_prebaked_fresh_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            (coordinator, registry, guard, forge, ep, adapters,
             reads, mutations, plan) = self._fixture(directory)
            incomplete_reads = {"forge-runtime": reads["forge-runtime"]}
            with self.assertRaisesRegex(
                ManagedForgeEPInstallationError, "final readiness"
            ):
                coordinator.execute(
                    "install-8", plan,
                    mutation_requests=mutations,
                    readback_requests=incomplete_reads,
                    adapters=adapters,
                    pairing_executor=Pairer(),
                )

            from forge_platform.managed_deployments import ManagedPeerBinding
            prebaked = ManagedDeployment(
                "prebaked", 1, None, desired("prebaked").components,
                ManagedPeerBinding("forge-prod", "ep-prod", "receipt:prebaked"),
            )
            bad_plan = ManagedDeploymentPlanner.plan(None, prebaked)
            with self.assertRaisesRegex(
                ManagedForgeEPInstallationError, "pre-authorize"
            ):
                coordinator.execute(
                    "install-9", bad_plan,
                    mutation_requests=mutations,
                    readback_requests=reads,
                    adapters=adapters,
                    pairing_executor=Pairer(),
                )


if __name__ == "__main__":
    unittest.main()
