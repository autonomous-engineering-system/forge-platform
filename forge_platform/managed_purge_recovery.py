"""Canonical read-only recovery of one previously confirmed PURGE."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256

from .managed_preserve_execution import ManagedPreserveExecutionRecord
from .managed_preserved_lifecycle_request import (
    NativePreservedLifecycleRequest, _canonical, _read,
    decode_native_preserved_lifecycle_request,
)


NATIVE_PURGE_RECOVERY_REQUEST_SCHEMA = "forge-platform.native-purge-recovery-request/v1"
NATIVE_PURGE_RECOVERY_RECEIPT_SCHEMA = "forge-platform.native-purge-recovery-receipt/v1"
MAXIMUM_NATIVE_PURGE_RECOVERY_REQUEST_BYTES = 48 * 1024
MAXIMUM_NATIVE_PURGE_RECOVERY_RECEIPT_BYTES = 4 * 1024


class ManagedPurgeRecoveryError(RuntimeError):
    """The original reviewed target or terminal proof changed."""


@dataclass(frozen=True)
class NativePurgeRecoveryRequest:
    execution: NativePreservedLifecycleRequest
    request_fingerprint: str


def decode_native_purge_recovery_request(raw: bytes) -> NativePurgeRecoveryRequest:
    try:
        payload = _read(raw, MAXIMUM_NATIVE_PURGE_RECOVERY_REQUEST_BYTES)
        if (
            set(payload) != {"schema", "execution_request", "request_fingerprint"}
            or payload["schema"] != NATIVE_PURGE_RECOVERY_REQUEST_SCHEMA
            or not isinstance(payload["execution_request"], dict)
            or not isinstance(payload["request_fingerprint"], str)
        ):
            raise ValueError("purge recovery envelope changed")
        unsigned = dict(payload)
        fingerprint = unsigned.pop("request_fingerprint")
        if fingerprint != sha256(_canonical(unsigned)).hexdigest():
            raise ValueError("purge recovery fingerprint changed")
        execution = decode_native_preserved_lifecycle_request(
            _canonical(payload["execution_request"])
        )
        if (
            execution.intent.operation != "PURGE"
            or execution.confirmed_instance_id != execution.review.instance_id
            or execution.review.historical_peer_reference is not None
                and execution.review.component != "forge-runtime"
        ):
            raise ValueError("confirmed PURGE recovery target is unsupported")
        return NativePurgeRecoveryRequest(execution, fingerprint)
    except Exception as error:
        raise ManagedPurgeRecoveryError("purge recovery request was rejected") from error


def _require_terminal(
    request: NativePurgeRecoveryRequest, record: ManagedPreserveExecutionRecord,
) -> None:
    if not isinstance(request, NativePurgeRecoveryRequest):
        raise ManagedPurgeRecoveryError("purge recovery request is unavailable")
    review = request.execution.review
    if (
        not isinstance(record, ManagedPreserveExecutionRecord)
        or record.state != "COMPLETE"
        or record.operation_id != review.operation_id
        or record.deployment_id != review.deployment_id
        or record.component != review.component
        or record.instance_id != review.instance_id
        or record.review_fingerprint != review.review_fingerprint
        or not isinstance(record.receipt_digest, str)
        or len(record.receipt_digest) != 71
        or not record.receipt_digest.startswith("sha256:")
        or any(character not in "0123456789abcdef" for character in record.receipt_digest[7:])
        or type(record.registry_revision) is not int
        or record.registry_revision != review.registry_revision + 1
    ):
        raise ManagedPurgeRecoveryError("terminal purge evidence changed")


def encode_native_purge_recovery_receipt(
    request: NativePurgeRecoveryRequest, record: ManagedPreserveExecutionRecord,
) -> bytes:
    _require_terminal(request, record)
    raw = _canonical({
        "schema": NATIVE_PURGE_RECOVERY_RECEIPT_SCHEMA,
        "request_fingerprint": request.request_fingerprint,
        "execution_request_fingerprint": request.execution.request_fingerprint,
        "record": asdict(record),
    })
    if len(raw) > MAXIMUM_NATIVE_PURGE_RECOVERY_RECEIPT_BYTES:
        raise ManagedPurgeRecoveryError("purge recovery receipt exceeded bound")
    return raw


def decode_native_purge_recovery_receipt(
    raw: bytes, *, request: NativePurgeRecoveryRequest,
) -> ManagedPreserveExecutionRecord:
    if not isinstance(request, NativePurgeRecoveryRequest):
        raise ManagedPurgeRecoveryError("purge recovery request is unavailable")
    try:
        payload = _read(raw, MAXIMUM_NATIVE_PURGE_RECOVERY_RECEIPT_BYTES)
        if (
            set(payload) != {
                "schema", "request_fingerprint", "execution_request_fingerprint", "record",
            }
            or payload["schema"] != NATIVE_PURGE_RECOVERY_RECEIPT_SCHEMA
            or payload["request_fingerprint"] != request.request_fingerprint
            or payload["execution_request_fingerprint"]
                != request.execution.request_fingerprint
            or not isinstance(payload["record"], dict)
            or set(payload["record"]) != set(ManagedPreserveExecutionRecord.__dataclass_fields__)
        ):
            raise ValueError("purge recovery receipt envelope changed")
        record = ManagedPreserveExecutionRecord(**payload["record"])
        _require_terminal(request, record)
        return record
    except Exception as error:
        raise ManagedPurgeRecoveryError("purge recovery receipt was rejected") from error
