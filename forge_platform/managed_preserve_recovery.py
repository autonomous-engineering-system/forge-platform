"""Canonical read-only terminal PRESERVE recovery request and receipt."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256

from .managed_preserve_execution import ManagedPreserveExecutionRecord
from .managed_preserved_lifecycle_proposal import (
    NativePreservedLifecycleReviewIntent, _DIGEST, _canonical, _read,
    decode_native_preserved_lifecycle_review_intent,
)


NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA = "forge-platform.native-preserve-recovery-request/v1"
NATIVE_PRESERVE_RECOVERY_RECEIPT_SCHEMA = "forge-platform.native-preserve-recovery-receipt/v1"
MAXIMUM_NATIVE_PRESERVE_RECOVERY_REQUEST_BYTES = 12 * 1024
MAXIMUM_NATIVE_PRESERVE_RECOVERY_RECEIPT_BYTES = 4 * 1024


class ManagedPreserveRecoveryError(RuntimeError):
    """Recovery request or terminal evidence cannot be admitted exactly."""


@dataclass(frozen=True)
class NativePreserveRecoveryRequest:
    intent: NativePreservedLifecycleReviewIntent
    request_fingerprint: str


def decode_native_preserve_recovery_request(raw: bytes) -> NativePreserveRecoveryRequest:
    try:
        payload = _read(raw, MAXIMUM_NATIVE_PRESERVE_RECOVERY_REQUEST_BYTES)
        if (
            frozenset(payload) != {"schema", "intent", "request_fingerprint"}
            or payload["schema"] != NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA
            or not isinstance(payload["intent"], dict)
            or not isinstance(payload["request_fingerprint"], str)
        ):
            raise ValueError("recovery request envelope changed")
        intent = decode_native_preserved_lifecycle_review_intent(
            _canonical(payload["intent"])
        )
        if intent.operation != "PRESERVE":
            raise ValueError("only terminal PRESERVE can be recovered")
        unsigned = dict(payload)
        unsigned.pop("request_fingerprint")
        fingerprint = sha256(_canonical(unsigned)).hexdigest()
        if payload["request_fingerprint"] != fingerprint:
            raise ValueError("recovery request fingerprint changed")
        return NativePreserveRecoveryRequest(intent, fingerprint)
    except Exception as error:
        raise ManagedPreserveRecoveryError("preserve recovery request was rejected") from error


def encode_native_preserve_recovery_receipt(
    request: NativePreserveRecoveryRequest,
    record: ManagedPreserveExecutionRecord,
) -> bytes:
    if (
        not isinstance(request, NativePreserveRecoveryRequest)
        or not isinstance(record, ManagedPreserveExecutionRecord)
        or record.state != "COMPLETE"
        or record.operation_id != request.intent.operation_id
        or record.deployment_id != request.intent.deployment_id
        or record.component != request.intent.component
        or record.instance_id != request.intent.instance_id
        or record.receipt_digest is None or record.registry_revision is None
        or _DIGEST.fullmatch(record.review_fingerprint) is None
        or _DIGEST.fullmatch(record.receipt_digest) is None
        or isinstance(record.registry_revision, bool)
        or not isinstance(record.registry_revision, int)
        or record.registry_revision < 1
    ):
        raise ManagedPreserveRecoveryError("terminal preserve evidence changed")
    payload = {
        "schema": NATIVE_PRESERVE_RECOVERY_RECEIPT_SCHEMA,
        "request_fingerprint": request.request_fingerprint,
        "intent_fingerprint": request.intent.intent_fingerprint,
        "record": asdict(record),
    }
    raw = _canonical(payload)
    if len(raw) > MAXIMUM_NATIVE_PRESERVE_RECOVERY_RECEIPT_BYTES:
        raise ManagedPreserveRecoveryError("preserve recovery receipt exceeded bound")
    return raw


def decode_native_preserve_recovery_receipt(
    raw: bytes, *, request: NativePreserveRecoveryRequest,
) -> ManagedPreserveExecutionRecord:
    if not isinstance(request, NativePreserveRecoveryRequest):
        raise ManagedPreserveRecoveryError("preserve recovery request is unavailable")
    try:
        payload = _read(raw, MAXIMUM_NATIVE_PRESERVE_RECOVERY_RECEIPT_BYTES)
        if (
            frozenset(payload) != {
                "schema", "request_fingerprint", "intent_fingerprint", "record",
            }
            or payload["schema"] != NATIVE_PRESERVE_RECOVERY_RECEIPT_SCHEMA
            or payload["request_fingerprint"] != request.request_fingerprint
            or payload["intent_fingerprint"] != request.intent.intent_fingerprint
            or not isinstance(payload["record"], dict)
            or frozenset(payload["record"])
                != frozenset(ManagedPreserveExecutionRecord.__dataclass_fields__)
        ):
            raise ValueError("preserve recovery receipt envelope changed")
        record = ManagedPreserveExecutionRecord(**payload["record"])
        if (
            record.state != "COMPLETE"
            or record.operation_id != request.intent.operation_id
            or record.deployment_id != request.intent.deployment_id
            or record.component != request.intent.component
            or record.instance_id != request.intent.instance_id
            or not isinstance(record.review_fingerprint, str)
            or _DIGEST.fullmatch(record.review_fingerprint) is None
            or not isinstance(record.receipt_digest, str)
            or _DIGEST.fullmatch(record.receipt_digest) is None
            or isinstance(record.registry_revision, bool)
            or not isinstance(record.registry_revision, int)
            or record.registry_revision < 1
        ):
            raise ValueError("terminal preserve recovery record changed")
        return record
    except Exception as error:
        raise ManagedPreserveRecoveryError("preserve recovery receipt was rejected") from error
