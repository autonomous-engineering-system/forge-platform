#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.engineering_platform_system_adapter import EPSystemInstanceTarget, ProductCommandResult
from forge_platform.forge_server_adapter import ForgeCommandResult, ForgeServerTarget, _forge_product_digest
from forge_platform.managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2, ManagedDeployment, ManagedDeploymentRegistry,
)
from forge_platform.managed_preserve_execution import (
    ManagedPreserveExecutionCoordinator, ManagedPreserveExecutionError,
)
from forge_platform.managed_preserved_lifecycle_plan import prepare_preserved_lifecycle_review
from forge_platform.managed_preserved_product_adapters import (
    EPPreservedProductAdapter, ForgePreservedProductAdapter,
)
from forge_platform.product_preserved_lifecycle import EP_COMPONENT, EP_CONTRACT, FORGE_COMPONENT
from tests.installer.test_managed_preserved_lifecycle_plan import _fixture
from tests.installer.test_managed_preserved_product_adapters import (
    FakeRunner, _ep_evidence, _forge_evidence, _wire,
)
from tests.installer.test_product_preserved_lifecycle import _artifact


class Currency:
    def __init__(self):
        self.calls = []
        self.denied = False

    def require_current(self, **kwargs):
        self.calls.append(kwargs)
        if self.denied:
            raise RuntimeError("installer is stale")
        return "currency:qualified"


class Supervisor:
    def __init__(self):
        self.is_loaded = True
        self.calls = []
        self.fail_remove = False

    def loaded(self, target):
        self.calls.append(("loaded", target.instance_id))
        return self.is_loaded

    def stop(self, target):
        self.calls.append(("stop", target.instance_id))
        self.is_loaded = False
        return {"result": "STOPPED"}

    def remove(self, target):
        self.calls.append(("remove", target.instance_id))
        if self.fail_remove:
            raise RuntimeError("remove failed")
        return {"result": "REMOVED"}


class ManagedPreserveExecutionTests(unittest.TestCase):
    def _state(self, root, component=FORGE_COMPONENT):
        manifest, active, _ = _fixture()
        registry = ManagedDeploymentRegistry(root / "registry")
        registry.create(active)
        instance = "forge-a" if component == FORGE_COMPONENT else "ep-a"
        review = prepare_preserved_lifecycle_review(
            current=active, installed_manifest=manifest, operation="PRESERVE",
            operation_id="preserve-a", component=component, instance_id=instance,
        )
        currency = Currency()
        supervisor = Supervisor()
        coordinator = ManagedPreserveExecutionCoordinator(
            operations_root=root / "operations", registry=registry,
            currency_guard=currency, forge_supervisor=supervisor,
            expected_owner_uid=os.getuid(),
        )
        return manifest, registry, active, review, currency, supervisor, coordinator

    @staticmethod
    def _forge_adapter(root):
        target = ForgeServerTarget(
            "forge-a", root / "instances" / "forge-a", root / "instances",
            "_forge", 8765, root / "credentials" / "forge-a.json",
        )
        artifact = _artifact(FORGE_COMPONENT)
        request = {
            "operation_id": "preserve-a", "instance_id": "forge-a",
            "runtime_id": "forge-a", "installation_id": "Install-A",
            "installed_version": artifact.version,
            "installed_source": artifact.source_revision,
            "installed_artifact_digest": artifact.digest,
            "data_root": str(target.data_root), "instances_root": str(target.instances_root),
        }
        receipt, status = _forge_evidence(
            "PRESERVE", "preserve-a", "forge-a", "Install-A",
            _forge_product_digest(request),
        )
        runner = FakeRunner(ForgeCommandResult, ((0, _wire(receipt)), (0, _wire(status))))
        adapter = ForgePreservedProductAdapter(
            lifecycle_executable=root / "forge", target=target,
            installation_id="Install-A", artifact=artifact, runner=runner,
        )
        return adapter, runner, receipt

    @staticmethod
    def _ep_adapter(root):
        receipt, status = _ep_evidence("PRESERVE", "preserve-a", "ep-a")
        outer = {"contract": EP_CONTRACT, "result": "COMPLETE", "instance_id": "ep-a", "receipt": receipt}
        runner = FakeRunner(ProductCommandResult, ((0, _wire(outer)), (0, _wire(status))))
        adapter = EPPreservedProductAdapter(
            provisioner_executable=root / "ep", product_root=root / "ep-root",
            target=EPSystemInstanceTarget("ep-a", "EP A", "_ep", 8766),
            artifact=_artifact(EP_COMPONENT), staged_wheel=root / "ep.whl",
            launch_daemons_directory=root / "daemons", runner=runner,
        )
        return adapter, runner, receipt

    def test_forge_preserve_commits_only_selected_instance_and_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active, review, currency, supervisor, coordinator = self._state(root)
            sibling = ManagedDeployment(
                "other-deployment", 1, None,
                (replace(active.active_by_component[FORGE_COMPONENT], instance_id="forge-b"),),
                schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=active.composition_binding,
            )
            registry.create(sibling)
            adapter, runner, receipt = self._forge_adapter(root)
            result = coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(result.registry_revision, 2)
            current = registry.load(active.deployment_id)
            self.assertEqual(current.preserved_by_component[FORGE_COMPONENT].instance_id, "forge-a")
            self.assertEqual(current.preserved_by_component[FORGE_COMPONENT].forge_installation_id, "Install-A")
            self.assertEqual(current.active_by_component[EP_COMPONENT].instance_id, "ep-a")
            self.assertEqual(current.historical_peer_binding, active.peer_binding)
            self.assertEqual(registry.load(sibling.deployment_id), sibling)
            self.assertIsNone(current.peer_binding)
            self.assertEqual([call[0] for call in supervisor.calls].count("remove"), 1)
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual(len(currency.calls), 4)
            self.assertEqual(coordinator.preserve(
                review, installed_manifest=manifest, adapter=adapter,
            ), result)
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual([call[0] for call in supervisor.calls].count("remove"), 1)
            self.assertNotIn("Install-A", (root / "operations" / "preserve-a.json").read_text())
            self.assertNotIn("data_root", (root / "operations" / "preserve-a.json").read_text())
            self.assertEqual(receipt["receipt_digest"], result.receipt_digest)

    def test_interrupted_service_removal_resumes_same_product_operation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active, review, _, supervisor, coordinator = self._state(root)
            adapter, _, _ = self._forge_adapter(root)
            supervisor.fail_remove = True
            with self.assertRaisesRegex(RuntimeError, "remove failed"):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(registry.load(active.deployment_id), active)
            self.assertIn("PRODUCT_TERMINAL", (root / "operations" / "preserve-a.json").read_text())
            supervisor.fail_remove = False
            resumed, runner, _ = self._forge_adapter(root)
            result = coordinator.preserve(review, installed_manifest=manifest, adapter=resumed)
            self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual(registry.load(active.deployment_id).revision, 2)

    def test_unsafe_journal_and_missing_registry_evidence_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active, review, _, supervisor, coordinator = self._state(root)
            adapter, runner, _ = self._forge_adapter(root)
            operations = root / "operations"
            operations.mkdir(mode=0o755)
            with self.assertRaisesRegex(ManagedPreserveExecutionError, "root is unsafe"):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            operations.chmod(0o700)
            journal = operations / "preserve-a.json"
            journal.symlink_to(root / "other")
            with self.assertRaises(OSError):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            journal.unlink()
            registry.remove(active.deployment_id, expected_revision=1)
            with self.assertRaisesRegex(ManagedPreserveExecutionError, "unavailable"):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(supervisor.calls, [])
            self.assertEqual(runner.calls, [])

    def test_ep_preserve_does_not_touch_forge_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active, review, currency, supervisor, coordinator = self._state(root, EP_COMPONENT)
            adapter, runner, _ = self._ep_adapter(root)
            result = coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(registry.load(active.deployment_id).active_by_component[FORGE_COMPONENT].instance_id, "forge-a")
            self.assertEqual(registry.load(active.deployment_id).preserved_by_component[EP_COMPONENT].instance_id, "ep-a")
            self.assertEqual(supervisor.calls, [])
            self.assertEqual(len(currency.calls), 2)
            self.assertEqual(len(runner.calls), 2)

    def test_stale_review_and_currency_denial_stop_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active, review, currency, supervisor, coordinator = self._state(root)
            adapter, runner, _ = self._forge_adapter(root)
            registry.replace(replace(active, revision=2), expected_revision=1)
            with self.assertRaisesRegex(ManagedPreserveExecutionError, "stale"):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(supervisor.calls, [])
            self.assertEqual(runner.calls, [])
            review = prepare_preserved_lifecycle_review(
                current=registry.load(active.deployment_id), installed_manifest=manifest,
                operation="PRESERVE", operation_id="preserve-b",
                component=FORGE_COMPONENT, instance_id="forge-a",
            )
            currency.denied = True
            with self.assertRaisesRegex(RuntimeError, "stale"):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(supervisor.calls, [])
            self.assertEqual(runner.calls, [])

    def test_foreign_target_journal_and_restarted_service_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, _, review, _, supervisor, coordinator = self._state(root)
            adapter, runner, _ = self._forge_adapter(root)
            wrong = replace(review, instance_id="forge-b")
            with self.assertRaisesRegex(ManagedPreserveExecutionError, "not sealed"):
                coordinator.preserve(wrong, installed_manifest=manifest, adapter=adapter)
            result = coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            supervisor.is_loaded = True
            with self.assertRaisesRegex(ManagedPreserveExecutionError, "no exact terminal"):
                coordinator.preserve(review, installed_manifest=manifest, adapter=adapter)
            supervisor.is_loaded = False
            foreign = replace(review, review_fingerprint="sha256:" + "a" * 64)
            with self.assertRaisesRegex(ManagedPreserveExecutionError, "identity changed"):
                coordinator.preserve(foreign, installed_manifest=manifest, adapter=adapter)
            self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(len(runner.calls), 2)


if __name__ == "__main__":
    unittest.main()
