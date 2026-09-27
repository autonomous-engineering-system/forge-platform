"""Read-only exact removal proposal from helper-owned product registry state.

The caller supplies only the selected public target and a durable operation ID.
The helper computes reviewed revision and hashes from its current registry and
signed installed manifest. Execution independently re-admits those bytes.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from hashlib import sha256
import json
import re

from .managed_deployments import ManagedDeploymentPlanner, ManagedDeploymentRegistry
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .managed_product_removal_admission import (
    NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA,
    admit_native_product_removal,
    decode_native_product_removal_request,
)
from .universal_installer import CompositionManifest


NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_SCHEMA = (
    "forge-platform.native-product-removal-review-intent/v1"
)
NATIVE_PRODUCT_REMOVAL_REVIEW_PROPOSAL_SCHEMA = (
    "forge-platform.native-product-removal-review-proposal/v1"
)
MAXIMUM_NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_BYTES = 8 * 1024
MAXIMUM_NATIVE_PRODUCT_REMOVAL_REVIEW_PROPOSAL_BYTES = 32 * 1024
_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_HASH = re.compile(r"^[0-9a-f]{64}$")
_FIELDS = frozenset({
    "schema", "operation_id", "deployment_id", "action", "target_component",
    "forge_instance_id", "engineering_platform_instance_id",
    "installed_composition_identity", "installed_manifest_sha256",
    "installer_release", "intent_fingerprint",
})
_RELEASE_FIELDS = frozenset({
    "version", "release_page", "asset_name", "sha256", "signing_key_id",
})


class ManagedProductRemovalProposalError(RuntimeError):
    """The selected read-only target is malformed, stale, or unsupported."""


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
            raise ValueError("duplicate removal review field")
        result[key] = value
    return result


@dataclass(frozen=True)
class NativeProductRemovalReviewIntent:
    operation_id: str
    deployment_id: str
    action: str
    target_component: str | None
    forge_instance_id: str
    engineering_platform_instance_id: str | None
    installed_composition_identity: str
    installed_manifest_sha256: str
    installer_release: NativeInstallerReleaseBinding
    intent_fingerprint: str


def decode_native_product_removal_review_intent(
    raw: bytes,
) -> NativeProductRemovalReviewIntent:
    """Reject duplicate, noncanonical, oversized, or ambiguous public intent."""

    if (
        not isinstance(raw, bytes) or not raw
        or len(raw) > MAXIMUM_NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_BYTES
    ):
        raise ManagedProductRemovalProposalError("removal review intent size is invalid")
    try:
        payload = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_unique_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
        )
        if (
            not isinstance(payload, dict) or frozenset(payload) != _FIELDS
            or payload["schema"] != NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_SCHEMA
            or _canonical(payload) != raw
        ):
            raise ValueError("removal review intent is noncanonical")
        supplied = payload["intent_fingerprint"]
        unsigned = dict(payload)
        del unsigned["intent_fingerprint"]
        if not isinstance(supplied, str) or _HASH.fullmatch(supplied) is None:
            raise ValueError("removal review fingerprint is invalid")
        if supplied != _fingerprint(unsigned):
            raise ValueError("removal review fingerprint changed")
        for field in (
            "operation_id", "deployment_id", "forge_instance_id",
            "installed_composition_identity",
        ):
            if not isinstance(payload[field], str) or _ID.fullmatch(payload[field]) is None:
                raise ValueError("removal review identity is invalid")
        ep_id = payload["engineering_platform_instance_id"]
        if ep_id is not None and (not isinstance(ep_id, str) or _ID.fullmatch(ep_id) is None):
            raise ValueError("EP removal review identity is invalid")
        action = payload["action"]
        target = payload["target_component"]
        if (
            action not in {"REMOVE_COMPONENT", "REMOVE_DEPLOYMENT"}
            or action == "REMOVE_COMPONENT" and (target != FORGE_COMPONENT or ep_id is None)
            or action == "REMOVE_DEPLOYMENT" and target is not None
            or not isinstance(payload["installed_manifest_sha256"], str)
            or _DIGEST.fullmatch(payload["installed_manifest_sha256"]) is None
        ):
            raise ValueError("removal review target is unsupported")
        release = payload["installer_release"]
        if not isinstance(release, dict) or frozenset(release) != _RELEASE_FIELDS:
            raise ValueError("removal review release is invalid")
        binding = NativeInstallerReleaseBinding(**release)
        return NativeProductRemovalReviewIntent(
            payload["operation_id"], payload["deployment_id"], action, target,
            payload["forge_instance_id"], ep_id,
            payload["installed_composition_identity"],
            payload["installed_manifest_sha256"], binding, supplied,
        )
    except (UnicodeError, json.JSONDecodeError, TypeError, ValueError) as error:
        raise ManagedProductRemovalProposalError(
            "removal review intent is invalid"
        ) from error


def prepare_native_product_removal_review(
    canonical_intent: bytes, *,
    installed_manifest: CompositionManifest,
    registry: ManagedDeploymentRegistry,
    current_installer_release: NativeInstallerReleaseBinding,
) -> bytes:
    """Return a bounded public proposal; never mutate the registry or product."""

    try:
        intent = decode_native_product_removal_review_intent(canonical_intent)
        if (
            not isinstance(installed_manifest, CompositionManifest)
            or not isinstance(registry, ManagedDeploymentRegistry)
            or not isinstance(current_installer_release, NativeInstallerReleaseBinding)
            or intent.installer_release != current_installer_release
            or intent.installed_composition_identity != installed_manifest.composition_id
            or intent.installed_manifest_sha256 != installed_manifest.manifest_digest
        ):
            raise ValueError("removal review authority changed")
        current = registry.load(intent.deployment_id)
        if current is None:
            raise ValueError("reviewed deployment is unavailable")
        by_component = current.by_component
        if (
            set(by_component) not in ({FORGE_COMPONENT}, {FORGE_COMPONENT, EP_COMPONENT})
            or by_component[FORGE_COMPONENT].instance_id != intent.forge_instance_id
            or (by_component.get(EP_COMPONENT).instance_id if EP_COMPONENT in by_component else None)
                != intent.engineering_platform_instance_id
            or current.composition_binding is None
            or current.composition_binding.composition_id != installed_manifest.composition_id
            or current.composition_binding.manifest_digest != installed_manifest.manifest_digest
        ):
            raise ValueError("removal review target changed")
        desired = None
        if intent.action == "REMOVE_COMPONENT":
            if EP_COMPONENT not in by_component:
                raise ValueError("Forge removal requires retained EP")
            desired = replace(
                current, components=(by_component[EP_COMPONENT],), peer_binding=None,
            )
        plan = ManagedDeploymentPlanner.plan(current, desired)
        request = {
            "schema": NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA,
            "operation_id": intent.operation_id,
            "deployment_id": intent.deployment_id,
            "action": intent.action,
            "target_component": intent.target_component,
            "reviewed_revision": current.revision,
            "reviewed_deployment_sha256": _fingerprint(asdict(current)),
            "reviewed_plan_sha256": _fingerprint(asdict(plan)),
            "forge_instance_id": intent.forge_instance_id,
            "engineering_platform_instance_id": intent.engineering_platform_instance_id,
            "installed_composition_identity": intent.installed_composition_identity,
            "installed_manifest_sha256": intent.installed_manifest_sha256,
            "installer_release": asdict(intent.installer_release),
        }
        request["request_fingerprint"] = _fingerprint(request)
        decoded = decode_native_product_removal_request(_canonical(request))
        admitted = admit_native_product_removal(
            decoded, installed_manifest=installed_manifest, registry=registry,
            current_installer_release=current_installer_release,
        )
        if admitted.reviewed_current != current or admitted.plan != plan:
            raise ValueError("removal review changed while preparing")
        proposal = {
            "schema": NATIVE_PRODUCT_REMOVAL_REVIEW_PROPOSAL_SCHEMA,
            "intent_fingerprint": intent.intent_fingerprint,
            "request": request,
            "deployment_action": plan.deployment_action,
            "component_diffs": [
                asdict(diff) for diff in sorted(plan.component_diffs, key=lambda item: item.component)
            ],
            "resulting_components": (
                [] if plan.desired is None else sorted(plan.desired.by_component)
            ),
        }
        raw = _canonical(proposal)
        if not raw or len(raw) > MAXIMUM_NATIVE_PRODUCT_REMOVAL_REVIEW_PROPOSAL_BYTES:
            raise ValueError("removal review proposal exceeded its bound")
        return raw
    except Exception as error:
        raise ManagedProductRemovalProposalError(
            "removal review proposal is unavailable"
        ) from error
