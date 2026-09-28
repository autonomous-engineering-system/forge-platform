"""Canonical read-only lifecycle review through helper-owned inventory.

The native caller selects only public operation and instance identities. The
helper chooses the installed signed manifest and derives all review evidence
from its own registry. A proposal never grants product mutation authority.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256
import json
import re

from .component_operations import QualifiedArtifact
from .managed_deployments import ManagedDeploymentRegistry
from .managed_preserved_lifecycle_plan import prepare_preserved_lifecycle_review
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .product_preserved_lifecycle import (
    EP_COMPONENT, FORGE_COMPONENT, frozen_preserved_release,
)
from .universal_installer import CompositionManifest


NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_SCHEMA = (
    "forge-platform.native-preserved-lifecycle-review-intent/v1"
)
NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_SCHEMA = (
    "forge-platform.native-preserved-lifecycle-review-proposal/v1"
)
MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_BYTES = 8 * 1024
MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_BYTES = 24 * 1024
_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_HASH = re.compile(r"[0-9a-f]{64}\Z")
_RECEIPT = re.compile(r"receipt:[a-z0-9][a-z0-9._-]{0,127}\Z")
_INTENT_FIELDS = frozenset({
    "schema", "operation_id", "deployment_id", "operation", "component",
    "instance_id", "installed_composition_identity", "installed_manifest_sha256",
    "installer_release", "intent_fingerprint",
})
_RELEASE_FIELDS = frozenset({
    "version", "release_page", "asset_name", "sha256", "signing_key_id",
})
_REVIEW_FIELDS = frozenset({
    "deployment_id", "registry_revision", "registry_fingerprint",
    "composition_id", "composition_digest", "operation", "operation_id",
    "component", "instance_id", "artifact", "previous_receipt_reference",
    "preserve_operation_id", "preserve_receipt_digest",
    "historical_peer_reference", "destructive_confirmation_required",
    "review_fingerprint",
})
_ARTIFACT_FIELDS = frozenset({
    "version", "source_revision", "source", "digest", "qualification",
})


class ManagedPreservedLifecycleProposalError(RuntimeError):
    """The helper lifecycle proposal is absent, stale or ambiguous."""


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
            raise ValueError("duplicate preserved lifecycle review field")
        result[key] = value
    return result


def _read(raw: bytes, maximum: int) -> dict[str, object]:
    if not isinstance(raw, bytes) or not raw or len(raw) > maximum:
        raise ValueError("preserved lifecycle review size is invalid")
    payload = json.loads(
        raw.decode("utf-8"), object_pairs_hook=_unique_object,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
    )
    if not isinstance(payload, dict) or _canonical(payload) != raw:
        raise ValueError("preserved lifecycle review is noncanonical")
    return payload


@dataclass(frozen=True)
class NativePreservedLifecycleReviewIntent:
    operation_id: str
    deployment_id: str
    operation: str
    component: str
    instance_id: str
    installed_composition_identity: str
    installed_manifest_sha256: str
    installer_release: NativeInstallerReleaseBinding
    intent_fingerprint: str


def decode_native_preserved_lifecycle_review_intent(
    raw: bytes,
) -> NativePreservedLifecycleReviewIntent:
    try:
        payload = _read(raw, MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_BYTES)
        if (
            frozenset(payload) != _INTENT_FIELDS
            or payload["schema"] != NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_SCHEMA
            or payload["operation"] not in {"PRESERVE", "RESTORE", "PURGE"}
            or payload["component"] not in {FORGE_COMPONENT, EP_COMPONENT}
            or any(
                not isinstance(payload[key], str) or _ID.fullmatch(payload[key]) is None
                for key in (
                    "operation_id", "deployment_id", "instance_id",
                    "installed_composition_identity",
                )
            )
            or not isinstance(payload["installed_manifest_sha256"], str)
            or _DIGEST.fullmatch(payload["installed_manifest_sha256"]) is None
            or not isinstance(payload["intent_fingerprint"], str)
            or _HASH.fullmatch(payload["intent_fingerprint"]) is None
        ):
            raise ValueError("preserved lifecycle target is invalid")
        unsigned = dict(payload)
        del unsigned["intent_fingerprint"]
        if payload["intent_fingerprint"] != _fingerprint(unsigned):
            raise ValueError("preserved lifecycle intent fingerprint changed")
        release = payload["installer_release"]
        if not isinstance(release, dict) or frozenset(release) != _RELEASE_FIELDS:
            raise ValueError("installer release binding is invalid")
        binding = NativeInstallerReleaseBinding(**release)
        return NativePreservedLifecycleReviewIntent(
            payload["operation_id"], payload["deployment_id"],
            payload["operation"], payload["component"], payload["instance_id"],
            payload["installed_composition_identity"],
            payload["installed_manifest_sha256"], binding,
            payload["intent_fingerprint"],
        )
    except (UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise ManagedPreservedLifecycleProposalError(
            "preserved lifecycle review intent was rejected"
        ) from error


def prepare_native_preserved_lifecycle_review(
    canonical_intent: bytes, *, installed_manifest: CompositionManifest,
    registry: ManagedDeploymentRegistry,
    current_installer_release: NativeInstallerReleaseBinding,
) -> bytes:
    """Return only an exact read-only proposal from the helper registry."""
    try:
        intent = decode_native_preserved_lifecycle_review_intent(canonical_intent)
        if (
            not isinstance(installed_manifest, CompositionManifest)
            or not isinstance(registry, ManagedDeploymentRegistry)
            or not isinstance(current_installer_release, NativeInstallerReleaseBinding)
            or intent.installer_release != current_installer_release
            or intent.installed_composition_identity != installed_manifest.composition_id
            or intent.installed_manifest_sha256 != installed_manifest.manifest_digest
        ):
            raise ValueError("installed lifecycle authority changed")
        current = registry.load(intent.deployment_id)
        if current is None:
            raise ValueError("reviewed deployment is unavailable")
        review = prepare_preserved_lifecycle_review(
            current=current, installed_manifest=installed_manifest,
            operation=intent.operation, operation_id=intent.operation_id,
            component=intent.component, instance_id=intent.instance_id,
        )
        proposal = {
            "schema": NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_SCHEMA,
            "intent_fingerprint": intent.intent_fingerprint,
            "review": asdict(review),
        }
        raw = _canonical(proposal)
        if len(raw) > MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_BYTES:
            raise ValueError("preserved lifecycle review proposal exceeded its bound")
        return raw
    except Exception as error:
        raise ManagedPreservedLifecycleProposalError(
            "preserved lifecycle review is unavailable"
        ) from error


def decode_native_preserved_lifecycle_review_proposal(
    raw: bytes, *, intent: NativePreservedLifecycleReviewIntent,
) -> dict[str, object]:
    """Independently reject a changed proposal before emitting it to native UI."""
    if not isinstance(intent, NativePreservedLifecycleReviewIntent):
        raise ManagedPreservedLifecycleProposalError("preserved lifecycle intent is unavailable")
    try:
        proposal = _read(raw, MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_BYTES)
        if (
            frozenset(proposal) != {"schema", "intent_fingerprint", "review"}
            or proposal["schema"] != NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_SCHEMA
            or proposal["intent_fingerprint"] != intent.intent_fingerprint
            or not isinstance(proposal["review"], dict)
        ):
            raise ValueError("preserved lifecycle proposal envelope changed")
        review = proposal["review"]
        if (
            frozenset(review) != _REVIEW_FIELDS
            or not isinstance(review["artifact"], dict)
            or frozenset(review["artifact"]) != _ARTIFACT_FIELDS
            or any(review[key] != getattr(intent, expected) for key, expected in (
                ("deployment_id", "deployment_id"),
                ("composition_id", "installed_composition_identity"),
                ("composition_digest", "installed_manifest_sha256"),
                ("operation", "operation"),
                ("operation_id", "operation_id"),
                ("component", "component"),
                ("instance_id", "instance_id"),
            ))
            or type(review["registry_revision"]) is not int
            or review["registry_revision"] <= 0
            or review["destructive_confirmation_required"] is not (intent.operation == "PURGE")
            or not isinstance(review["review_fingerprint"], str)
            or _DIGEST.fullmatch(review["review_fingerprint"]) is None
            or not isinstance(review["registry_fingerprint"], str)
            or _DIGEST.fullmatch(review["registry_fingerprint"]) is None
            or not isinstance(review["previous_receipt_reference"], str)
            or _RECEIPT.fullmatch(review["previous_receipt_reference"]) is None
            or review["historical_peer_reference"] is not None and (
                not isinstance(review["historical_peer_reference"], str)
                or _RECEIPT.fullmatch(review["historical_peer_reference"]) is None
            )
            or review["preserve_operation_id"] is not None and (
                not isinstance(review["preserve_operation_id"], str)
                or _ID.fullmatch(review["preserve_operation_id"]) is None
            )
            or any(
                value is not None and (
                    not isinstance(value, str) or _DIGEST.fullmatch(value) is None
                ) for value in (review["preserve_receipt_digest"],)
            )
        ):
            raise ValueError("preserved lifecycle proposal target changed")
        if not frozen_preserved_release(
            intent.component, QualifiedArtifact(**review["artifact"]),
        ):
            raise ValueError("preserved lifecycle producer release changed")
        unsigned = dict(review)
        supplied = unsigned.pop("review_fingerprint")
        if "sha256:" + _fingerprint(unsigned) != supplied:
            raise ValueError("preserved lifecycle review fingerprint changed")
        if intent.operation == "RESTORE" and (
            not isinstance(review["preserve_operation_id"], str)
            or not isinstance(review["preserve_receipt_digest"], str)
        ):
            raise ValueError("restore has no exact preserve evidence")
        return proposal
    except (UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise ManagedPreservedLifecycleProposalError(
            "preserved lifecycle review proposal was rejected"
        ) from error
