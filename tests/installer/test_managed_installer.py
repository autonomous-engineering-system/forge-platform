#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

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
from forge_platform.managed_installer import ManagedDeploymentOperationCoordinator


ARTIFACT = QualifiedArtifact(
    "1.0.0", "a" * 40, "https://example.invalid/component.whl",
    "sha256:" + "b" * 64, "https://example.invalid/qualification",
)


def binding(component: str, instance: str) -> ManagedComponentBinding:
    return ManagedComponentBinding(component, instance, f"receipt:{component}-{instance}")


def desired(revision: int = 1) -> ManagedDeployment:
    return ManagedDeployment(
        "production",
        revision,
        "Production",
        (
            binding("forge-runtime", "forge-prod"),
            binding("engineering-platform-server", "ep-prod"),
        ),
        None,
    )


def readback(component: str, instance: str, state: str = "ABSENT") -> ProductInstallationReadback:
    if state == "ABSENT":
        return ProductInstallationReadback(
            component, instance, "ABSENT", None, None, None, None, None,
            "UNKNOWN", "MACHINE_WIDE", "NONE", f"evidence:{component}:absent",
        )
    return ProductInstallationReadback(
        component, instance, "ACTIVE", f"runtime:{component}", f"exec:{component}",
        f"server:{component}", instance, ARTIFACT.correlation, "HEALTHY",
        "MACHINE_WIDE", "NONE", f"evidence:{component}:active", f"health:{component}",
    )


class Adapter:
    def __init__(self, component: str, instance: str, *, pending_once: bool = False) -> None:
        self.component = component
        self.instance = instance
        self.pending_once = pending_once
        self.execute_calls = 0
        self.resume_calls = 0
        self.active = False

    def readback(self, request):
        return readback(self.component, self.instance, "ACTIVE" if self.active else "ABSENT")

    def assess_update(self, request):
        raise AssertionError("not used")

    def execute(self, request):
        self.execute_calls += 1
        if self.pending_once:
            self.pending_once = False
            return ProductOperationReceipt(
                request.operation_id, self.component, self.instance, ARTIFACT.correlation,
                "CLEANUP_PENDING", f"evidence:{self.component}:pending", f"cleanup:{self.component}",
            )
        self.active = request.kind != "remove"
        return ProductOperationReceipt(
            request.operation_id, self.component, self.instance, ARTIFACT.correlation,
            "COMPLETED", f"evidence:{self.component}:complete",
        )

    def resume(self, request, prior_receipt):
        self.resume_calls += 1
        self.active = request.kind != "remove"
        return ProductOperationReceipt(
            request.operation_id, self.component, self.instance, ARTIFACT.correlation,
            "COMPLETED", f"evidence:{self.component}:complete",
        )


class ManagedInstallerTests(unittest.TestCase):
    def request(self, component: str, instance: str, operation: str) -> ComponentOperationRequest:
        return ComponentOperationRequest(operation, component, "install", ARTIFACT, instance, "server", {})

    def test_partial_deployment_resumes_same_component_operation_and_commits_registry_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            plan = ManagedDeploymentPlanner.plan(None, desired())
            forge, ep = Adapter("forge-runtime", "forge-prod"), Adapter(
                "engineering-platform-server", "ep-prod", pending_once=True,
            )
            coordinator = ManagedDeploymentOperationCoordinator(
                operations_root=root / "deployments",
                component_operations_root=root / "components",
                registry=registry,
            )
            requests = {
                "forge-runtime": self.request("forge-runtime", "forge-prod", "deploy-1-forge"),
                "engineering-platform-server": self.request(
                    "engineering-platform-server", "ep-prod", "deploy-1-ep"
                ),
            }
            adapters = {"forge-runtime": forge, "engineering-platform-server": ep}

            first = coordinator.execute("deploy-1", plan, requests=requests, adapters=adapters)
            self.assertEqual(first.state, "RECOVERY_PENDING")
            self.assertIsNone(registry.load("production"))
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(ep.execute_calls, 1)

            completed = coordinator.execute("deploy-1", plan, requests=requests, adapters=adapters)
            self.assertEqual(completed.state, "COMPLETE")
            self.assertEqual(completed.registry_revision, 1)
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(ep.execute_calls, 1)
            self.assertEqual(ep.resume_calls, 1)
            stored = registry.load("production")
            self.assertIsNotNone(stored)
            self.assertEqual({item.instance_id for item in stored.components}, {"forge-prod", "ep-prod"})

    def test_reviewed_diff_must_match_exact_product_requests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            coordinator = ManagedDeploymentOperationCoordinator(
                operations_root=root / "deployments",
                component_operations_root=root / "components",
                registry=ManagedDeploymentRegistry(root / "registry"),
            )
            plan = ManagedDeploymentPlanner.plan(None, desired())
            requests = {
                "forge-runtime": self.request("forge-runtime", "forge-WRONG", "deploy-2-forge"),
                "engineering-platform-server": self.request(
                    "engineering-platform-server", "ep-prod", "deploy-2-ep"
                ),
            }
            with self.assertRaisesRegex(Exception, "target changed"):
                coordinator.execute(
                    "deploy-2",
                    plan,
                    requests=requests,
                    adapters={
                        "forge-runtime": Adapter("forge-runtime", "forge-WRONG"),
                        "engineering-platform-server": Adapter("engineering-platform-server", "ep-prod"),
                    },
                )

    def test_no_change_does_not_dispatch_product_and_update_is_exact_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            registry.create(desired())
            next_state = ManagedDeployment(
                "production", 2, "Production",
                desired().components, None,
            )
            plan = ManagedDeploymentPlanner.plan(
                desired(), next_state,
                product_actions={
                    "forge-runtime": "NO_CHANGE",
                    "engineering-platform-server": "UPDATE",
                },
            )
            ep_adapter = Adapter("engineering-platform-server", "ep-prod")
            ep_adapter.active = True
            update_request = ComponentOperationRequest(
                "deploy-update-ep", "engineering-platform-server", "update",
                QualifiedArtifact(
                    "1.1.0", "c" * 40, ARTIFACT.source, "sha256:" + "d" * 64,
                    ARTIFACT.qualification,
                ),
                "ep-prod", "server", {},
            )

            class UpdateAdapter(Adapter):
                def assess_update(self, request):
                    from forge_platform.component_operations import ProductUpdateAssessment
                    return ProductUpdateAssessment(
                        request.component, request.installation_identity,
                        request.artifact.correlation, "UPDATE_AVAILABLE", "evidence:update",
                    )

                def execute(self, request):
                    self.execute_calls += 1
                    self.active = True
                    return ProductOperationReceipt(
                        request.operation_id, self.component, self.instance,
                        request.artifact.correlation, "COMPLETED", "evidence:update:complete",
                    )

                def readback(self, request):
                    if request.kind == "update":
                        return ProductInstallationReadback(
                            self.component, self.instance, "ACTIVE", "runtime:new", "exec:new",
                            "server:ep", self.instance, request.artifact.correlation, "HEALTHY",
                            "MACHINE_WIDE", "NONE", "evidence:active", "health:active",
                        )
                    return super().readback(request)

            adapter = UpdateAdapter("engineering-platform-server", "ep-prod")
            adapter.active = True
            coordinator = ManagedDeploymentOperationCoordinator(
                operations_root=root / "deployments",
                component_operations_root=root / "components",
                registry=registry,
            )
            completed = coordinator.execute(
                "deploy-update",
                plan,
                requests={"engineering-platform-server": update_request},
                adapters={"engineering-platform-server": adapter},
            )
            self.assertEqual(completed.state, "COMPLETE")
            self.assertEqual(adapter.execute_calls, 1)
            self.assertEqual(registry.load("production").revision, 2)


if __name__ == "__main__":
    unittest.main()
