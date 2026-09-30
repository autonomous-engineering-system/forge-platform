"""Canonical native execution request for reviewed preserved lifecycle work.

The caller supplies only the public review already returned by the helper.
Installed product paths, commands, service controls and credentials are absent.
PURGE requires a separate exact-instance confirmation. RESTORE remains unavailable.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json

from .component_operations import QualifiedArtifact
from .managed_preserved_lifecycle_plan import ManagedPreservedLifecycleReview
from .managed_preserved_lifecycle_proposal import (
    MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_BYTES,
    NativePreservedLifecycleReviewIntent,
    decode_native_preserved_lifecycle_review_intent,
    decode_native_preserved_lifecycle_review_proposal,
)


NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA = (
    "forge-platform.native-preserved-lifecycle-request/v1"
)
NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA = (
    "forge-platform.native-preserved-lifecycle-request/v2"
)
NATIVE_PRESERVED_LIFECYCLE_RECEIPT_SCHEMA = (
    "forge-platform.native-preserved-lifecycle-receipt/v1"
)
MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REQUEST_BYTES = 40 * 1024
MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_RECEIPT_BYTES = 4 * 1024


class ManagedPreservedLifecycleRequestError(RuntimeError):
    """Execution request or terminal worker receipt changed after review."""


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"),
        ensure_ascii=True, allow_nan=False,
    ).encode("utf-8")


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate lifecycle execution field")
        result[key] = value
    return result


def _read(raw: bytes, maximum: int) -> dict[str, object]:
    if not isinstance(raw, bytes) or not raw or len(raw) > maximum:
        raise ValueError("lifecycle execution size is invalid")
    payload = json.loads(
        raw.decode("utf-8"), object_pairs_hook=_unique,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
    )
    if not isinstance(payload, dict) or _canonical(payload) != raw:
        raise ValueError("lifecycle execution is noncanonical")
    return payload


@dataclass(frozen=True)
class NativePreservedLifecycleRequest:
    intent: NativePreservedLifecycleReviewIntent
    review: ManagedPreservedLifecycleReview
    request_fingerprint: str
    confirmed_instance_id: str | None = None


def decode_native_preserved_lifecycle_request(raw: bytes) -> NativePreservedLifecycleRequest:
    try:
        payload = _read(raw, MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REQUEST_BYTES)
        schema = payload.get("schema")
        required = {"schema", "intent", "proposal", "request_fingerprint"}
        if schema == NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA:
            required.add("confirmed_instance_id")
        if (
            set(payload) != required
            or schema not in {
                NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA,
                NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA,
            }
            or not isinstance(payload["intent"], dict)
            or not isinstance(payload["proposal"], dict)
            or not isinstance(payload["request_fingerprint"], str)
        ):
            raise ValueError("lifecycle request envelope changed")
        unsigned = dict(payload)
        fingerprint = unsigned.pop("request_fingerprint")
        if fingerprint != sha256(_canonical(unsigned)).hexdigest():
            raise ValueError("lifecycle request fingerprint changed")
        intent = decode_native_preserved_lifecycle_review_intent(_canonical(payload["intent"]))
        if (
            schema == NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA
            and intent.operation != "PRESERVE"
            or schema == NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA
            and intent.operation != "PURGE"
        ):
            raise ValueError("lifecycle request schema or mutation is unavailable")
        proposal_raw = _canonical(payload["proposal"])
        if len(proposal_raw) > MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_BYTES:
            raise ValueError("lifecycle proposal exceeds bound")
        proposal = decode_native_preserved_lifecycle_review_proposal(
            proposal_raw, intent=intent,
        )
        review_wire = dict(proposal["review"])
        review_wire["artifact"] = QualifiedArtifact(**review_wire["artifact"])
        review = ManagedPreservedLifecycleReview(**review_wire)
        confirmation = payload.get("confirmed_instance_id")
        if schema == NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA:
            if review.destructive_confirmation_required or review.preserve_operation_id is not None:
                raise ValueError("preserve request carries incompatible lifecycle authority")
        elif (
            review.destructive_confirmation_required is not True
            or confirmation != intent.instance_id
            or confirmation != review.instance_id
        ):
            raise ValueError("purge confirmation does not name the reviewed instance")
        return NativePreservedLifecycleRequest(intent, review, fingerprint, confirmation)
    except Exception as error:
        raise ManagedPreservedLifecycleRequestError(
            "preserved lifecycle execution request was rejected"
        ) from error


def encode_native_preserved_lifecycle_receipt(
    request: NativePreservedLifecycleRequest, *,
    receipt_digest: str, registry_revision: int,
) -> bytes:
    value = {
        "schema": NATIVE_PRESERVED_LIFECYCLE_RECEIPT_SCHEMA,
        "request_fingerprint": request.request_fingerprint,
        "operation_id": request.review.operation_id,
        "deployment_id": request.review.deployment_id,
        "component": request.review.component,
        "instance_id": request.review.instance_id,
        "state": "COMPLETE",
        "receipt_digest": receipt_digest,
        "registry_revision": registry_revision,
    }
    raw = _canonical(value)
    if len(raw) > MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_RECEIPT_BYTES:
        raise ManagedPreservedLifecycleRequestError("lifecycle receipt exceeds bound")
    decode_native_preserved_lifecycle_receipt(raw, request=request)
    return raw


def decode_native_preserved_lifecycle_receipt(
    raw: bytes, *, request: NativePreservedLifecycleRequest,
) -> dict[str, object]:
    if not isinstance(request, NativePreservedLifecycleRequest):
        raise ManagedPreservedLifecycleRequestError("lifecycle request is unavailable")
    try:
        value = _read(raw, MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_RECEIPT_BYTES)
        if (
            set(value) != {
                "schema", "request_fingerprint", "operation_id", "deployment_id",
                "component", "instance_id", "state", "receipt_digest",
                "registry_revision",
            }
            or value["schema"] != NATIVE_PRESERVED_LIFECYCLE_RECEIPT_SCHEMA
            or value["request_fingerprint"] != request.request_fingerprint
            or value["operation_id"] != request.review.operation_id
            or value["deployment_id"] != request.review.deployment_id
            or value["component"] != request.review.component
            or value["instance_id"] != request.review.instance_id
            or value["state"] != "COMPLETE"
            or not isinstance(value["receipt_digest"], str)
            or len(value["receipt_digest"]) != 71
            or not value["receipt_digest"].startswith("sha256:")
            or any(character not in "0123456789abcdef" for character in value["receipt_digest"][7:])
            or type(value["registry_revision"]) is not int
            or value["registry_revision"] != request.review.registry_revision + 1
        ):
            raise ValueError("lifecycle receipt identity changed")
        return value
    except Exception as error:
        raise ManagedPreservedLifecycleRequestError(
            "preserved lifecycle execution receipt was rejected"
        ) from error
