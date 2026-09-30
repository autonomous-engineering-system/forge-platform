"""Read-only, exact-target review for product-owned preserved lifecycles.

This plan is a review boundary only. It grants no helper, filesystem, service,
provider or product mutation authority. The dispatcher must bind its product
request and terminal commit to this exact review and recheck it before mutation.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256
import json
import re

from .component_operations import QualifiedArtifact
from .managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2,
    MANAGED_DEPLOYMENT_SCHEMA_V3,
    ManagedDeployment,
    ManagedDeploymentError,
    SERVER_COMPONENTS,
)
from .product_preserved_lifecycle import frozen_preserved_release
from .universal_installer import CompositionManifest


_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}\Z")
_OPERATIONS = frozenset({"PRESERVE", "RESTORE", "PURGE"})


def _fingerprint(value: object) -> str:
    payload = json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode("utf-8")
    return "sha256:" + sha256(payload).hexdigest()


@dataclass(frozen=True)
class ManagedPreservedLifecycleReview:
    deployment_id: str
    registry_revision: int
    registry_fingerprint: str
    composition_id: str
    composition_digest: str
    operation: str
    operation_id: str
    component: str
    instance_id: str
    artifact: QualifiedArtifact
    previous_receipt_reference: str
    preserve_operation_id: str | None
    preserve_receipt_digest: str | None
    historical_peer_reference: str | None
    destructive_confirmation_required: bool
    review_fingerprint: str


def prepare_preserved_lifecycle_review(
    *, current: ManagedDeployment, installed_manifest: CompositionManifest,
    operation: str, operation_id: str, component: str, instance_id: str,
) -> ManagedPreservedLifecycleReview:
    """Bind one reviewed transition to exact inventory and installed release."""
    if (
        not isinstance(current, ManagedDeployment)
        or current.schema not in {
            MANAGED_DEPLOYMENT_SCHEMA_V2, MANAGED_DEPLOYMENT_SCHEMA_V3,
        }
        or not isinstance(installed_manifest, CompositionManifest)
        or operation not in _OPERATIONS
        or component not in SERVER_COMPONENTS
        or not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
        or not isinstance(instance_id, str) or _ID.fullmatch(instance_id) is None
    ):
        raise ManagedDeploymentError("preserved lifecycle review target is invalid")
    binding = current.composition_binding
    if (
        binding is None
        or binding.composition_id != installed_manifest.composition_id
        or binding.manifest_digest != installed_manifest.manifest_digest
    ):
        raise ManagedDeploymentError("installed composition changed before lifecycle review")
    selected = [
        item.artifact for item in installed_manifest.components
        if item.identity == component
    ]
    if len(selected) != 1 or not frozen_preserved_release(component, selected[0]):
        raise ManagedDeploymentError("exact frozen lifecycle product is unavailable")
    artifact = selected[0]
    active = current.active_by_component.get(component)
    preserved = current.preserved_by_component.get(component)
    target = preserved if operation == "RESTORE" else active or preserved
    if (
        target is None or target.instance_id != instance_id
        or operation == "PRESERVE" and active is None
        or operation == "RESTORE" and preserved is None
        or operation == "PURGE" and active is None and preserved is None
    ):
        raise ManagedDeploymentError("reviewed lifecycle state or instance changed")
    if preserved is not None and (
        preserved.version, preserved.source_revision, preserved.artifact_digest
    ) != (artifact.version, artifact.source_revision, artifact.digest):
        raise ManagedDeploymentError("preserved product release changed")
    previous_reference = (
        preserved.previous_receipt_reference if preserved is not None
        else active.receipt_reference  # type: ignore[union-attr]
    )
    historical = getattr(current, "historical_peer_binding", None) or current.peer_binding
    values = {
        "deployment_id": current.deployment_id,
        "registry_revision": current.revision,
        "registry_fingerprint": _fingerprint(asdict(current)),
        "composition_id": binding.composition_id,
        "composition_digest": binding.manifest_digest,
        "operation": operation,
        "operation_id": operation_id,
        "component": component,
        "instance_id": instance_id,
        "artifact": asdict(artifact),
        "previous_receipt_reference": previous_reference,
        "preserve_operation_id": preserved.preserve_operation_id if preserved else None,
        "preserve_receipt_digest": preserved.preserve_receipt_digest if preserved else None,
        "historical_peer_reference": historical.receipt_reference if historical else None,
        "destructive_confirmation_required": operation == "PURGE",
    }
    return ManagedPreservedLifecycleReview(
        current.deployment_id, current.revision, values["registry_fingerprint"],
        binding.composition_id, binding.manifest_digest, operation, operation_id,
        component, instance_id, artifact, previous_reference,
        values["preserve_operation_id"], values["preserve_receipt_digest"],
        values["historical_peer_reference"], operation == "PURGE",
        _fingerprint(values),
    )


def require_current_preserved_lifecycle_review(
    review: ManagedPreservedLifecycleReview, *, current: ManagedDeployment,
    installed_manifest: CompositionManifest,
) -> None:
    """Fresh readback immediately before product mutation, fail closed on drift."""
    if not isinstance(review, ManagedPreservedLifecycleReview):
        raise ManagedDeploymentError("reviewed lifecycle authority is unavailable")
    fresh = prepare_preserved_lifecycle_review(
        current=current, installed_manifest=installed_manifest,
        operation=review.operation, operation_id=review.operation_id,
        component=review.component, instance_id=review.instance_id,
    )
    if fresh != review:
        raise ManagedDeploymentError("reviewed lifecycle inventory changed")
