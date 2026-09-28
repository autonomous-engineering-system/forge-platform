#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget, ProductCommandResult,
)
from forge_platform.forge_server_adapter import (
    ForgeCommandResult, ForgeServerTarget, _forge_product_digest,
)
from forge_platform.managed_deployments import (
    ManagedDeploymentRegistry, ManagedPreservedComponentBinding,
    ManagedPreservedDeployment,
)
from forge_platform.managed_preserved_lifecycle_plan import prepare_preserved_lifecycle_review
from forge_platform.managed_preserved_product_adapters import (
    EPPreservedProductAdapter,
    ForgePreservedProductAdapter,
    ManagedPreservedProductAdapterError,
)
from forge_platform.product_preserved_lifecycle import (
    EP_COMPONENT, EP_CONTRACT, FORGE_COMPONENT,
)
from tests.installer.test_managed_preserved_lifecycle_plan import _fixture
from tests.installer.test_product_preserved_lifecycle import (
    _artifact, _receipt_digest, _terminal,
)


class FakeRunner:
    def __init__(self, result_type, results):
        self.result_type = result_type
        self.results = list(results)
        self.calls = []

    def run(self, argv):
        self.calls.append(tuple(argv))
        code, payload = self.results.pop(0)
        return self.result_type(code, payload, "")


def _wire(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _forge_evidence(operation, operation_id, instance_id, installation_id, request_digest):
    receipt, status = _terminal(FORGE_COMPONENT, operation)
    receipt.update({
        "operation_id": operation_id, "instance_id": instance_id,
        "runtime_id": instance_id, "installation_id": installation_id,
        "request_digest": request_digest,
    })
    if operation == "RESTORE":
        receipt["restored_from_preserve_operation"] = "preserve-a"
    receipt["receipt_digest"] = _receipt_digest(
        FORGE_COMPONENT, {key: value for key, value in receipt.items() if key != "receipt_digest"},
    )
    status.update({
        "operation_id": operation_id, "instance_id": instance_id,
        "request_digest": request_digest, "receipt_digest": receipt["receipt_digest"],
    })
    return receipt, status


def _ep_evidence(operation, operation_id, instance_id, preserve_operation_id="preserve-a"):
    receipt, status = _terminal(EP_COMPONENT, operation)
    receipt.update({"operation_id": operation_id, "instance_id": instance_id})
    if operation == "RESTORE":
        receipt["evidence"]["restored_from_preserve_operation"] = preserve_operation_id
    receipt["receipt_sha256"] = _receipt_digest(
        EP_COMPONENT, {key: value for key, value in receipt.items() if key != "receipt_sha256"},
    )
    status.update({
        "operation_id": operation_id, "instance_id": instance_id,
        "receipt_sha256": receipt["receipt_sha256"],
    })
    return receipt, status


class ManagedPreservedProductAdapterTests(unittest.TestCase):
    def _state(self, root, *, preserved=False):
        manifest, active, preserved_record = _fixture()
        registry = ManagedDeploymentRegistry(root / "registry")
        registry.create(active)
        if preserved:
            registry._write(preserved_record)
        return manifest, registry, preserved_record if preserved else active

    @staticmethod
    def _forge_target(root):
        instances = root / "instances"
        return ForgeServerTarget(
            "forge-a", instances / "forge-a", instances,
            "_forge", 8765, root / "credentials" / "forge-a.json",
        )

    def test_forge_preserve_and_restore_use_fixed_cli_and_product_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active = self._state(root)
            artifact = _artifact(FORGE_COMPONENT)
            target = self._forge_target(root)
            review = prepare_preserved_lifecycle_review(
                current=active, installed_manifest=manifest, operation="PRESERVE",
                operation_id="preserve-a", component=FORGE_COMPONENT, instance_id="forge-a",
            )
            request = {
                "operation_id": "preserve-a", "instance_id": "forge-a",
                "runtime_id": "forge-a", "installation_id": "install-a",
                "installed_version": artifact.version,
                "installed_source": artifact.source_revision,
                "installed_artifact_digest": artifact.digest,
                "data_root": str(target.data_root),
                "instances_root": str(target.instances_root),
            }
            receipt, status = _forge_evidence(
                "PRESERVE", "preserve-a", "forge-a", "install-a",
                _forge_product_digest(request),
            )
            runner = FakeRunner(ForgeCommandResult, ((0, _wire(receipt)), (0, _wire(status))))
            adapter = ForgePreservedProductAdapter(
                lifecycle_executable=root / "forge-lifecycle", target=target,
                installation_id="install-a", artifact=artifact, runner=runner,
            )
            terminal = adapter.invoke(review, registry=registry, installed_manifest=manifest)
            self.assertEqual(terminal.terminal.lifecycle_state, "UNINSTALLED_DATA_PRESERVED")
            self.assertEqual(terminal.receipt, receipt)
            self.assertEqual(terminal.status, status)
            self.assertEqual(runner.calls[0][0:5], (
                str(root / "forge-lifecycle"), "--data-root", str(target.data_root),
                "server", "preserve",
            ))
            self.assertEqual(runner.calls[1][1:3], ("server", "lifecycle-status"))

            manifest, registry, preserved = self._state(root / "restore", preserved=True)
            restore = prepare_preserved_lifecycle_review(
                current=preserved, installed_manifest=manifest, operation="RESTORE",
                operation_id="restore-a", component=FORGE_COMPONENT, instance_id="forge-a",
            )
            restore_request = request | {
                "operation_id": "restore-a", "preserve_operation_id": "preserve-a",
            }
            receipt, status = _forge_evidence(
                "RESTORE", "restore-a", "forge-a", "install-a",
                _forge_product_digest(restore_request),
            )
            runner = FakeRunner(ForgeCommandResult, ((0, _wire(receipt)), (0, _wire(status))))
            adapter = ForgePreservedProductAdapter(
                lifecycle_executable=root / "forge-lifecycle", target=target,
                installation_id="install-a", artifact=artifact, runner=runner,
            )
            self.assertEqual(adapter.invoke(
                restore, registry=registry, installed_manifest=manifest,
            ).terminal.lifecycle_state, "RESTORE_VALIDATED")
            self.assertIn("--preserve-operation-id", runner.calls[0])
            self.assertEqual(runner.calls[0][-1], "preserve-a")

    def test_ep_preserve_uses_fixed_provisioner_and_owning_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active = self._state(root)
            review = prepare_preserved_lifecycle_review(
                current=active, installed_manifest=manifest, operation="PRESERVE",
                operation_id="preserve-ep", component=EP_COMPONENT, instance_id="ep-a",
            )
            receipt, status = _ep_evidence("PRESERVE", "preserve-ep", "ep-a")
            outer = {"contract": EP_CONTRACT, "result": "COMPLETE", "instance_id": "ep-a", "receipt": receipt}
            runner = FakeRunner(ProductCommandResult, ((0, _wire(outer)), (0, _wire(status))))
            adapter = EPPreservedProductAdapter(
                provisioner_executable=root / "ep-provisioner", product_root=root / "ep",
                target=EPSystemInstanceTarget("ep-a", "EP A", "_ep", 8766),
                artifact=_artifact(EP_COMPONENT), staged_wheel=root / "ep.whl",
                launch_daemons_directory=root / "daemons", runner=runner,
            )
            self.assertEqual(adapter.invoke(
                review, registry=registry, installed_manifest=manifest,
            ).terminal.lifecycle_state, "UNINSTALLED_DATA_PRESERVED")
            self.assertEqual(runner.calls[0][0:2], (str(root / "ep-provisioner"), "preserve"))
            self.assertEqual(runner.calls[0][-2:], ("--confirm-instance-id", "ep-a"))
            self.assertEqual(runner.calls[1][1], "lifecycle-status")

    def test_forge_and_ep_purge_require_product_tombstones(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active = self._state(root)
            target = self._forge_target(root)
            artifact = _artifact(FORGE_COMPONENT)
            forge_review = prepare_preserved_lifecycle_review(
                current=active, installed_manifest=manifest, operation="PURGE",
                operation_id="purge-a", component=FORGE_COMPONENT, instance_id="forge-a",
            )
            request = {
                "operation_id": "purge-a", "instance_id": "forge-a",
                "runtime_id": "forge-a", "installation_id": "install-a",
                "installed_version": artifact.version,
                "installed_source": artifact.source_revision,
                "installed_artifact_digest": artifact.digest,
                "data_root": str(target.data_root),
                "instances_root": str(target.instances_root),
            }
            receipt, status = _forge_evidence(
                "PURGE", "purge-a", "forge-a", "install-a",
                _forge_product_digest(request),
            )
            runner = FakeRunner(ForgeCommandResult, ((0, _wire(receipt)), (0, _wire(status))))
            forge = ForgePreservedProductAdapter(
                lifecycle_executable=root / "forge-lifecycle", target=target,
                installation_id="install-a", artifact=artifact, runner=runner,
            )
            self.assertEqual(forge.invoke(
                forge_review, registry=registry, installed_manifest=manifest,
            ).terminal.lifecycle_state, "PURGED")
            self.assertEqual(runner.calls[0][4], "purge")

            ep_review = prepare_preserved_lifecycle_review(
                current=active, installed_manifest=manifest, operation="PURGE",
                operation_id="purge-ep", component=EP_COMPONENT, instance_id="ep-a",
            )
            receipt, status = _ep_evidence("PURGE", "purge-ep", "ep-a")
            outer = {"contract": EP_CONTRACT, "result": "COMPLETE", "instance_id": "ep-a", "receipt": receipt}
            runner = FakeRunner(ProductCommandResult, ((0, _wire(outer)), (0, _wire(status))))
            ep = EPPreservedProductAdapter(
                provisioner_executable=root / "ep-provisioner", product_root=root / "ep",
                target=EPSystemInstanceTarget("ep-a", "EP A", "_ep", 8766),
                artifact=_artifact(EP_COMPONENT), staged_wheel=root / "ep.whl",
                launch_daemons_directory=root / "daemons", runner=runner,
            )
            self.assertEqual(ep.invoke(
                ep_review, registry=registry, installed_manifest=manifest,
            ).terminal.lifecycle_state, "PURGED")
            self.assertEqual(runner.calls[0][1], "purge")

    def test_stale_review_wrong_target_and_bad_receipt_fail_before_or_after_cli(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active = self._state(root)
            review = prepare_preserved_lifecycle_review(
                current=active, installed_manifest=manifest, operation="PRESERVE",
                operation_id="preserve-a", component=FORGE_COMPONENT, instance_id="forge-a",
            )
            runner = FakeRunner(ForgeCommandResult, ())
            adapter = ForgePreservedProductAdapter(
                lifecycle_executable=root / "forge-lifecycle",
                target=self._forge_target(root), installation_id="install-a",
                artifact=_artifact(FORGE_COMPONENT), runner=runner,
            )
            registry.replace(replace(active, revision=2), expected_revision=1)
            with self.assertRaisesRegex(ManagedPreservedProductAdapterError, "stale"):
                adapter.invoke(review, registry=registry, installed_manifest=manifest)
            self.assertEqual(runner.calls, [])
            registry.replace(replace(active, revision=3), expected_revision=2)
            current = registry.load(active.deployment_id)
            review = prepare_preserved_lifecycle_review(
                current=current, installed_manifest=manifest, operation="PRESERVE",
                operation_id="preserve-a", component=FORGE_COMPONENT, instance_id="forge-a",
            )
            wrong_target = replace(self._forge_target(root), instance_id="forge-b",
                                   data_root=root / "instances" / "forge-b")
            wrong = ForgePreservedProductAdapter(
                lifecycle_executable=root / "forge-lifecycle", target=wrong_target,
                installation_id="install-a", artifact=_artifact(FORGE_COMPONENT), runner=runner,
            )
            with self.assertRaisesRegex(ManagedPreservedProductAdapterError, "target changed"):
                wrong.invoke(review, registry=registry, installed_manifest=manifest)
            self.assertEqual(runner.calls, [])
            runner = FakeRunner(ForgeCommandResult, ((0, "{\"bad\":true}"), (0, "{}")))
            adapter = ForgePreservedProductAdapter(
                lifecycle_executable=root / "forge-lifecycle", target=self._forge_target(root),
                installation_id="install-a", artifact=_artifact(FORGE_COMPONENT), runner=runner,
            )
            with self.assertRaisesRegex(ManagedPreservedProductAdapterError, "terminal evidence"):
                adapter.invoke(review, registry=registry, installed_manifest=manifest)

    def test_ep_restore_rejects_unavailable_or_wrong_released_wheel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, active = self._state(root)
            artifact = _artifact(EP_COMPONENT)
            preserved = ManagedPreservedDeployment(
                active.deployment_id, 2, active.label,
                (active.active_by_component[FORGE_COMPONENT],),
                composition_binding=active.composition_binding,
                preserved_components=(ManagedPreservedComponentBinding(
                    EP_COMPONENT, "ep-a", "receipt:ep-a", "preserve-ep",
                    "sha256:" + "e" * 64, artifact.version,
                    artifact.source_revision, artifact.digest,
                ),),
                historical_peer_binding=active.peer_binding,
            )
            registry._write(preserved)
            review = prepare_preserved_lifecycle_review(
                current=preserved, installed_manifest=manifest, operation="RESTORE",
                operation_id="restore-ep", component=EP_COMPONENT, instance_id="ep-a",
            )
            runner = FakeRunner(ProductCommandResult, ())
            adapter = EPPreservedProductAdapter(
                provisioner_executable=root / "ep-provisioner", product_root=root / "ep",
                target=EPSystemInstanceTarget("ep-a", "EP A", "_ep", 8766),
                artifact=artifact, staged_wheel=root / "ep.whl",
                launch_daemons_directory=root / "daemons", runner=runner,
            )
            with self.assertRaisesRegex(ManagedPreservedProductAdapterError, "wheel is unavailable"):
                adapter.invoke(review, registry=registry, installed_manifest=manifest)
            (root / "ep.whl").write_bytes(b"wrong released bytes")
            with self.assertRaisesRegex(ManagedPreservedProductAdapterError, "wheel bytes changed"):
                adapter.invoke(review, registry=registry, installed_manifest=manifest)
            self.assertEqual(runner.calls, [])

            receipt, status = _ep_evidence(
                "RESTORE", "restore-ep", "ep-a", "preserve-ep",
            )
            outer = {"contract": EP_CONTRACT, "result": "COMPLETE", "instance_id": "ep-a", "receipt": receipt}
            runner = FakeRunner(ProductCommandResult, ((0, _wire(outer)), (0, _wire(status))))
            adapter.runner = runner

            class MatchingDigest:
                def hexdigest(self):
                    return artifact.digest.removeprefix("sha256:")

            with patch("forge_platform.managed_preserved_product_adapters.sha256", return_value=MatchingDigest()):
                terminal = adapter.invoke(
                    review, registry=registry, installed_manifest=manifest,
                )
            self.assertEqual(terminal.terminal.lifecycle_state, "RESTORED_REQUIRES_PROVIDER_REVERIFICATION")
            self.assertIn("--preserve-operation-id", runner.calls[0])
            self.assertEqual(runner.calls[0][runner.calls[0].index("--preserve-operation-id") + 1], "preserve-ep")


if __name__ == "__main__":
    unittest.main()
