#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.managed_deployments import (
    ManagedComponentBinding,
    ManagedDeployment,
    ManagedDeploymentRegistry,
)
from forge_platform.managed_pairing import (
    ManagedDeploymentPairingCoordinator,
    ManagedPairingError,
    ManagedPairingEvidence,
)


def binding(component: str, instance: str) -> ManagedComponentBinding:
    return ManagedComponentBinding(component, instance, f"receipt:{component}-{instance}")


def evidence(forge: str = "forge-prod", ep: str = "ep-prod") -> ManagedPairingEvidence:
    return ManagedPairingEvidence(
        forge,
        ep,
        "evidence:forge-peer-config",
        "evidence:forge-ep-preflight-pass",
        "evidence:ep-instance-readiness-pass",
    )


class ManagedPairingTests(unittest.TestCase):
    def test_terminal_pairing_evidence_binds_exact_instances_and_advances_revision(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(ManagedDeployment(
                "production",
                1,
                "Production",
                (
                    binding("forge-runtime", "forge-prod"),
                    binding("engineering-platform-server", "ep-prod"),
                ),
            ))
            updated = ManagedDeploymentPairingCoordinator(registry).commit(
                "production", expected_revision=1, evidence=evidence(),
            )
            self.assertEqual(updated.revision, 2)
            self.assertEqual(updated.peer_binding.forge_instance_id, "forge-prod")
            self.assertEqual(updated.peer_binding.ep_instance_id, "ep-prod")
            self.assertTrue(updated.peer_binding.receipt_reference.startswith("receipt:pairing-"))

    def test_pairing_is_idempotent_for_same_terminal_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(ManagedDeployment(
                "production", 1, None,
                (
                    binding("forge-runtime", "forge-prod"),
                    binding("engineering-platform-server", "ep-prod"),
                ),
            ))
            coordinator = ManagedDeploymentPairingCoordinator(registry)
            first = coordinator.commit("production", expected_revision=1, evidence=evidence())
            second = coordinator.commit("production", expected_revision=2, evidence=evidence())
            self.assertEqual(second, first)

    def test_wrong_instance_or_stale_revision_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(ManagedDeployment(
                "production", 1, None,
                (
                    binding("forge-runtime", "forge-prod"),
                    binding("engineering-platform-server", "ep-prod"),
                ),
            ))
            coordinator = ManagedDeploymentPairingCoordinator(registry)
            with self.assertRaisesRegex(ManagedPairingError, "different product instances"):
                coordinator.commit("production", expected_revision=1, evidence=evidence(forge="forge-other"))
            with self.assertRaisesRegex(ManagedPairingError, "revision changed"):
                coordinator.commit("production", expected_revision=2, evidence=evidence())

    def test_pairing_requires_both_components_and_rejects_secret_shaped_reference(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(ManagedDeployment(
                "ep-only", 1, None,
                (binding("engineering-platform-server", "ep-prod"),),
            ))
            with self.assertRaisesRegex(ManagedPairingError, "both Forge and EP"):
                ManagedDeploymentPairingCoordinator(registry).commit(
                    "ep-only", expected_revision=1, evidence=evidence(),
                )
        with self.assertRaisesRegex(ValueError, "secret material"):
            ManagedPairingEvidence(
                "forge-prod", "ep-prod",
                "authorization:Bearer token", "evidence:preflight", "evidence:ready",
            )


if __name__ == "__main__":
    unittest.main()
