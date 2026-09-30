from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

from forge_platform.component_operations import (
    ComponentOperationRequest, ProductInstallationReadback, ProductOperationReceipt,
)
from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingBinding
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedCompositionBinding, ManagedDeployment,
    ManagedDeploymentPlanner, ManagedDeploymentRegistry, ManagedPeerBinding,
    MANAGED_DEPLOYMENT_SCHEMA_V2,
)
from forge_platform.managed_paired_deployment_removal import (
    ManagedPairedDeploymentRemovalCoordinator, ManagedPairedDeploymentRemovalError,
)
from forge_platform.managed_paired_forge_removal import ManagedPairedForgeRemovalError
from forge_platform.managed_pairing_revocation import (
    ManagedPairingRevocationCoordinator, ManagedPairingRevocationError,
)
from forge_platform.managed_pairing_detach import (
    ManagedPairingDetachCoordinator, ManagedPairingDetachError,
)
from tests.installer.test_managed_paired_forge_removal import (
    EP_ARTIFACT, FORGE_ARTIFACT, FORGE_239_ARTIFACT, ForgeAdapter, Guard, Revoker,
)


EP_RECEIPT = "ep-receipt:sha256:" + "b" * 64


class EPRemovalAdapter:
    def __init__(self):
        self.active = True
        self.mutations = 0
        self.rechecks = 0
        self.receipt = EP_RECEIPT

    def readback(self, request):
        if self.active:
            return ProductInstallationReadback(
                "engineering-platform-server", "ep-a", "ACTIVE",
                "runtime:ep", "executable:ep", "service:ep", "ep-a",
                request.artifact.correlation, "HEALTHY", "MACHINE_WIDE", "NONE",
                "ep-inventory:active", "ep-health:ready",
            )
        return ProductInstallationReadback(
            "engineering-platform-server", "ep-a", "ABSENT", None, None,
            None, None, None, "UNKNOWN", "MACHINE_WIDE", "NONE",
            "ep-inventory:absent",
        )

    def assess_update(self, request):
        raise AssertionError("remove must not assess an update")

    def execute(self, request):
        self.mutations += 1
        self.active = False
        return ProductOperationReceipt(
            request.operation_id, "engineering-platform-server", "ep-a",
            request.artifact.correlation, "COMPLETED", self.receipt,
        )

    def resume(self, request, prior_receipt):
        self.rechecks += 1
        if self.active:
            raise AssertionError("terminal EP removal cannot return while instance is active")
        return ProductOperationReceipt(
            request.operation_id, "engineering-platform-server", "ep-a",
            request.artifact.correlation, "COMPLETED", self.receipt,
        )


class ManagedPairedDeploymentRemovalTests(unittest.TestCase):
    def enable_239_detachment(self):
        root = Path(self.temporary.name).resolve()
        self.forge_request = replace(self.forge_request, artifact=FORGE_239_ARTIFACT)
        binding = ForgeEPProductPairingBinding(
            "binding-a", "http://127.0.0.1:9001", "ep-a", "consumer-a",
            "host-a", "project-a", "repo-a", "owner:repo",
            "keychain://forge/ep-a", "operator-a", True,
        )
        detachment = ManagedPairingDetachCoordinator(
            operations_root=root / "detach", registry=self.registry,
            currency_guard=self.guard, expected_owner_uid=os.getuid(),
        )
        self.coordinator.detachment = detachment
        self.coordinator.pairing_binding = binding
        return detachment

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
            schema=MANAGED_DEPLOYMENT_SCHEMA_V2, composition_binding=self.composition,
        )
        self.other = ManagedDeployment(
            "deployment-b", 1, "Paired B", (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
                ManagedComponentBinding("engineering-platform-server", "ep-b", "receipt:ep-b"),
            ), ManagedPeerBinding("forge-b", "ep-b", "receipt:pair-b"),
        )
        self.registry.create(self.current)
        self.registry.create(self.other)
        self.plan = ManagedDeploymentPlanner.plan(self.current, None)
        self.forge_request = ComponentOperationRequest(
            "forge-a-remove", "forge-runtime", "remove", FORGE_ARTIFACT,
            "forge-a", "server", {},
        )
        self.ep_request = ComponentOperationRequest(
            "ep-a-remove", "engineering-platform-server", "remove", EP_ARTIFACT,
            "ep-a", "server", {},
        )
        self.guard = Guard()
        self.scope = EPConsumerScope("consumer-a", "project-a")
        self.revoker = Revoker(self.scope)
        self.revocation = ManagedPairingRevocationCoordinator(
            operations_root=root / "revocation", registry=self.registry,
            currency_guard=self.guard,
            scope_claims={
                "deployment-a": self.scope,
                "deployment-b": EPConsumerScope("consumer-b", "project-b"),
            },
            expected_owner_uid=root.stat().st_uid,
        )
        self.coordinator = ManagedPairedDeploymentRemovalCoordinator(
            operations_root=root / "operations",
            component_operations_root=root / "components",
            registry=self.registry, currency_guard=self.guard,
            revocation=self.revocation,
        )
        self.forge = ForgeAdapter()
        self.ep = EPRemovalAdapter()

    def remove(self):
        return self.coordinator.remove(
            "deployment-a-remove", self.plan, reviewed_current=self.current,
            forge_request=self.forge_request, forge_adapter=self.forge,
            ep_request=self.ep_request, ep_adapter=self.ep,
            revoker=self.revoker,
        )

    def test_exact_full_remove_and_duplicate_preserve_other_bytes(self):
        other_bytes = (self.registry.root / "deployment-b.json").read_bytes()
        first = self.remove()
        self.assertEqual(first.state, "COMPLETE")
        self.assertIsNone(self.registry.load("deployment-a"))
        self.assertEqual((self.registry.root / "deployment-b.json").read_bytes(), other_bytes)
        self.assertEqual(self.remove(), first)
        self.assertEqual(self.ep.mutations, 1)
        self.assertEqual(self.forge.calls, 1)
        self.assertEqual(self.revoker.mutations, 1)
        self.assertGreaterEqual(self.ep.rechecks, 2)

    def test_239_detach_precedes_full_removal_and_survives_forge_resume(self):
        detachment = self.enable_239_detachment()
        self.forge.pending_once = True
        other_bytes = (self.registry.root / "deployment-b.json").read_bytes()
        def before_product_removal(*_args, **_kwargs):
            self.assertEqual(self.ep.mutations, 0)
            self.assertEqual(self.forge.calls, 0)
            return object()

        with patch.object(detachment, "detach", side_effect=before_product_removal) as detach, patch.object(
            detachment, "read_terminal", return_value=object(),
        ) as terminal:
            self.assertEqual(self.remove().state, "RECOVERY_PENDING")
            self.assertEqual(detach.call_count, 1)
            self.assertEqual(self.ep.mutations, 1)
            self.assertEqual(self.remove().state, "COMPLETE")
            self.assertEqual(detach.call_count, 1)
            self.assertGreaterEqual(terminal.call_count, 2)
            self.assertEqual(self.remove().state, "COMPLETE")
        self.assertIsNone(self.registry.load("deployment-a"))
        self.assertEqual((self.registry.root / "deployment-b.json").read_bytes(), other_bytes)

    def test_239_missing_detach_authority_blocks_both_product_removals(self):
        self.forge_request = replace(self.forge_request, artifact=FORGE_239_ARTIFACT)
        with self.assertRaisesRegex(ManagedPairedDeploymentRemovalError, "detach authority"):
            self.remove()
        self.assertEqual(self.ep.mutations, 0)
        self.assertEqual(self.forge.calls, 0)
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_239_missing_terminal_detach_blocks_registry_removal(self):
        detachment = self.enable_239_detachment()
        with patch.object(detachment, "detach", return_value=object()), patch.object(
            detachment, "read_terminal",
            side_effect=ManagedPairingDetachError("terminal receipt lost"),
        ):
            with self.assertRaisesRegex(ManagedPairingDetachError, "terminal receipt"):
                self.remove()
        self.assertEqual(self.ep.mutations, 1)
        self.assertEqual(self.forge.calls, 1)
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_resume_after_ep_removed_and_forge_interrupted(self):
        self.forge.pending_once = True
        first = self.remove()
        self.assertEqual(first.state, "RECOVERY_PENDING")
        self.assertFalse(self.ep.active)
        self.assertEqual(self.registry.load("deployment-a"), self.current)
        second = self.remove()
        self.assertEqual(second.state, "COMPLETE")
        self.assertEqual(self.ep.mutations, 1)
        self.assertEqual(self.forge.resumes, 1)
        self.assertEqual(self.revoker.mutations, 1)

    def test_missing_ep_terminal_receipt_blocks_forge_resume(self):
        self.forge.pending_once = True
        self.assertEqual(self.remove().state, "RECOVERY_PENDING")
        self.ep.receipt = "ep-receipt:sha256:" + "f" * 64
        with self.assertRaises(ManagedPairedDeploymentRemovalError):
            self.remove()
        self.assertEqual(self.forge.resumes, 0)
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_missing_ep_component_journal_after_removal_fails_closed(self):
        self.forge.pending_once = True
        self.assertEqual(self.remove().state, "RECOVERY_PENDING")
        journal = self.coordinator.component_operations_root / "ep-a-remove" / "record.json"
        journal.unlink()
        with self.assertRaises(ManagedPairedDeploymentRemovalError):
            self.remove()
        self.assertEqual(self.forge.resumes, 0)
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_wrong_forge_receipt_blocks_registry_removal(self):
        self.forge.receipt = "forge-uninstall:sha256:" + "f" * 64
        original = self.forge.readback

        def inconsistent(request):
            result = original(request)
            if result.state == "ABSENT":
                return ProductInstallationReadback(
                    "forge-runtime", "forge-a", "ABSENT", None, None, None,
                    None, None, "UNKNOWN", "MACHINE_WIDE", "NONE",
                    "forge-uninstall:sha256:" + "d" * 64,
                )
            return result

        self.forge.readback = inconsistent
        with self.assertRaises(ManagedPairedForgeRemovalError):
            self.remove()
        self.assertEqual(self.registry.load("deployment-a"), self.current)

    def test_wrong_consumer_scope_blocks_all_product_removals(self):
        self.revoker.scope = EPConsumerScope("consumer-b", "project-b")
        with self.assertRaises(ManagedPairingRevocationError):
            self.remove()
        self.assertEqual(self.ep.mutations, 0)
        self.assertEqual(self.forge.calls, 0)

    def test_wrong_target_and_stale_registry_fail_before_product_mutation(self):
        self.ep_request = ComponentOperationRequest(
            "ep-b-remove", "engineering-platform-server", "remove", EP_ARTIFACT,
            "ep-b", "server", {},
        )
        with self.assertRaises(ManagedPairedDeploymentRemovalError):
            self.remove()
        self.ep_request = ComponentOperationRequest(
            "ep-a-remove", "engineering-platform-server", "remove", EP_ARTIFACT,
            "ep-a", "server", {},
        )
        self.registry.replace(
            ManagedDeployment(
                "deployment-a", 2, "Changed", self.current.components,
                self.current.peer_binding, schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=self.composition,
            ), expected_revision=1,
        )
        with self.assertRaises(ManagedPairedDeploymentRemovalError):
            self.remove()
        self.assertEqual(self.ep.mutations, 0)
        self.assertEqual(self.forge.calls, 0)
        self.assertEqual(self.revoker.mutations, 0)

    def test_unqualified_release_or_artifact_digest_blocks_both_removals(self):
        for component, original, old_version in (
            ("forge", self.forge_request, "2.7.36"),
            ("ep", self.ep_request, "2.3.103"),
        ):
            for artifact in (
                replace(original.artifact, version=old_version),
                replace(original.artifact, digest="sha256:" + "0" * 64),
            ):
                setattr(self, f"{component}_request", replace(original, artifact=artifact))
                with self.subTest(component=component, artifact=artifact), self.assertRaises(
                    ManagedPairedDeploymentRemovalError
                ):
                    self.remove()
            setattr(self, f"{component}_request", original)
        self.assertEqual(self.ep.mutations, 0)
        self.assertEqual(self.forge.calls, 0)
        self.assertEqual(self.revoker.mutations, 0)


if __name__ == "__main__":
    unittest.main()
