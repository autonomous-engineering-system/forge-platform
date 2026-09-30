#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import (
    ProductInstallationReadback, ProductOperationReceipt,
)
from forge_platform.engineering_platform_system_adapter import (
    EngineeringPlatformSystemProvisionerAdapter, EPSystemInstanceTarget,
    ProductCommandResult,
)
from forge_platform.managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2, ManagedComponentBinding, ManagedDeployment,
    ManagedDeploymentRegistry, ManagedPreservedComponentBinding, ManagedPreservedDeployment,
)
from forge_platform.managed_ep_restore_execution import (
    ManagedEPRestoreExecutionCoordinator, ManagedEPRestoreExecutionError,
    _read as read_restore_journal,
    _write as write_restore_journal,
)
from forge_platform.managed_preserve_execution import (
    ManagedPreserveExecutionRecord, _write as write_preserve_journal,
)
from forge_platform.managed_preserved_lifecycle_plan import prepare_preserved_lifecycle_review
from forge_platform.managed_preserved_product_adapters import EPPreservedProductAdapter
from forge_platform.product_preserved_lifecycle import EP_COMPONENT, EP_CONTRACT
from tests.installer.test_managed_preserve_execution import Currency
from tests.installer.test_managed_preserved_lifecycle_plan import _fixture
from tests.installer.test_managed_preserved_product_adapters import (
    FakeRunner, _ep_evidence, _wire,
)
from tests.installer.test_product_preserved_lifecycle import _artifact, _receipt_digest


class ManagedEPRestoreExecutionTests(unittest.TestCase):
    def _scenario(self, root: Path):
        manifest, active, _ = _fixture()
        artifact = _artifact(EP_COMPONENT)
        registry = ManagedDeploymentRegistry(root / "registry")
        registry.create(active)
        preserved = ManagedPreservedDeployment(
            active.deployment_id, 2, active.label, (),
            composition_binding=active.composition_binding,
            preserved_components=(ManagedPreservedComponentBinding(
                EP_COMPONENT, "ep-a", "receipt:ep-a", "preserve-ep",
                "sha256:" + "e" * 64, artifact.version,
                artifact.source_revision, artifact.digest,
            ),),
        )
        registry._write(preserved)
        review = prepare_preserved_lifecycle_review(
            current=preserved, installed_manifest=manifest, operation="RESTORE",
            operation_id="restore-ep", component=EP_COMPONENT, instance_id="ep-a",
        )
        preserve_root = root / "preserved-lifecycle"
        preserve_root.mkdir(mode=0o700)
        lock = preserve_root / ".reviewed-pair.lock"
        lock.touch(mode=0o600)
        os.chmod(lock, 0o600)
        write_preserve_journal(
            preserve_root / "preserve-ep.json",
            ManagedPreserveExecutionRecord(
                "preserve-ep", "reviewed-pair", "sha256:" + "a" * 64,
                EP_COMPONENT, "ep-a", "COMPLETE", "sha256:" + "e" * 64, 2,
            ),
        )
        target = EPSystemInstanceTarget("ep-a", "EP A", "_ep", 8766)
        restore_receipt, restore_status = _ep_evidence(
            "RESTORE", "restore-ep", "ep-a", "preserve-ep",
        )
        restore_receipt["evidence"].update({
            "restored": True,
            "shared_immutable_runtime_slots": "PRESERVED",
            "release": {
                "version": artifact.version,
                "artifact_digest": artifact.digest,
                "source_revision": artifact.source_revision,
            },
        })
        restore_receipt["receipt_sha256"] = _receipt_digest(
            EP_COMPONENT, {
                key: value for key, value in restore_receipt.items()
                if key != "receipt_sha256"
            },
        )
        restore_status["receipt_sha256"] = restore_receipt["receipt_sha256"]
        preserve_status = {
            "contract": EP_CONTRACT, "operation": "PRESERVE",
            "operation_id": "preserve-ep", "instance_id": "ep-a",
            "phase": "COMPLETE", "state": "COMPLETE",
            "lifecycle_state": "UNINSTALLED_DATA_PRESERVED",
            "restorable": True, "receipt_sha256": "sha256:" + "e" * 64,
        }
        outer = {
            "contract": EP_CONTRACT, "result": "COMPLETE",
            "instance_id": "ep-a", "receipt": restore_receipt,
        }
        runner = FakeRunner(ProductCommandResult, (
            (0, _wire(preserve_status)), (0, _wire(outer)),
            (0, _wire(restore_status)), (0, _wire(restore_status)),
            (0, _wire(restore_status)),
        ), repeat_terminal_status=True)
        wheel = root / "ep.whl"
        wheel.write_bytes(b"released-wheel-fixture")
        lifecycle = EPPreservedProductAdapter(
            provisioner_executable=root / "ep-provisioner", product_root=root / "ep",
            target=target, artifact=artifact, staged_wheel=wheel,
            launch_daemons_directory=root / "daemons", runner=runner,
        )
        system = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=root / "ep-provisioner", product_root=root / "ep",
            target=target, staged_artifacts={artifact.digest: wheel},
        )
        currency = Currency()
        coordinator = ManagedEPRestoreExecutionCoordinator(
            operations_root=root / "restore", preserve_operations_root=preserve_root,
            registry=registry, currency_guard=currency,
            expected_owner_uid=os.getuid(),
        )
        repair_request = coordinator._repair_request(review)
        repair_receipt = ProductOperationReceipt(
            repair_request.operation_id, EP_COMPONENT, "ep-a",
            artifact.correlation, "COMPLETED", "ep-receipt:" + "b" * 64,
        )
        readback = ProductInstallationReadback(
            EP_COMPONENT, "ep-a", "ACTIVE", "ep-runtime:a", "ep-executable:a",
            "ep-server:a", "ep-a", artifact.correlation, "HEALTHY", "MACHINE_WIDE",
            "NONE", "ep-inventory:" + "c" * 64,
            "ep-status:" + "d" * 64,
        )
        return (manifest, registry, review, lifecycle, system, runner, currency,
                coordinator, preserve_status, repair_receipt, readback)

    def test_interrupted_provider_repair_resumes_same_restore_and_commits_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (manifest, registry, review, lifecycle, system, runner, currency,
             coordinator, preserve_status, repair_receipt, readback) = self._scenario(root)
            registry.create(ManagedDeployment(
                "other-deployment", 1, None,
                (ManagedComponentBinding(EP_COMPONENT, "ep-b", "receipt:ep-b"),),
                schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=registry.load("reviewed-pair").composition_binding,
            ))
            sibling_before = (registry.root / "other-deployment.json").read_bytes()
            class MatchingDigest:
                def hexdigest(self):
                    return review.artifact.digest.removeprefix("sha256:")
            with (
                patch("forge_platform.managed_preserved_product_adapters.sha256",
                      return_value=MatchingDigest()),
                patch.object(system, "execute", side_effect=(
                    RuntimeError("provider verification pending"), repair_receipt,
                )) as repair,
                patch.object(system, "readback", return_value=readback) as observe,
            ):
                with self.assertRaisesRegex(RuntimeError, "provider verification pending"):
                    coordinator.restore(
                        review, installed_manifest=manifest,
                        lifecycle=lifecycle, system=system,
                    )
                self.assertEqual(registry.load("reviewed-pair").revision, 2)
                self.assertEqual(read_restore_journal(
                    root / "restore/restore-restore-ep.json", os.getuid(), review,
                ).state, "PRODUCT_TERMINAL")
                runner.results.append((0, _wire(preserve_status)))
                complete = coordinator.restore(
                    review, installed_manifest=manifest,
                    lifecycle=lifecycle, system=system,
                )
                self.assertEqual(complete.state, "COMPLETE")
                self.assertEqual(complete.registry_revision, 3)
                self.assertEqual(registry.load("reviewed-pair").active_by_component[
                    EP_COMPONENT].instance_id, "ep-a")
                replay = coordinator.restore(
                    review, installed_manifest=manifest,
                    lifecycle=lifecycle, system=system,
                )
                self.assertEqual(replay, complete)
            self.assertEqual(repair.call_count, 2)
            self.assertEqual(observe.call_count, 2)
            self.assertEqual(sum(call[1] == "restore" for call in runner.calls), 1)
            self.assertTrue(all(call["mutation"] == "RESTORE" for call in currency.calls))
            self.assertEqual((registry.root / "other-deployment.json").read_bytes(), sibling_before)

    def test_missing_preserve_journal_or_wrong_route_fails_before_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (manifest, registry, review, lifecycle, system, runner, _,
             coordinator, _, _, _) = self._scenario(root)
            (root / "preserved-lifecycle/preserve-ep.json").unlink()
            with self.assertRaises(Exception):
                coordinator.restore(
                    review, installed_manifest=manifest,
                    lifecycle=lifecycle, system=system,
                )
            self.assertEqual(runner.calls, [])
            with self.assertRaises(ManagedEPRestoreExecutionError):
                coordinator.restore(
                    replace(review, instance_id="ep-other"),
                    installed_manifest=manifest, lifecycle=lifecycle, system=system,
                )
            self.assertEqual(registry.load("reviewed-pair").revision, 2)

    def test_stale_installer_authority_stops_before_product_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (manifest, registry, review, lifecycle, system, runner, currency,
             coordinator, _, _, _) = self._scenario(root)
            currency.denied = True
            with self.assertRaisesRegex(RuntimeError, "installer is stale"):
                coordinator.restore(
                    review, installed_manifest=manifest,
                    lifecycle=lifecycle, system=system,
                )
            self.assertEqual(registry.load("reviewed-pair").revision, 2)
            self.assertEqual(read_restore_journal(
                root / "restore/restore-restore-ep.json", os.getuid(), review,
            ).state, "PREPARED")
            self.assertTrue(all(call[1] == "lifecycle-status" for call in runner.calls))

    def test_changed_durable_operation_identity_rejects_resume_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (manifest, registry, review, lifecycle, system, runner, _,
             coordinator, _, _, _) = self._scenario(root)
            class MatchingDigest:
                def hexdigest(self):
                    return review.artifact.digest.removeprefix("sha256:")
            with (
                patch("forge_platform.managed_preserved_product_adapters.sha256",
                      return_value=MatchingDigest()),
                patch.object(system, "execute", side_effect=RuntimeError("providers pending")),
            ):
                with self.assertRaisesRegex(RuntimeError, "providers pending"):
                    coordinator.restore(
                        review, installed_manifest=manifest,
                        lifecycle=lifecycle, system=system,
                    )
            path = root / "restore/restore-restore-ep.json"
            changed = json.loads(path.read_bytes())
            changed["instance_id"] = "ep-other"
            path.write_bytes(_wire(changed).encode())
            calls_before = len(runner.calls)
            with self.assertRaises(ManagedEPRestoreExecutionError):
                coordinator.restore(
                    review, installed_manifest=manifest,
                    lifecycle=lifecycle, system=system,
                )
            self.assertEqual(len(runner.calls), calls_before)
            self.assertEqual(registry.load("reviewed-pair").revision, 2)

    def test_registry_commit_crash_replays_without_second_product_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (manifest, registry, review, lifecycle, system, runner, _,
             coordinator, _, repair_receipt, readback) = self._scenario(root)
            class MatchingDigest:
                def hexdigest(self):
                    return review.artifact.digest.removeprefix("sha256:")
            def interrupted_write(path, record):
                if record.state == "COMPLETE":
                    raise OSError("simulated journal fsync interruption")
                write_restore_journal(path, record)
            with (
                patch("forge_platform.managed_preserved_product_adapters.sha256",
                      return_value=MatchingDigest()),
                patch.object(system, "execute", return_value=repair_receipt) as repair,
                patch.object(system, "readback", return_value=readback) as observe,
            ):
                with patch("forge_platform.managed_ep_restore_execution._write",
                           side_effect=interrupted_write):
                    with self.assertRaisesRegex(OSError, "fsync interruption"):
                        coordinator.restore(
                            review, installed_manifest=manifest,
                            lifecycle=lifecycle, system=system,
                        )
                self.assertEqual(registry.load("reviewed-pair").revision, 3)
                self.assertEqual(read_restore_journal(
                    root / "restore/restore-restore-ep.json", os.getuid(), review,
                ).state, "REPAIRED")
                result = coordinator.restore(
                    review, installed_manifest=manifest,
                    lifecycle=lifecycle, system=system,
                )
                self.assertEqual(result.state, "COMPLETE")
            self.assertEqual(repair.call_count, 1)
            self.assertEqual(observe.call_count, 2)
            self.assertEqual(sum(call[1] == "restore" for call in runner.calls), 1)


if __name__ == "__main__":
    unittest.main()
