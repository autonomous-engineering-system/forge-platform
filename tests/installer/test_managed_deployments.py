#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2,
    MANAGED_DEPLOYMENT_SCHEMA_V3,
    ManagedComponentBinding,
    ManagedCompositionBinding,
    ManagedDeployment,
    ManagedDeploymentError,
    ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
    ManagedPeerBinding,
    ManagedPreservedComponentBinding,
)
from forge_platform.product_preserved_lifecycle import FORGE_COMPONENT, EP_COMPONENT
from tests.installer.test_product_preserved_lifecycle import (
    _REQUEST, _artifact, _receipt_digest, _terminal,
)
from tests.installer.test_released_product_routes import verified_forge_ep_selection
from tests.installer.test_universal_installer import current_context


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
    def test_preserved_forge_installation_identity_accepts_product_opaque_case(self) -> None:
        artifact = _artifact(FORGE_COMPONENT)
        preserved = ManagedPreservedComponentBinding(
            FORGE_COMPONENT, "forge-a", "receipt:forge-a", "preserve-a",
            "sha256:" + "e" * 64, artifact.version,
            artifact.source_revision, artifact.digest, "forge-a", "Install-A",
        )
        self.assertEqual(preserved.forge_installation_id, "Install-A")
        with self.assertRaisesRegex(ValueError, "installation_id"):
            replace(preserved, forge_installation_id="../other")

    def test_preserve_commit_keeps_exact_instance_claim_and_historical_pairing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            base = verified_forge_ep_selection(current_context()).manifest
            artifacts = {component: _artifact(component) for component in (FORGE_COMPONENT, EP_COMPONENT)}
            manifest = replace(
                base,
                manifest_digest="sha256:" + "d" * 64,
                components=tuple(
                    replace(item, artifact=artifacts[item.identity])
                    for item in base.components
                ),
            )
            binding = ManagedCompositionBinding(
                manifest.composition_id, manifest.manifest_digest,
                "receipt:installed-preserved-composition",
            )
            pair = ManagedDeployment(
                "preserved-pair", 1, "Preserved pair", (
                    ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:forge-a"),
                    ManagedComponentBinding(EP_COMPONENT, "ep-a", "receipt:ep-a"),
                ),
                ManagedPeerBinding("forge-a", "ep-a", "receipt:paired-a"),
                MANAGED_DEPLOYMENT_SCHEMA_V2, binding,
            )
            sibling = ManagedDeployment(
                "sibling", 1, "Sibling", (
                    ManagedComponentBinding(FORGE_COMPONENT, "forge-b", "receipt:forge-b"),
                ),
                schema=MANAGED_DEPLOYMENT_SCHEMA_V2, composition_binding=binding,
            )
            registry.create(pair)
            registry.create(sibling)

            receipt, status = self._preserve_evidence(FORGE_COMPONENT, "forge-a", "preserve-a")
            preserved = registry.commit_preserved(
                deployment_id=pair.deployment_id, expected_revision=1,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="preserve-a", artifact=artifacts[FORGE_COMPONENT],
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=receipt, status=status,
            )
            self.assertEqual(preserved.schema, MANAGED_DEPLOYMENT_SCHEMA_V3)
            self.assertEqual(preserved.revision, 2)
            self.assertEqual(preserved.active_by_component[EP_COMPONENT].instance_id, "ep-a")
            self.assertEqual(preserved.preserved_by_component[FORGE_COMPONENT].instance_id, "forge-a")
            self.assertIsNone(preserved.peer_binding)
            self.assertEqual(preserved.historical_peer_binding, pair.peer_binding)
            self.assertEqual(registry.load(pair.deployment_id), preserved)
            self.assertEqual(registry.load(sibling.deployment_id), sibling)
            self.assertEqual(registry.commit_preserved(
                deployment_id=pair.deployment_id, expected_revision=1,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="preserve-a", artifact=artifacts[FORGE_COMPONENT],
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=receipt, status=status,
            ), preserved)

            with self.assertRaisesRegex(ManagedDeploymentError, "already belongs"):
                registry.create(ManagedDeployment(
                    "foreign", 1, None,
                    (ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:foreign"),),
                ))
            with self.assertRaisesRegex(ManagedDeploymentError, "lifecycle-aware"):
                _ = preserved.by_component
            with self.assertRaisesRegex(ManagedDeploymentError, "lifecycle plan"):
                ManagedDeploymentPlanner.plan(preserved, None)
            with self.assertRaisesRegex(ManagedDeploymentError, "without purge"):
                registry.remove(pair.deployment_id, expected_revision=2)
            with self.assertRaisesRegex(ManagedDeploymentError, "lifecycle commit"):
                registry.replace(replace(preserved, revision=3), expected_revision=2)

            ep_receipt, ep_status = self._preserve_evidence(EP_COMPONENT, "ep-a", "preserve-ep")
            both_preserved = registry.commit_preserved(
                deployment_id=pair.deployment_id, expected_revision=2,
                component=EP_COMPONENT, instance_id="ep-a",
                operation_id="preserve-ep", artifact=artifacts[EP_COMPONENT],
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=ep_receipt, status=ep_status,
            )
            self.assertEqual(both_preserved.components, ())
            self.assertEqual(set(both_preserved.preserved_by_component), {FORGE_COMPONENT, EP_COMPONENT})
            self.assertEqual(registry.inventory(), (both_preserved, sibling))

    def test_preserve_commit_rejects_stale_foreign_and_tampered_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            manifest = verified_forge_ep_selection(current_context()).manifest
            artifact = _artifact(FORGE_COMPONENT)
            manifest = replace(
                manifest, manifest_digest="sha256:" + "d" * 64,
                components=tuple(
                    replace(item, artifact=artifact) if item.identity == FORGE_COMPONENT else item
                    for item in manifest.components
                ),
            )
            current = ManagedDeployment(
                "forge-only", 1, None,
                (ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:forge-a"),),
                schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=ManagedCompositionBinding(
                    manifest.composition_id, manifest.manifest_digest, "receipt:composition-a"
                ),
            )
            registry.create(current)
            receipt, status = self._preserve_evidence(FORGE_COMPONENT, "forge-a", "preserve-a")
            common = dict(
                deployment_id=current.deployment_id, expected_revision=1,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="preserve-a", artifact=artifact,
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=receipt, status=status,
            )
            with self.assertRaisesRegex(ManagedDeploymentError, "revision changed"):
                registry.commit_preserved(**(common | {"expected_revision": 2}))
            with self.assertRaisesRegex(ManagedDeploymentError, "invalid"):
                registry.commit_preserved(**(common | {"instance_id": "forge-b"}))
            with self.assertRaisesRegex(ManagedDeploymentError, "outside installed composition"):
                registry.commit_preserved(**(common | {
                    "installed_manifest": replace(
                        manifest,
                        components=tuple(
                            item for item in manifest.components if item.identity != FORGE_COMPONENT
                        ),
                        product_venvs=tuple(
                            item for item in manifest.product_venvs
                            if item.component_identity != FORGE_COMPONENT
                        ),
                    ),
                }))
            changed = receipt | {"provider_auth_state": "READY"}
            with self.assertRaisesRegex(ManagedDeploymentError, "invalid"):
                registry.commit_preserved(**(common | {"receipt": changed}))
            self.assertEqual(registry.load(current.deployment_id), current)

    def test_purge_commit_releases_only_terminal_product_claim(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            artifact = _artifact(FORGE_COMPONENT)
            base = verified_forge_ep_selection(current_context()).manifest
            manifest = replace(
                base, manifest_digest="sha256:" + "d" * 64,
                components=tuple(
                    replace(item, artifact=artifact)
                    if item.identity == FORGE_COMPONENT else item
                    for item in base.components
                ),
            )
            composition = ManagedCompositionBinding(
                manifest.composition_id, manifest.manifest_digest,
                "receipt:purge-composition",
            )
            selected = ManagedDeployment(
                "selected", 1, "Selected", (
                    ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:forge-a"),
                ), schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=composition,
            )
            sibling = ManagedDeployment(
                "sibling", 1, "Sibling", (
                    ManagedComponentBinding(FORGE_COMPONENT, "forge-b", "receipt:forge-b"),
                ), schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=composition,
            )
            registry.create(selected)
            registry.create(sibling)
            preserve_receipt, preserve_status = self._preserve_evidence(
                FORGE_COMPONENT, "forge-a", "preserve-a"
            )
            preserved = registry.commit_preserved(
                deployment_id="selected", expected_revision=1,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="preserve-a", artifact=artifact,
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=preserve_receipt, status=preserve_status,
            )
            purge_receipt, purge_status = self._purge_evidence(
                FORGE_COMPONENT, "forge-a", "purge-a"
            )
            common = dict(
                deployment_id="selected", expected_revision=preserved.revision,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="purge-a", artifact=artifact,
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=purge_receipt, status=purge_status,
            )
            with self.assertRaisesRegex(ManagedDeploymentError, "revision changed"):
                registry.commit_purged(**(common | {"expected_revision": 1}))
            with self.assertRaisesRegex(ManagedDeploymentError, "invalid"):
                registry.commit_purged(**(common | {"instance_id": "forge-b"}))
            self.assertEqual(registry.load("selected"), preserved)
            self.assertIsNone(registry.commit_purged(**common))
            self.assertIsNone(registry.load("selected"))
            self.assertEqual(registry.load("sibling"), sibling)
            with self.assertRaisesRegex(ManagedDeploymentError, "revision changed"):
                registry.commit_purged(**common)

    def test_purge_commit_keeps_unpaired_sibling_component_and_rejects_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            artifact = _artifact(FORGE_COMPONENT)
            base = verified_forge_ep_selection(current_context()).manifest
            manifest = replace(base, manifest_digest="sha256:" + "d" * 64,
                               components=tuple(
                replace(item, artifact=artifact)
                if item.identity == FORGE_COMPONENT else item
                for item in base.components
            ))
            composition = ManagedCompositionBinding(
                manifest.composition_id, manifest.manifest_digest,
                "receipt:purge-composition",
            )
            components = (
                ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:forge-a"),
                ManagedComponentBinding(EP_COMPONENT, "ep-a", "receipt:ep-a"),
            )
            paired = ManagedDeployment(
                "paired", 1, None, components,
                ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-a"),
                MANAGED_DEPLOYMENT_SCHEMA_V2, composition,
            )
            unpaired = ManagedDeployment(
                "unpaired", 1, None, components, schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=composition,
            )
            purge_receipt, purge_status = self._purge_evidence(
                FORGE_COMPONENT, "forge-a", "purge-a"
            )
            args = dict(
                expected_revision=1, component=FORGE_COMPONENT,
                instance_id="forge-a", operation_id="purge-a",
                artifact=artifact, installed_manifest=manifest,
                request_digest=_REQUEST, receipt=purge_receipt,
                status=purge_status,
            )
            registry.create(paired)
            with self.assertRaisesRegex(ManagedDeploymentError, "lacks EP consumer revocation"):
                registry.commit_purged(deployment_id="paired", **args)
            self.assertEqual(registry.load("paired"), paired)
            registry.remove("paired", expected_revision=1)
            registry.create(unpaired)
            updated = registry.commit_purged(deployment_id="unpaired", **args)
            self.assertIsNotNone(updated)
            self.assertEqual(updated.revision, 2)
            self.assertEqual(updated.schema, MANAGED_DEPLOYMENT_SCHEMA_V2)
            self.assertEqual(updated.active_by_component[EP_COMPONENT].instance_id, "ep-a")
            self.assertNotIn(FORGE_COMPONENT, updated.active_by_component)

    def test_purge_commit_preserves_other_product_tombstone_and_rejects_bad_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            artifacts = {component: _artifact(component) for component in (FORGE_COMPONENT, EP_COMPONENT)}
            base = verified_forge_ep_selection(current_context()).manifest
            manifest = replace(
                base, manifest_digest="sha256:" + "d" * 64,
                components=tuple(
                    replace(item, artifact=artifacts[item.identity])
                    for item in base.components
                ),
            )
            composition = ManagedCompositionBinding(
                manifest.composition_id, manifest.manifest_digest,
                "receipt:purge-composition",
            )
            original = ManagedDeployment(
                "selected", 1, None, (
                    ManagedComponentBinding(FORGE_COMPONENT, "forge-a", "receipt:forge-a"),
                    ManagedComponentBinding(EP_COMPONENT, "ep-a", "receipt:ep-a"),
                ), schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=composition,
            )
            registry.create(original)
            preserve_receipt, preserve_status = self._preserve_evidence(
                EP_COMPONENT, "ep-a", "preserve-ep"
            )
            preserved = registry.commit_preserved(
                deployment_id="selected", expected_revision=1,
                component=EP_COMPONENT, instance_id="ep-a",
                operation_id="preserve-ep", artifact=artifacts[EP_COMPONENT],
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=preserve_receipt, status=preserve_status,
            )
            purge_receipt, purge_status = self._purge_evidence(
                FORGE_COMPONENT, "forge-a", "purge-forge"
            )
            common = dict(
                deployment_id="selected", expected_revision=preserved.revision,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="purge-forge", artifact=artifacts[FORGE_COMPONENT],
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=purge_receipt, status=purge_status,
            )
            with self.assertRaisesRegex(ManagedDeploymentError, "invalid"):
                registry.commit_purged(**(common | {"status": purge_status | {"lifecycle_state": "PRESERVED"}}))
            self.assertEqual(registry.load("selected"), preserved)
            updated = registry.commit_purged(**common)
            self.assertIsNotNone(updated)
            self.assertEqual(updated.schema, MANAGED_DEPLOYMENT_SCHEMA_V3)
            self.assertEqual(updated.revision, preserved.revision + 1)
            self.assertEqual(updated.preserved_by_component[EP_COMPONENT],
                             preserved.preserved_by_component[EP_COMPONENT])
            self.assertNotIn(FORGE_COMPONENT, updated.active_by_component)

    @staticmethod
    def _preserve_evidence(component: str, instance_id: str, operation_id: str):
        receipt, status = _terminal(component, "PRESERVE")
        receipt["instance_id"] = instance_id
        receipt["operation_id"] = operation_id
        key = "receipt_digest" if component == FORGE_COMPONENT else "receipt_sha256"
        receipt[key] = _receipt_digest(component, {k: v for k, v in receipt.items() if k != key})
        status.update({
            "instance_id": instance_id, "operation_id": operation_id,
            key: receipt[key],
        })
        if component == FORGE_COMPONENT:
            receipt["runtime_id"] = instance_id
            receipt[key] = _receipt_digest(component, {k: v for k, v in receipt.items() if k != key})
            status[key] = receipt[key]
        return receipt, status

    @staticmethod
    def _purge_evidence(component: str, instance_id: str, operation_id: str):
        receipt, status = _terminal(component, "PURGE")
        receipt["instance_id"] = instance_id
        receipt["operation_id"] = operation_id
        key = "receipt_digest" if component == FORGE_COMPONENT else "receipt_sha256"
        if component == FORGE_COMPONENT:
            receipt["runtime_id"] = instance_id
        receipt[key] = _receipt_digest(
            component, {k: v for k, v in receipt.items() if k != key}
        )
        status.update({"instance_id": instance_id, "operation_id": operation_id,
                       key: receipt[key]})
        return receipt, status

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


    def test_v1_records_remain_exactly_readable_and_v2_requires_terminal_composition_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root)
            legacy = registry.create(deployment())
            raw = (root / "production.json").read_text(encoding="utf-8")
            self.assertNotIn("composition_binding", raw)
            self.assertEqual(set(json.loads(raw)), {
                "schema", "deployment_id", "revision", "label", "components", "peer_binding",
            })
            self.assertEqual(registry.load("production"), legacy)

            composition = ManagedCompositionBinding(
                "forge-ep-qualified-v3",
                "sha256:" + "a" * 64,
                "receipt:composition-" + "b" * 64,
            )
            qualified = ManagedDeployment(
                legacy.deployment_id,
                2,
                legacy.label,
                legacy.components,
                legacy.peer_binding,
                MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition,
            )
            registry.replace(qualified, expected_revision=1)
            stored = registry.load("production")
            self.assertEqual(stored, qualified)
            self.assertEqual(stored.composition_binding.composition_id, "forge-ep-qualified-v3")
            v2_raw = (root / "production.json").read_text()
            self.assertIn('"schema":"forge-platform.managed-deployment/v2"', v2_raw)
            self.assertEqual(set(json.loads(v2_raw)), {
                "schema", "deployment_id", "revision", "label", "components",
                "peer_binding", "composition_binding",
            })

            with self.assertRaisesRegex(ValueError, "requires terminal composition"):
                ManagedDeployment(
                    "broken-v2",
                    1,
                    None,
                    legacy.components,
                    legacy.peer_binding,
                    MANAGED_DEPLOYMENT_SCHEMA_V2,
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
