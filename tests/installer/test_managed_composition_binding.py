#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.managed_composition_binding import (
    ManagedCompositionCommitCoordinator,
    ManagedCompositionCommitError,
    ManagedCompositionTerminalEvidence,
)
from forge_platform.managed_deployments import (
    ManagedComponentBinding,
    ManagedDeployment,
    ManagedDeploymentRegistry,
    ManagedPeerBinding,
)


def evidence(*, pairing: str | None = "receipt:peer-prod") -> ManagedCompositionTerminalEvidence:
    return ManagedCompositionTerminalEvidence(
        composition_id="forge-ep-stable-001",
        manifest_digest="sha256:" + "a" * 64,
        composition_catalog_sequence=12,
        composition_catalog_digest="sha256:" + "b" * 64,
        component_catalog_sequence=13,
        component_catalog_digest="sha256:" + "c" * 64,
        product_receipt_references=("receipt:forge-product", "receipt:ep-product"),
        readiness_receipt_references=("receipt:forge-ready", "receipt:ep-ready"),
        pairing_receipt_reference=pairing,
    )


class ManagedCompositionBindingTests(unittest.TestCase):
    def test_terminal_evidence_binds_exact_composition_after_pairing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            deployment = ManagedDeployment(
                "production", 1, "Production",
                (
                    ManagedComponentBinding("forge-runtime", "forge-prod", "receipt:forge-product"),
                    ManagedComponentBinding("engineering-platform-server", "ep-prod", "receipt:ep-product"),
                ),
                ManagedPeerBinding("forge-prod", "ep-prod", "receipt:peer-prod"),
            )
            registry.create(deployment)
            updated = ManagedCompositionCommitCoordinator(registry).commit(
                "production", expected_revision=1, evidence=evidence()
            )
            self.assertEqual(updated.revision, 2)
            self.assertEqual(updated.composition_binding.composition_id, "forge-ep-stable-001")
            self.assertEqual(updated.composition_binding.manifest_digest, "sha256:" + "a" * 64)
            self.assertTrue(updated.composition_binding.receipt_reference.startswith("receipt:composition-"))

    def test_stale_revision_wrong_pairing_and_missing_receipt_coverage_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(ManagedDeployment(
                "production", 1, None,
                (
                    ManagedComponentBinding("forge-runtime", "forge-prod", "receipt:forge-product"),
                    ManagedComponentBinding("engineering-platform-server", "ep-prod", "receipt:ep-product"),
                ),
                ManagedPeerBinding("forge-prod", "ep-prod", "receipt:peer-prod"),
            ))
            coordinator = ManagedCompositionCommitCoordinator(registry)
            with self.assertRaisesRegex(ManagedCompositionCommitError, "revision changed"):
                coordinator.commit("production", expected_revision=2, evidence=evidence())
            with self.assertRaisesRegex(ManagedCompositionCommitError, "pairing evidence"):
                coordinator.commit(
                    "production", expected_revision=1, evidence=evidence(pairing="receipt:peer-other")
                )
            incomplete = ManagedCompositionTerminalEvidence(
                composition_id="forge-ep-stable-001",
                manifest_digest="sha256:" + "a" * 64,
                composition_catalog_sequence=12,
                composition_catalog_digest="sha256:" + "b" * 64,
                component_catalog_sequence=13,
                component_catalog_digest="sha256:" + "c" * 64,
                product_receipt_references=("receipt:forge-product",),
                readiness_receipt_references=("receipt:forge-ready", "receipt:ep-ready"),
                pairing_receipt_reference="receipt:peer-prod",
            )
            with self.assertRaisesRegex(ManagedCompositionCommitError, "coverage"):
                coordinator.commit("production", expected_revision=1, evidence=incomplete)

    def test_single_component_needs_no_pairing_but_still_requires_readiness(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(ManagedDeployment(
                "ep-only", 1, None,
                (ManagedComponentBinding("engineering-platform-server", "ep-prod", "receipt:ep-product"),),
            ))
            single = ManagedCompositionTerminalEvidence(
                composition_id="ep-only-stable-001",
                manifest_digest="sha256:" + "d" * 64,
                composition_catalog_sequence=14,
                composition_catalog_digest="sha256:" + "e" * 64,
                component_catalog_sequence=15,
                component_catalog_digest="sha256:" + "f" * 64,
                product_receipt_references=("receipt:ep-product",),
                readiness_receipt_references=("receipt:ep-ready",),
            )
            updated = ManagedCompositionCommitCoordinator(registry).commit(
                "ep-only", expected_revision=1, evidence=single,
            )
            self.assertEqual(updated.composition_binding.composition_id, "ep-only-stable-001")

    def test_secret_shaped_terminal_reference_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "secret material"):
            ManagedCompositionTerminalEvidence(
                composition_id="ep-only-stable-001",
                manifest_digest="sha256:" + "a" * 64,
                composition_catalog_sequence=1,
                composition_catalog_digest="sha256:" + "b" * 64,
                component_catalog_sequence=1,
                component_catalog_digest="sha256:" + "c" * 64,
                product_receipt_references=("receipt:secret=bad",),
                readiness_receipt_references=("receipt:ready",),
            )


if __name__ == "__main__":
    unittest.main()
