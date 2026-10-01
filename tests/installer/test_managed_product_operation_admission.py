#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
import json
from pathlib import Path
import tempfile
import unittest

from forge_platform.managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2,
    ManagedComponentBinding,
    ManagedCompositionBinding,
    ManagedDeployment,
    ManagedDeploymentRegistry,
)
from forge_platform.managed_product_operation_admission import (
    MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES,
    ManagedProductOperationAdmissionError,
    NativeInstallerReleaseBinding,
    admit_native_product_operation,
    decode_native_product_operation_request,
)
from forge_platform.universal_installer import (
    CompositionCatalogEntry,
    CompositionManifest,
    DownloadIdentity,
    InstallerRequirement,
    ProviderRequirement,
    ProviderRuntimeRequirement,
    SemanticVersion,
)
from tests.installer.test_universal_installer import manifest_payload


FORGE_DIGEST = "sha256:" + "8" * 64
EP_DIGEST = "sha256:" + "7" * 64
OLD_FORGE_DIGEST = "sha256:" + "6" * 64
OLD_EP_DIGEST = "sha256:" + "5" * 64


def composition_manifest(
    *,
    composition_id: str,
    forge_version: str,
    forge_digest: str,
    ep_version: str,
    ep_digest: str,
    upgrade_from: tuple[str, ...] = (),
    components: tuple[str, ...] = ("engineering-platform-server", "forge-runtime"),
) -> CompositionManifest:
    payload = manifest_payload(
        composition_id=composition_id,
        upgrade_from=upgrade_from,
    )
    ep = payload["components"][0]
    ep["artifact"]["version"] = ep_version
    ep["artifact"]["digest"] = ep_digest
    forge = json.loads(json.dumps(ep))
    forge["identity"] = "forge-runtime"
    forge["artifact"] = {
        "version": forge_version,
        "source_revision": "f" * 40,
        "source": "https://registry.example.invalid/forge-runtime.whl",
        "digest": forge_digest,
        "qualification": "https://evidence.example.invalid/forge-runtime",
    }
    forge["service"]["product_service_reference"] = "forge-server-service-v1"
    payload["components"].append(forge)
    payload["product_venvs"].append({
        "component_identity": "forge-runtime",
        "venv_identity": "forge-runtime-primary",
        "python_runtime_identity": payload["python_runtime"]["identity_digest"],
    })
    payload["components"] = [
        component for component in payload["components"]
        if component["identity"] in components
    ]
    payload["product_venvs"] = [
        venv for venv in payload["product_venvs"]
        if venv["component_identity"] in components
    ]
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    digest = "sha256:" + sha256(raw).hexdigest()
    requirement = InstallerRequirement(
        SemanticVersion.parse(payload["requires_installer"]["minimum_version"]),
        frozenset(payload["requires_installer"]["capabilities"]),
    )
    entry = CompositionCatalogEntry(
        composition_id,
        "stable",
        DownloadIdentity("https://example.invalid/composition.json", digest),
        requirement,
    )
    return CompositionManifest.from_catalog_bytes(entry, raw)


def canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode()


def installer_release() -> NativeInstallerReleaseBinding:
    return NativeInstallerReleaseBinding(
        "1.2.3",
        "https://github.com/autonomous-engineering-system/forge-platform/releases/tag/v1.2.3",
        "ForgePlatformInstaller-1.2.3-arm64.zip",
        "sha256:" + "4" * 64,
        "release-key-1",
    )


def request_payload(
    candidate: CompositionManifest,
    *,
    installed: CompositionManifest | None,
    exists: bool = True,
) -> dict[str, object]:
    candidate_by = {component.identity: component for component in candidate.components}
    installed_by = (
        {} if installed is None else {
            component.identity: component for component in installed.components
        }
    )
    components = []
    for identity in sorted(candidate_by):
        artifact = candidate_by[identity].artifact
        previous = installed_by.get(identity)
        components.append({
            "identity": identity,
            "change": "update" if exists else "install",
            "installed_version": None if previous is None else previous.artifact.version,
            "candidate_version": artifact.version,
            "artifact_sha256": artifact.digest,
            "update_assessment_reference": (
                ("forge-update-assess:" if identity == "forge-runtime" else "ep-update-assess:")
                + "sha256:" + ("a" if identity == "forge-runtime" else "b") * 64
            ) if exists else None,
        })
    release = installer_release()
    payload: dict[str, object] = {
        "schema": "forge-platform.native-product-operation-request/v3",
        "stable_plan_fingerprint": "1" * 64,
        "operation_id": "operation-one",
        "session_id": "session-one",
        "deployment_id": "production",
        "deployment_exists": exists,
        "forge_instance_id": "forge-prod" if exists and "forge-runtime" in installed_by else None,
        "engineering_platform_instance_id": "ep-prod" if exists and "engineering-platform-server" in installed_by else None,
        "installed_composition_identity": None if installed is None else installed.composition_id,
        "installed_composition_manifest_sha256": None if installed is None else installed.manifest_digest,
        "inventory_evidence_reference": "evidence:inventory-one",
        "composition_identity": candidate.composition_id,
        "manifest_sha256": candidate.manifest_digest,
        "installer_release": {
            "version": release.version,
            "release_page": release.release_page,
            "asset_name": release.asset_name,
            "sha256": release.sha256,
            "signing_key_id": release.signing_key_id,
        },
        "components": components,
        "provider_target_ids": ["codex", "github-cli"],
        "runtime_evidence_references": [
            "receipt:runtime-complete", "receipt:tools-complete",
        ],
    }
    payload["request_fingerprint"] = sha256(canonical(payload)).hexdigest()
    return payload


def decoded(payload: dict[str, object]):
    return decode_native_product_operation_request(canonical(payload))


def stored_deployment(installed: CompositionManifest) -> ManagedDeployment:
    components = {component.identity for component in installed.components}
    return ManagedDeployment(
        "production",
        1,
        "Production",
        tuple(binding for identity, binding in (
            ("forge-runtime", ManagedComponentBinding(
                "forge-runtime", "forge-prod", "receipt:forge-prod"
            )),
            ("engineering-platform-server", ManagedComponentBinding(
                "engineering-platform-server", "ep-prod", "receipt:ep-prod"
            )),
        ) if identity in components),
        schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
        composition_binding=ManagedCompositionBinding(
            installed.composition_id,
            installed.manifest_digest,
            "receipt:installed-composition",
        ),
    )


class ManagedProductOperationRequestDecodingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installed = composition_manifest(
            composition_id="forge-ep-old",
            forge_version="1.0.0",
            forge_digest=OLD_FORGE_DIGEST,
            ep_version="2.0.0",
            ep_digest=OLD_EP_DIGEST,
        )
        cls.candidate = composition_manifest(
            composition_id="forge-ep-current",
            forge_version="1.1.0",
            forge_digest=FORGE_DIGEST,
            ep_version="2.1.0",
            ep_digest=EP_DIGEST,
            upgrade_from=("forge-ep-old",),
        )

    def test_decodes_exact_canonical_request_and_preserves_ordered_public_sets(self) -> None:
        payload = request_payload(self.candidate, installed=self.installed)

        request = decoded(payload)

        self.assertEqual(request.composition_identity, "forge-ep-current")
        self.assertEqual(request.provider_target_ids, ("codex", "github-cli"))
        self.assertEqual(
            tuple(component.identity for component in request.components),
            ("engineering-platform-server", "forge-runtime"),
        )
        self.assertEqual(
            request.components[1].update_assessment_reference,
            "forge-update-assess:sha256:" + "a" * 64,
        )

    def test_update_requires_exact_reviewed_product_assessment(self) -> None:
        for changed in (None, "forge-update-assess:unavailable", "ep-update-assess:sha256:" + "a" * 64):
            payload = request_payload(self.candidate, installed=self.installed)
            payload["components"][1]["update_assessment_reference"] = changed
            with self.subTest(changed=changed), self.assertRaises(ManagedProductOperationAdmissionError):
                decoded(_refingerprint(payload))
        legacy = request_payload(self.candidate, installed=self.installed)
        legacy["schema"] = "forge-platform.native-product-operation-request/v2"
        for component in legacy["components"]:
            component.pop("update_assessment_reference")
        with self.assertRaises(ManagedProductOperationAdmissionError):
            decoded(_refingerprint(legacy))

    def test_rejects_duplicate_noncanonical_oversized_and_changed_requests(self) -> None:
        payload = request_payload(self.candidate, installed=self.installed)
        raw = canonical(payload)
        duplicate = raw.replace(
            b'{"components":', b'{"schema":"duplicate","components":', 1
        )
        with self.assertRaises(ManagedProductOperationAdmissionError):
            decode_native_product_operation_request(duplicate)
        with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "canonical"):
            decode_native_product_operation_request(json.dumps(payload).encode())
        with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "size"):
            decode_native_product_operation_request(
                b" " * (MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES + 1)
            )
        payload["operation_id"] = "changed"
        with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "fingerprint"):
            decoded(payload)

    def test_rejects_invalid_shape_topology_components_provider_and_evidence(self) -> None:
        cases = []
        payload = request_payload(self.candidate, installed=self.installed)
        payload["unexpected"] = True
        cases.append(payload)
        payload = request_payload(self.candidate, installed=self.installed)
        payload["components"] = payload["components"][:1]
        cases.append(payload)
        payload = request_payload(self.candidate, installed=self.installed)
        payload["provider_target_ids"] = ["codex", "codex"]
        cases.append(payload)
        payload = request_payload(self.candidate, installed=self.installed)
        payload["provider_target_ids"] = ["github-cli", "codex"]
        cases.append(payload)
        payload = request_payload(self.candidate, installed=self.installed)
        payload["runtime_evidence_references"] = ["token=secret"]
        cases.append(payload)
        payload = request_payload(self.candidate, installed=self.installed)
        payload["forge_instance_id"] = None
        cases.append(payload)
        payload = request_payload(self.candidate, installed=None, exists=False)
        payload["forge_instance_id"] = "invented"
        cases.append(payload)
        for payload in cases:
            payload.pop("request_fingerprint", None)
            payload["request_fingerprint"] = sha256(canonical(payload)).hexdigest()
            with self.assertRaises(ManagedProductOperationAdmissionError):
                decoded(payload)

    def test_rejects_bad_release_and_component_values(self) -> None:
        mutations = [
            ("installer_release", "release_page", "http://example.invalid/release"),
            ("installer_release", "asset_name", "../installer.zip"),
            ("installer_release", "sha256", "bad"),
            ("installer_release", "signing_key_id", "UPPER"),
            ("components", 0, {"change": "remove"}),
            ("components", 0, {"artifact_sha256": "bad"}),
        ]
        for root, child, value in mutations:
            payload = request_payload(self.candidate, installed=self.installed)
            if root == "installer_release":
                payload[root][child] = value
            else:
                payload[root][child].update(value)
            payload.pop("request_fingerprint")
            payload["request_fingerprint"] = sha256(canonical(payload)).hexdigest()
            with self.assertRaises(ManagedProductOperationAdmissionError):
                decoded(payload)


class ManagedProductOperationAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.installed = composition_manifest(
            composition_id="forge-ep-old",
            forge_version="1.0.0",
            forge_digest=OLD_FORGE_DIGEST,
            ep_version="2.0.0",
            ep_digest=OLD_EP_DIGEST,
        )
        cls.candidate = composition_manifest(
            composition_id="forge-ep-current",
            forge_version="1.1.0",
            forge_digest=FORGE_DIGEST,
            ep_version="2.1.0",
            ep_digest=EP_DIGEST,
            upgrade_from=("forge-ep-old",),
        )

    def _registry(self, root: Path, *, create: bool = True) -> ManagedDeploymentRegistry:
        registry = ManagedDeploymentRegistry(root)
        if create:
            registry.create(stored_deployment(self.installed))
        return registry

    def test_admits_exact_release_manifest_registry_upgrade_and_provider_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = self._registry(Path(directory).resolve())
            request = decoded(request_payload(self.candidate, installed=self.installed))

            admitted = admit_native_product_operation(
                request,
                manifest=self.candidate,
                installed_manifest=self.installed,
                registry=registry,
                current_installer_release=installer_release(),
            )

            self.assertEqual(admitted.request.request_fingerprint, request.request_fingerprint)
            self.assertEqual(admitted.manifest.manifest_digest, self.candidate.manifest_digest)
            self.assertEqual(admitted.current_deployment.revision, 1)

    def test_admits_fresh_exact_install_without_invented_installed_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = self._registry(Path(directory).resolve(), create=False)
            request = decoded(request_payload(self.candidate, installed=None, exists=False))
            admitted = admit_native_product_operation(
                request,
                manifest=self.candidate,
                registry=registry,
                current_installer_release=installer_release(),
            )
            self.assertIsNone(admitted.current_deployment)

    def test_signed_provider_template_binds_each_reviewed_deployment(self) -> None:
        runtime = ProviderRuntimeRequirement(
            SemanticVersion.parse("1.0.0"), "tar.gz",
            DownloadIdentity("https://example.invalid/provider.tar.gz", "sha256:" + "a" * 64),
            "bin/provider", "sha256:" + "b" * 64,
        )
        template = replace(self.candidate, providers=(
            ProviderRequirement("codex", True, None, "component", "forge-runtime",
                                "selected-deployment", runtime),
            ProviderRequirement("github-cli", True, None, "component",
                                "engineering-platform-server", "selected-deployment", runtime),
        ))
        with tempfile.TemporaryDirectory() as directory:
            registry = self._registry(Path(directory).resolve(), create=False)
            for deployment in ("deployment-a", "deployment-b"):
                payload = request_payload(template, installed=None, exists=False)
                payload["deployment_id"] = deployment
                payload["provider_target_ids"] = [
                    f"codex:forge-runtime:{deployment}",
                    f"github-cli:engineering-platform-server:{deployment}",
                ]
                payload["request_fingerprint"] = sha256(canonical({
                    key: value for key, value in payload.items() if key != "request_fingerprint"
                })).hexdigest()
                admitted = admit_native_product_operation(
                    decoded(payload), manifest=template, registry=registry,
                    current_installer_release=installer_release(),
                )
                self.assertEqual(admitted.request.deployment_id, deployment)
                payload["provider_target_ids"][0] = "codex:forge-runtime:other"
                payload["request_fingerprint"] = sha256(canonical({
                    key: value for key, value in payload.items() if key != "request_fingerprint"
                })).hexdigest()
                with self.assertRaises(ManagedProductOperationAdmissionError):
                    admit_native_product_operation(
                        decoded(payload), manifest=template, registry=registry,
                        current_installer_release=installer_release(),
                    )

    def test_admits_exact_single_component_install_and_existing_update(self) -> None:
        for identity in ("forge-runtime", "engineering-platform-server"):
            with self.subTest(identity=identity):
                installed = composition_manifest(
                    composition_id=f"{identity}-old",
                    forge_version="1.0.0", forge_digest=OLD_FORGE_DIGEST,
                    ep_version="2.0.0", ep_digest=OLD_EP_DIGEST,
                    components=(identity,),
                )
                candidate = composition_manifest(
                    composition_id=f"{identity}-current",
                    forge_version="1.1.0", forge_digest=FORGE_DIGEST,
                    ep_version="2.1.0", ep_digest=EP_DIGEST,
                    upgrade_from=(installed.composition_id,),
                    components=(identity,),
                )
                with tempfile.TemporaryDirectory() as directory:
                    registry = ManagedDeploymentRegistry(Path(directory).resolve())
                    fresh = decoded(request_payload(candidate, installed=None, exists=False))
                    admitted = admit_native_product_operation(
                        fresh, manifest=candidate, registry=registry,
                        current_installer_release=installer_release(),
                    )
                    self.assertIsNone(admitted.current_deployment)
                    registry.create(stored_deployment(installed))
                    update = decoded(request_payload(candidate, installed=installed))
                    admitted = admit_native_product_operation(
                        update, manifest=candidate, installed_manifest=installed,
                        registry=registry, current_installer_release=installer_release(),
                    )
                    self.assertEqual(set(admitted.current_deployment.by_component), {identity})

    def test_single_component_rejects_extra_and_missing_instance_authority(self) -> None:
        forge = composition_manifest(
            composition_id="forge-alone", forge_version="1.1.0",
            forge_digest=FORGE_DIGEST, ep_version="2.1.0", ep_digest=EP_DIGEST,
            components=("forge-runtime",),
        )
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(stored_deployment(forge))
            valid = request_payload(forge, installed=forge)
            valid["components"][0]["change"] = "retain"
            valid["components"][0]["update_assessment_reference"] = None
            for field, value in (
                ("engineering_platform_instance_id", "ep-other"),
                ("forge_instance_id", None),
            ):
                payload = json.loads(json.dumps(valid))
                payload[field] = value
                with self.subTest(field=field), self.assertRaises(ManagedProductOperationAdmissionError):
                    decoded(_refingerprint(payload))
            pair = composition_manifest(
                composition_id="pair", forge_version="1.1.0",
                forge_digest=FORGE_DIGEST, ep_version="2.1.0", ep_digest=EP_DIGEST,
            )
            valid["composition_identity"] = pair.composition_id
            valid["manifest_sha256"] = pair.manifest_digest
            with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "topology"):
                admit_native_product_operation(
                    decoded(_refingerprint(valid)), manifest=pair, registry=registry,
                    installed_manifest=forge, current_installer_release=installer_release(),
                )

    def test_rejects_release_manifest_candidate_and_provider_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            registry = self._registry(Path(directory).resolve())
            base = request_payload(self.candidate, installed=self.installed)
            requests = []
            changed = json.loads(json.dumps(base))
            changed["manifest_sha256"] = "sha256:" + "0" * 64
            requests.append((decoded(_refingerprint(changed)), installer_release()))
            changed = json.loads(json.dumps(base))
            changed["components"][0]["candidate_version"] = "9.9.9"
            requests.append((decoded(_refingerprint(changed)), installer_release()))
            changed = json.loads(json.dumps(base))
            changed["provider_target_ids"] = ["codex"]
            requests.append((decoded(_refingerprint(changed)), installer_release()))
            requests.append((decoded(base), replace(installer_release(), version="9.9.9")))
            for request, release in requests:
                with self.assertRaises(ManagedProductOperationAdmissionError):
                    admit_native_product_operation(
                        request,
                        manifest=self.candidate,
                        installed_manifest=self.installed,
                        registry=registry,
                        current_installer_release=release,
                    )

    def test_rejects_registry_and_installed_manifest_drift(self) -> None:
        base = request_payload(self.candidate, installed=self.installed)
        with tempfile.TemporaryDirectory() as directory:
            empty = self._registry(Path(directory).resolve(), create=False)
            with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "existence"):
                admit_native_product_operation(
                    decoded(base),
                    manifest=self.candidate,
                    installed_manifest=self.installed,
                    registry=empty,
                    current_installer_release=installer_release(),
                )
        with tempfile.TemporaryDirectory() as directory:
            registry = self._registry(Path(directory).resolve())
            with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "unavailable"):
                admit_native_product_operation(
                    decoded(base),
                    manifest=self.candidate,
                    registry=registry,
                    current_installer_release=installer_release(),
                )
            wrong = composition_manifest(
                composition_id="forge-ep-other",
                forge_version="1.0.0",
                forge_digest=OLD_FORGE_DIGEST,
                ep_version="2.0.0",
                ep_digest=OLD_EP_DIGEST,
            )
            with self.assertRaises(ManagedProductOperationAdmissionError):
                admit_native_product_operation(
                    decoded(base),
                    manifest=self.candidate,
                    installed_manifest=wrong,
                    registry=registry,
                    current_installer_release=installer_release(),
                )

    def test_rejects_unauthorized_upgrade_and_nonupdate_version_change(self) -> None:
        unauthorized = composition_manifest(
            composition_id="forge-ep-unrouted",
            forge_version="1.1.0",
            forge_digest=FORGE_DIGEST,
            ep_version="2.1.0",
            ep_digest=EP_DIGEST,
        )
        with tempfile.TemporaryDirectory() as directory:
            registry = self._registry(Path(directory).resolve())
            request = decoded(request_payload(unauthorized, installed=self.installed))
            with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "upgrade route"):
                admit_native_product_operation(
                    request,
                    manifest=unauthorized,
                    installed_manifest=self.installed,
                    registry=registry,
                    current_installer_release=installer_release(),
                )
            payload = request_payload(self.candidate, installed=self.installed)
            payload["components"][0]["change"] = "retain"
            payload["components"][0]["update_assessment_reference"] = None
            with self.assertRaisesRegex(ManagedProductOperationAdmissionError, "non-update"):
                admit_native_product_operation(
                    decoded(_refingerprint(payload)),
                    manifest=self.candidate,
                    installed_manifest=self.installed,
                    registry=registry,
                    current_installer_release=installer_release(),
                )


def _refingerprint(payload: dict[str, object]) -> dict[str, object]:
    payload.pop("request_fingerprint", None)
    payload["request_fingerprint"] = sha256(canonical(payload)).hexdigest()
    return payload


if __name__ == "__main__":
    unittest.main()
