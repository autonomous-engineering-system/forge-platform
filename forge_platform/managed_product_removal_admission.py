"""Admit a reviewed native removal against fresh helper-owned registry authority.

The request contains only public identities and plan fingerprints. Product
artifacts, topology and removal order come from the signed installed manifest
and the helper's current registry; executable and filesystem authority never
come from the caller.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from hashlib import sha256
import json
import re

from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .qualified_ep_lifecycle import qualified_ep_lifecycle_artifact
from .qualified_forge_lifecycle import qualified_forge_lifecycle_artifact
from .universal_installer import CompositionManifest


NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA = "forge-platform.native-product-removal-request/v1"
MAXIMUM_NATIVE_PRODUCT_REMOVAL_REQUEST_BYTES = 16 * 1024
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_HASH = re.compile(r"^[0-9a-f]{64}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_FIELDS = frozenset({
    "schema", "operation_id", "deployment_id", "action", "target_component",
    "reviewed_revision", "reviewed_deployment_sha256", "reviewed_plan_sha256",
    "forge_instance_id", "engineering_platform_instance_id",
    "installed_composition_identity", "installed_manifest_sha256",
    "installer_release", "request_fingerprint",
})
_RELEASE_FIELDS = frozenset({
    "version", "release_page", "asset_name", "sha256", "signing_key_id",
})


class ManagedProductRemovalAdmissionError(RuntimeError):
    """Removal intent is malformed, stale, ambiguous or unsupported."""


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")


def _fingerprint(value: object) -> str:
    return sha256(_canonical(value)).hexdigest()


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate removal request key")
        result[key] = value
    return result


@dataclass(frozen=True)
class NativeProductRemovalRequest:
    operation_id: str
    deployment_id: str
    action: str
    target_component: str | None
    reviewed_revision: int
    reviewed_deployment_sha256: str
    reviewed_plan_sha256: str
    forge_instance_id: str
    engineering_platform_instance_id: str | None
    installed_composition_identity: str
    installed_manifest_sha256: str
    installer_release: NativeInstallerReleaseBinding
    request_fingerprint: str


@dataclass(frozen=True)
class AdmittedNativeProductRemoval:
    request: NativeProductRemovalRequest
    reviewed_current: ManagedDeployment
    plan: ManagedDeploymentPlan
    installed_manifest: CompositionManifest


def decode_native_product_removal_request(raw: bytes) -> NativeProductRemovalRequest:
    """Decode only bounded canonical JSON with exact public fields."""

    if not isinstance(raw, bytes) or not raw or len(raw) > MAXIMUM_NATIVE_PRODUCT_REMOVAL_REQUEST_BYTES:
        raise ManagedProductRemovalAdmissionError("removal request size is invalid")
    try:
        payload = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_unique_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
        )
        if not isinstance(payload, dict) or frozenset(payload) != _FIELDS:
            raise ValueError("removal request fields are invalid")
        if _canonical(payload) != raw or payload["schema"] != NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA:
            raise ValueError("removal request is noncanonical or unsupported")
        supplied = payload["request_fingerprint"]
        unsigned = dict(payload)
        del unsigned["request_fingerprint"]
        if not isinstance(supplied, str) or supplied != _fingerprint(unsigned):
            raise ValueError("removal request fingerprint changed")
        release = payload["installer_release"]
        if not isinstance(release, dict) or frozenset(release) != _RELEASE_FIELDS:
            raise ValueError("installer release binding is invalid")
        binding = NativeInstallerReleaseBinding(**release)
        for field in ("operation_id", "deployment_id", "forge_instance_id"):
            if not isinstance(payload[field], str) or _ID.fullmatch(payload[field]) is None:
                raise ValueError("removal identity is invalid")
        ep_id = payload["engineering_platform_instance_id"]
        if ep_id is not None and (not isinstance(ep_id, str) or _ID.fullmatch(ep_id) is None):
            raise ValueError("EP removal identity is invalid")
        if (
            isinstance(payload["reviewed_revision"], bool)
            or not isinstance(payload["reviewed_revision"], int)
            or payload["reviewed_revision"] <= 0
            or any(
                not isinstance(payload[field], str) or _HASH.fullmatch(payload[field]) is None
                for field in ("reviewed_deployment_sha256", "reviewed_plan_sha256")
            )
            or not isinstance(payload["installed_composition_identity"], str)
            or _ID.fullmatch(payload["installed_composition_identity"]) is None
            or not isinstance(payload["installed_manifest_sha256"], str)
            or _DIGEST.fullmatch(payload["installed_manifest_sha256"]) is None
        ):
            raise ValueError("reviewed removal authority is invalid")
        action = payload["action"]
        target = payload["target_component"]
        if (
            action not in {"REMOVE_COMPONENT", "REMOVE_DEPLOYMENT"}
            or action == "REMOVE_COMPONENT" and (target != FORGE_COMPONENT or ep_id is None)
            or action == "REMOVE_DEPLOYMENT" and target is not None
        ):
            raise ValueError("removal action is unsupported")
        return NativeProductRemovalRequest(
            payload["operation_id"], payload["deployment_id"], action, target,
            payload["reviewed_revision"], payload["reviewed_deployment_sha256"],
            payload["reviewed_plan_sha256"], payload["forge_instance_id"], ep_id,
            payload["installed_composition_identity"], payload["installed_manifest_sha256"],
            binding, supplied,
        )
    except (UnicodeError, json.JSONDecodeError, TypeError, ValueError) as error:
        raise ManagedProductRemovalAdmissionError("removal request is invalid") from error


def admit_native_product_removal(
    request: NativeProductRemovalRequest, *,
    installed_manifest: CompositionManifest,
    registry: ManagedDeploymentRegistry,
    current_installer_release: NativeInstallerReleaseBinding,
) -> AdmittedNativeProductRemoval:
    """Recompute exact reviewed removal from current registered product state."""

    if not isinstance(request, NativeProductRemovalRequest):
        raise TypeError("decoded removal request is required")
    if not isinstance(installed_manifest, CompositionManifest):
        raise TypeError("signed installed composition authority is required")
    if not isinstance(registry, ManagedDeploymentRegistry):
        raise TypeError("managed deployment registry is required")
    if request.installer_release != current_installer_release:
        raise ManagedProductRemovalAdmissionError("installer release changed after review")
    if (
        request.installed_composition_identity != installed_manifest.composition_id
        or request.installed_manifest_sha256 != installed_manifest.manifest_digest
    ):
        raise ManagedProductRemovalAdmissionError("installed composition changed after review")
    current = registry.load(request.deployment_id)
    inventory = registry.inventory()
    if current is None or current not in inventory:
        raise ManagedProductRemovalAdmissionError("reviewed deployment is unavailable")
    binding = current.composition_binding
    by_component = current.by_component
    if (
        current.revision != request.reviewed_revision
        or _fingerprint(asdict(current)) != request.reviewed_deployment_sha256
        or binding is None
        or binding.composition_id != installed_manifest.composition_id
        or binding.manifest_digest != installed_manifest.manifest_digest
        or set(by_component) not in ({FORGE_COMPONENT}, {FORGE_COMPONENT, EP_COMPONENT})
        or by_component[FORGE_COMPONENT].instance_id != request.forge_instance_id
        or (by_component.get(EP_COMPONENT).instance_id if EP_COMPONENT in by_component else None)
        != request.engineering_platform_instance_id
        or (current.peer_binding is None) != (EP_COMPONENT not in by_component)
    ):
        raise ManagedProductRemovalAdmissionError("reviewed removal target changed")
    claims = {(component, item.instance_id) for component, item in by_component.items()}
    if any(
        deployment.deployment_id != current.deployment_id
        and claims.intersection(
            (component, item.instance_id)
            for component, item in deployment.by_component.items()
        )
        for deployment in inventory
    ):
        raise ManagedProductRemovalAdmissionError("product instance is shared with another deployment")
    artifacts = {component.identity: component.artifact for component in installed_manifest.components}
    forge = artifacts.get(FORGE_COMPONENT)
    ep = artifacts.get(EP_COMPONENT)
    if (
        not qualified_forge_lifecycle_artifact(forge)
        or EP_COMPONENT in by_component and (
            not qualified_ep_lifecycle_artifact(ep)
        )
    ):
        raise ManagedProductRemovalAdmissionError("product-owned removal contract is unavailable")
    if request.action == "REMOVE_COMPONENT":
        if EP_COMPONENT not in by_component:
            raise ManagedProductRemovalAdmissionError("Forge component removal requires paired EP")
        desired = replace(
            current, components=(by_component[EP_COMPONENT],), peer_binding=None,
        )
    else:
        desired = None
    plan = ManagedDeploymentPlanner.plan(current, desired)
    if _fingerprint(asdict(plan)) != request.reviewed_plan_sha256:
        raise ManagedProductRemovalAdmissionError("reviewed removal plan changed")
    return AdmittedNativeProductRemoval(request, current, plan, installed_manifest)
