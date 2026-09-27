#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from forge_platform.managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2, ManagedComponentBinding,
    ManagedCompositionBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from forge_platform.managed_product_removal_admission import (
    MAXIMUM_NATIVE_PRODUCT_REMOVAL_REQUEST_BYTES,
    ManagedProductRemovalAdmissionError, NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA,
    admit_native_product_removal, decode_native_product_removal_request,
)
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from tests.installer.test_managed_product_operation_admission import (
    canonical, installer_release,
)
from tests.installer.test_released_product_routes import verified_forge_ep_selection
from tests.installer.test_universal_installer import current_context


def digest(value):
    return sha256(canonical(value)).hexdigest()


class ManagedProductRemovalAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.registry = ManagedDeploymentRegistry(self.root / "registry")
        self.manifest = verified_forge_ep_selection(current_context()).manifest
        self.release = installer_release()
        self.composition = ManagedCompositionBinding(
            self.manifest.composition_id,
            self.manifest.manifest_digest,
            "receipt:installed-composition",
        )
        self.paired = ManagedDeployment(
            "deployment-a", 1, "Paired A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge-a"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep-a"),
            ),
            peer_binding=ManagedPeerBinding("forge-a", "ep-a", "receipt:pair-a"),
            schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
            composition_binding=self.composition,
        )
        self.registry.create(self.paired)
        self.other = ManagedDeployment(
            "deployment-b", 1, "Forge B", (
                ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge-b"),
            ),
            schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
            composition_binding=self.composition,
        )
        self.registry.create(self.other)

    def tearDown(self):
        self.temporary.cleanup()

    def payload(self, *, current=None, action="REMOVE_COMPONENT", **changes):
        current = current or self.paired
        by = current.by_component
        desired = None if action == "REMOVE_DEPLOYMENT" else replace(
            current, components=(by["engineering-platform-server"],), peer_binding=None,
        )
        plan = ManagedDeploymentPlanner.plan(current, desired)
        payload = {
            "schema": NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA,
            "operation_id": "remove-a",
            "deployment_id": current.deployment_id,
            "action": action,
            "target_component": "forge-runtime" if action == "REMOVE_COMPONENT" else None,
            "reviewed_revision": current.revision,
            "reviewed_deployment_sha256": digest(asdict(current)),
            "reviewed_plan_sha256": digest(asdict(plan)),
            "forge_instance_id": by["forge-runtime"].instance_id,
            "engineering_platform_instance_id": (
                by["engineering-platform-server"].instance_id
                if "engineering-platform-server" in by else None
            ),
            "installed_composition_identity": self.manifest.composition_id,
            "installed_manifest_sha256": self.manifest.manifest_digest,
            "installer_release": asdict(self.release),
        }
        payload.update(changes)
        payload["request_fingerprint"] = digest(payload)
        return payload

    def admit(self, payload):
        return admit_native_product_removal(
            decode_native_product_removal_request(canonical(payload)),
            installed_manifest=self.manifest,
            registry=self.registry,
            current_installer_release=self.release,
        )

    def test_exact_paired_component_removal_retains_ep_and_other_deployment(self):
        other_bytes = (self.registry.root / "deployment-b.json").read_bytes()
        admitted = self.admit(self.payload())
        self.assertEqual(admitted.plan.deployment_action, "CREATE_OR_UPDATE")
        self.assertEqual(
            {diff.component: diff.action for diff in admitted.plan.component_diffs},
            {"forge-runtime": "REMOVE_COMPONENT", "engineering-platform-server": "NO_CHANGE"},
        )
        self.assertEqual(set(admitted.plan.desired.by_component), {"engineering-platform-server"})
        self.assertIsNone(admitted.plan.desired.peer_binding)
        self.assertEqual((self.registry.root / "deployment-b.json").read_bytes(), other_bytes)

    def test_exact_paired_and_forge_only_deployment_removal(self):
        paired = self.admit(self.payload(action="REMOVE_DEPLOYMENT"))
        self.assertEqual(paired.plan.deployment_action, "REMOVE_DEPLOYMENT")
        self.assertEqual(len(paired.plan.component_diffs), 2)
        forge_only = self.admit(self.payload(
            current=self.other, action="REMOVE_DEPLOYMENT", operation_id="remove-b",
        ))
        self.assertEqual(len(forge_only.plan.component_diffs), 1)
        self.assertEqual(forge_only.plan.component_diffs[0].instance_id, "forge-b")

    def test_noncanonical_duplicate_oversized_and_unknown_fields_fail(self):
        payload = self.payload()
        raw = canonical(payload)
        for invalid in (
            b" " + raw,
            raw.replace(b'"schema":', b'"schema":"duplicate","schema":', 1),
            raw + b" " * MAXIMUM_NATIVE_PRODUCT_REMOVAL_REQUEST_BYTES,
            b"{\"schema\":NaN}",
            b"\xff",
        ):
            with self.subTest(invalid=invalid[:35]), self.assertRaises(ManagedProductRemovalAdmissionError):
                decode_native_product_removal_request(invalid)
        payload["executable"] = "/tmp/forge"
        payload["request_fingerprint"] = digest({k: v for k, v in payload.items() if k != "request_fingerprint"})
        with self.assertRaises(ManagedProductRemovalAdmissionError):
            self.admit(payload)

    def test_exact_request_shape_and_authority_fail_closed(self):
        for change in (
            {"action": "DELETE_ALL"},
            {"target_component": "engineering-platform-server"},
            {"engineering_platform_instance_id": None},
            {"reviewed_revision": True},
            {"operation_id": "../other"},
            {"reviewed_plan_sha256": "0" * 64},
            {"reviewed_deployment_sha256": "0" * 64},
            {"installed_manifest_sha256": "sha256:" + "0" * 64},
            {"forge_instance_id": "forge-b"},
            {"deployment_id": "deployment-b"},
            {"installer_release": {**asdict(self.release), "version": "9.9.9"}},
        ):
            payload = self.payload(**change)
            with self.subTest(change=change), self.assertRaises(ManagedProductRemovalAdmissionError):
                self.admit(payload)

    def test_stale_registry_and_unsupported_producer_fail_closed(self):
        payload = self.payload()
        self.registry.replace(replace(self.paired, revision=2), expected_revision=1)
        with self.assertRaisesRegex(ManagedProductRemovalAdmissionError, "target changed"):
            self.admit(payload)
        wrong_manifest = replace(self.manifest, components=tuple(
            replace(component, artifact=replace(component.artifact, version="2.7.34"))
            if component.identity == "forge-runtime" else component
            for component in self.manifest.components
        ))
        request = decode_native_product_removal_request(canonical(payload))
        with self.assertRaises(ManagedProductRemovalAdmissionError):
            admit_native_product_removal(
                request, installed_manifest=wrong_manifest, registry=self.registry,
                current_installer_release=self.release,
            )

    def test_shared_instance_across_deployments_fails_closed(self):
        payload = self.payload()
        collision = replace(
            self.other, components=(
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:foreign"),
            ),
        )
        with patch.object(self.registry, "inventory", return_value=(self.paired, collision)):
            with self.assertRaisesRegex(ManagedProductRemovalAdmissionError, "shared"):
                self.admit(payload)

    def test_installed_removal_manifest_is_selected_only_from_pinned_authority(self):
        resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=self.release,
            manifests=(self.manifest,),
        )
        request = decode_native_product_removal_request(canonical(self.payload()))
        self.assertIs(resolver.resolve_installed_removal(request), self.manifest)
        with self.assertRaisesRegex(ManagedProductOperationServiceError, "unavailable"):
            resolver.resolve_installed_removal(replace(
                request, installed_manifest_sha256="sha256:" + "0" * 64,
            ))
        with self.assertRaisesRegex(ManagedProductOperationServiceError, "release"):
            resolver.resolve_installed_removal(replace(
                request, installer_release=replace(self.release, version="9.9.9"),
            ))
        with self.assertRaises(TypeError):
            resolver.resolve_installed_removal(object())


if __name__ == "__main__":
    unittest.main()
