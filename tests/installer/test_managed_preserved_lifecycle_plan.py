#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2,
    ManagedComponentBinding,
    ManagedCompositionBinding,
    ManagedDeployment,
    ManagedDeploymentError,
    ManagedPeerBinding,
    ManagedPreservedComponentBinding,
    ManagedPreservedDeployment,
)
from forge_platform.managed_preserved_lifecycle_plan import (
    prepare_preserved_lifecycle_review,
    require_current_preserved_lifecycle_review,
)
from forge_platform.product_preserved_lifecycle import EP_COMPONENT, FORGE_COMPONENT
from tests.installer.test_product_preserved_lifecycle import _artifact
from tests.installer.test_released_product_routes import verified_forge_ep_selection
from tests.installer.test_universal_installer import current_context


def _fixture():
    base = verified_forge_ep_selection(current_context()).manifest
    artifacts = {component: _artifact(component) for component in (FORGE_COMPONENT, EP_COMPONENT)}
    manifest = replace(
        base, manifest_digest="sha256:" + "d" * 64,
        components=tuple(
            replace(item, artifact=artifacts[item.identity])
            for item in base.components
        ),
    )
    binding = ManagedCompositionBinding(
        manifest.composition_id, manifest.manifest_digest, "receipt:installed-composition",
    )
    pair = ManagedDeployment(
        "reviewed-pair", 1, None,
        (
            ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:forge-a"),
            ManagedComponentBinding(EP_COMPONENT, "ep-a", "receipt:ep-a"),
        ),
        ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-a"),
        MANAGED_DEPLOYMENT_SCHEMA_V2, binding,
    )
    forge = artifacts[FORGE_COMPONENT]
    preserved = ManagedPreservedComponentBinding(
        FORGE_COMPONENT, "forge-a", "receipt:forge-a", "preserve-a",
        "sha256:" + "e" * 64, forge.version, forge.source_revision,
        forge.digest, "forge-a", "install-a",
    )
    partly_preserved = ManagedPreservedDeployment(
        "reviewed-pair", 2, None,
        (ManagedComponentBinding(EP_COMPONENT, "ep-a", "receipt:ep-a"),),
        composition_binding=binding, preserved_components=(preserved,),
        historical_peer_binding=pair.peer_binding,
    )
    return manifest, pair, partly_preserved


class ManagedPreservedLifecyclePlanTests(unittest.TestCase):
    def test_preserve_restore_and_purge_bind_exact_state(self) -> None:
        manifest, pair, preserved = _fixture()
        preserve = prepare_preserved_lifecycle_review(
            current=pair, installed_manifest=manifest, operation="PRESERVE",
            operation_id="preserve-a", component=FORGE_COMPONENT,
            instance_id="forge-a",
        )
        self.assertEqual(preserve.registry_revision, 1)
        self.assertEqual(preserve.previous_receipt_reference, "receipt:forge-a")
        self.assertIsNone(preserve.preserve_operation_id)
        self.assertEqual(preserve.historical_peer_reference, "receipt:pair-a")
        self.assertFalse(preserve.destructive_confirmation_required)

        restore = prepare_preserved_lifecycle_review(
            current=preserved, installed_manifest=manifest, operation="RESTORE",
            operation_id="restore-a", component=FORGE_COMPONENT,
            instance_id="forge-a",
        )
        self.assertEqual(restore.preserve_operation_id, "preserve-a")
        self.assertEqual(restore.preserve_receipt_digest, "sha256:" + "e" * 64)
        self.assertEqual(restore.historical_peer_reference, "receipt:pair-a")
        self.assertNotEqual(restore.review_fingerprint, preserve.review_fingerprint)
        require_current_preserved_lifecycle_review(
            restore, current=preserved, installed_manifest=manifest,
        )

        purge = prepare_preserved_lifecycle_review(
            current=preserved, installed_manifest=manifest, operation="PURGE",
            operation_id="purge-a", component=FORGE_COMPONENT,
            instance_id="forge-a",
        )
        self.assertTrue(purge.destructive_confirmation_required)
        self.assertEqual(purge.preserve_operation_id, "preserve-a")
        self.assertNotEqual(purge.review_fingerprint, restore.review_fingerprint)

        ep_preserve = prepare_preserved_lifecycle_review(
            current=preserved, installed_manifest=manifest, operation="PRESERVE",
            operation_id="preserve-ep", component=EP_COMPONENT,
            instance_id="ep-a",
        )
        self.assertEqual(ep_preserve.previous_receipt_reference, "receipt:ep-a")
        self.assertIsNone(ep_preserve.preserve_operation_id)

        active_purge = prepare_preserved_lifecycle_review(
            current=pair, installed_manifest=manifest, operation="PURGE",
            operation_id="purge-ep", component=EP_COMPONENT, instance_id="ep-a",
        )
        self.assertTrue(active_purge.destructive_confirmation_required)
        self.assertIsNone(active_purge.preserve_operation_id)
        self.assertEqual(active_purge.previous_receipt_reference, "receipt:ep-a")

    def test_wrong_state_instance_release_or_composition_fails_closed(self) -> None:
        manifest, pair, preserved = _fixture()
        common = dict(
            installed_manifest=manifest, operation="RESTORE", operation_id="restore-a",
            component=FORGE_COMPONENT, instance_id="forge-a",
        )
        with self.assertRaisesRegex(ManagedDeploymentError, "state or instance"):
            prepare_preserved_lifecycle_review(current=pair, **common)
        with self.assertRaisesRegex(ManagedDeploymentError, "state or instance"):
            prepare_preserved_lifecycle_review(
                current=preserved, **(common | {"instance_id": "forge-b"}),
            )
        with self.assertRaisesRegex(ManagedDeploymentError, "state or instance"):
            prepare_preserved_lifecycle_review(
                current=preserved, **(common | {"operation": "PRESERVE"}),
            )
        with self.assertRaisesRegex(ManagedDeploymentError, "composition changed"):
            prepare_preserved_lifecycle_review(
                current=preserved,
                **(common | {"installed_manifest": replace(
                    manifest, manifest_digest="sha256:" + "a" * 64,
                )}),
            )
        changed_components = tuple(
            replace(item, artifact=replace(item.artifact, version="2.7.99"))
            if item.identity == FORGE_COMPONENT else item
            for item in manifest.components
        )
        with self.assertRaisesRegex(ManagedDeploymentError, "frozen lifecycle"):
            prepare_preserved_lifecycle_review(
                current=preserved,
                **(common | {"installed_manifest": replace(
                    manifest, components=changed_components,
                )}),
            )
        with self.assertRaisesRegex(ManagedDeploymentError, "review target is invalid"):
            prepare_preserved_lifecycle_review(
                current=preserved, **(common | {"operation_id": "bad/path"}),
            )
        with self.assertRaisesRegex(ManagedDeploymentError, "review target is invalid"):
            prepare_preserved_lifecycle_review(
                current=preserved, **(common | {"operation": "DELETE"}),
            )

    def test_review_must_be_fresh_before_product_mutation(self) -> None:
        manifest, _, preserved = _fixture()
        args = dict(
            current=preserved, installed_manifest=manifest, operation="RESTORE",
            operation_id="restore-a", component=FORGE_COMPONENT, instance_id="forge-a",
        )
        review = prepare_preserved_lifecycle_review(**args)
        with self.assertRaisesRegex(ManagedDeploymentError, "inventory changed"):
            require_current_preserved_lifecycle_review(
                review, current=replace(preserved, revision=3),
                installed_manifest=manifest,
            )
        with self.assertRaisesRegex(ManagedDeploymentError, "inventory changed"):
            require_current_preserved_lifecycle_review(
                review, current=replace(preserved, label="changed"),
                installed_manifest=manifest,
            )
        changed_preserve = replace(
            preserved.preserved_components[0],
            preserve_receipt_digest="sha256:" + "f" * 64,
        )
        with self.assertRaisesRegex(ManagedDeploymentError, "inventory changed"):
            require_current_preserved_lifecycle_review(
                review,
                current=replace(preserved, preserved_components=(changed_preserve,)),
                installed_manifest=manifest,
            )
        with self.assertRaisesRegex(ManagedDeploymentError, "composition changed"):
            require_current_preserved_lifecycle_review(
                review, current=preserved,
                installed_manifest=replace(manifest, manifest_digest="sha256:" + "a" * 64),
            )


if __name__ == "__main__":
    unittest.main()
