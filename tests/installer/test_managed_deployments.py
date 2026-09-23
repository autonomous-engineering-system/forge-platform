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
    ManagedDeploymentError,
    ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
    ManagedPeerBinding,
)


def binding(component: str, instance: str) -> ManagedComponentBinding:
    return ManagedComponentBinding(component, instance, f"receipt:{component}-{instance}")


def deployment(
    deployment_id: str = "production",
    *,
    revision: int = 1,
    forge: str | None = "forge-prod",
    ep: str | None = "ep-prod",
) -> ManagedDeployment:
    components = tuple(
        item for item in (
            binding("forge-runtime", forge) if forge else None,
            binding("engineering-platform-server", ep) if ep else None,
        ) if item is not None
    )
    peer = (
        ManagedPeerBinding(forge, ep, "receipt:peer-production")
        if forge is not None and ep is not None else None
    )
    return ManagedDeployment(deployment_id, revision, "Production", components, peer)


class ManagedDeploymentTests(unittest.TestCase):
    def test_registry_persists_multiple_deployments_and_never_conflates_instances(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            first = registry.create(deployment())
            second = registry.create(deployment("development", forge="forge-dev", ep="ep-dev"))
            self.assertEqual({item.deployment_id for item in registry.inventory()}, {"production", "development"})
            self.assertEqual(registry.load("production"), first)
            self.assertEqual(registry.load("development"), second)
            self.assertEqual(oct((Path(directory) / "production.json").stat().st_mode & 0o777), "0o600")
            self.assertEqual(oct(Path(directory).stat().st_mode & 0o777), "0o700")

    def test_one_product_instance_cannot_be_claimed_by_two_managed_deployments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(deployment())
            with self.assertRaisesRegex(ManagedDeploymentError, "already belongs"):
                registry.create(deployment("other", forge="forge-prod", ep="ep-other"))

    def test_replace_is_revision_bound_and_remove_is_exact_target_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(deployment())
            registry.create(deployment("development", forge="forge-dev", ep="ep-dev"))
            replacement = deployment(revision=2, forge="forge-prod", ep=None)
            with self.assertRaisesRegex(ManagedDeploymentError, "revision changed"):
                registry.replace(replacement, expected_revision=2)
            registry.replace(replacement, expected_revision=1)
            removed = registry.remove("production", expected_revision=2)
            self.assertEqual(removed.deployment_id, "production")
            self.assertIsNone(registry.load("production"))
            self.assertIsNotNone(registry.load("development"))

    def test_topology_diff_is_scoped_to_selected_deployment(self) -> None:
        current = deployment()
        desired = deployment(revision=2, forge="forge-prod", ep=None)
        plan = ManagedDeploymentPlanner.plan(
            current, desired, product_actions={"forge-runtime": "UPDATE"},
        )
        self.assertEqual(
            {(item.component, item.action) for item in plan.component_diffs},
            {
                ("forge-runtime", "UPDATE"),
                ("engineering-platform-server", "REMOVE_COMPONENT"),
            },
        )
        self.assertEqual(plan.deployment_action, "CREATE_OR_UPDATE")

    def test_add_repair_no_change_and_remove_deployment_are_explicit(self) -> None:
        current = deployment(forge=None, ep="ep-prod")
        desired = deployment(revision=2, forge="forge-prod", ep="ep-prod")
        plan = ManagedDeploymentPlanner.plan(
            current, desired,
            product_actions={"forge-runtime": "ADD_COMPONENT", "engineering-platform-server": "REPAIR"},
        )
        self.assertEqual(
            [(item.component, item.action) for item in plan.component_diffs],
            [("engineering-platform-server", "REPAIR"), ("forge-runtime", "ADD_COMPONENT")],
        )
        removed = ManagedDeploymentPlanner.plan(desired, None)
        self.assertEqual(removed.deployment_action, "REMOVE_DEPLOYMENT")
        self.assertTrue(all(item.action == "REMOVE_COMPONENT" for item in removed.component_diffs))

    def test_existing_instance_replacement_requires_remove_then_add(self) -> None:
        with self.assertRaisesRegex(ManagedDeploymentError, "remove then add"):
            ManagedDeploymentPlanner.plan(
                deployment(),
                deployment(revision=2, forge="forge-other", ep="ep-prod"),
            )

    def test_peer_binding_must_join_exact_component_instances(self) -> None:
        with self.assertRaisesRegex(ValueError, "exact managed"):
            ManagedDeployment(
                "broken",
                1,
                None,
                (binding("forge-runtime", "forge-one"), binding("engineering-platform-server", "ep-one")),
                ManagedPeerBinding("forge-two", "ep-one", "receipt:peer-broken"),
            )

    def test_registry_rejects_corrupt_or_secret_shaped_receipts(self) -> None:
        with self.assertRaisesRegex(ValueError, "opaque receipt"):
            ManagedComponentBinding("forge-runtime", "forge-prod", "ghp_secret")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "production.json").write_text('{"not":"a deployment"}', encoding="utf-8")
            with self.assertRaisesRegex(ManagedDeploymentError, "record is invalid"):
                ManagedDeploymentRegistry(root).load("production")


if __name__ == "__main__":
    unittest.main()
