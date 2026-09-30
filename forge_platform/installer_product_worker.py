"""Bounded entrypoint for the privileged managed-installer product worker.

The zipapp receives exactly one canonical native request on stdin and emits at
most one canonical terminal receipt on stdout.  Construction of the released
helper service remains a separate helper-owned authority boundary.
"""

from __future__ import annotations

from typing import BinaryIO, Callable
import json
import sys

from .managed_product_operation_admission import MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES
from .managed_product_removal_admission import (
    NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA,
    decode_native_product_removal_request,
)
from .managed_product_removal_proposal import (
    NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_SCHEMA,
    decode_native_product_removal_review_intent,
    decode_native_product_removal_review_proposal,
)
from .managed_preserved_lifecycle_proposal import (
    NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_SCHEMA,
    decode_native_preserved_lifecycle_review_intent,
    decode_native_preserved_lifecycle_review_proposal,
)
from .managed_preserved_lifecycle_request import (
    NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA,
    MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_RECEIPT_BYTES,
    NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA,
    decode_native_preserved_lifecycle_receipt,
    decode_native_preserved_lifecycle_request,
)
from .managed_preserve_recovery import (
    MAXIMUM_NATIVE_PRESERVE_RECOVERY_RECEIPT_BYTES,
    NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA,
    decode_native_preserve_recovery_request,
    decode_native_preserve_recovery_receipt,
)
from .managed_purge_recovery import (
    MAXIMUM_NATIVE_PURGE_RECOVERY_RECEIPT_BYTES,
    NATIVE_PURGE_RECOVERY_REQUEST_SCHEMA,
    decode_native_purge_recovery_request,
    decode_native_purge_recovery_receipt,
)
from .managed_product_operation_service import (
    MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES,
    MAXIMUM_NATIVE_PRODUCT_REMOVAL_RECEIPT_BYTES,
    NATIVE_PRODUCT_REMOVAL_RECEIPT_SCHEMA,
    ManagedProductOperationHelperService,
)
from .managed_product_wheel_worker import SCHEMA as PRODUCT_WHEEL_WORKER_SCHEMA
from .managed_product_wheel_worker import execute_wheel_request
from .product_worker_authority import ProductWorkerAuthorityLoader


class InstallerProductWorkerUnavailable(RuntimeError):
    """The released helper authority has not been loaded safely."""


ServiceLoader = Callable[[], ManagedProductOperationHelperService]


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate worker receipt field")
        result[key] = value
    return result


def load_released_product_service() -> ManagedProductOperationHelperService:
    """Load only the fixed root-owned released product authority."""

    try:
        return ProductWorkerAuthorityLoader().load()
    except Exception as error:
        raise InstallerProductWorkerUnavailable(
            "released product-worker authority is unavailable"
        ) from error


def execute_product_request(
    canonical_request: bytes,
    *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    if (
        not isinstance(canonical_request, bytes)
        or not canonical_request
        or len(canonical_request) > MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES
    ):
        raise InstallerProductWorkerUnavailable("product request is unavailable")
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("product service is unavailable")
    response = service.execute(canonical_request)
    if (
        not isinstance(response, bytes)
        or not response
        or len(response) > MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES
    ):
        raise InstallerProductWorkerUnavailable("product receipt is unavailable")
    return response


def execute_removal_request(
    canonical_request: bytes,
    *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    """Run only the exact removal schema and independently bind its receipt."""

    request = decode_native_product_removal_request(canonical_request)
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("product removal service is unavailable")
    response = service.execute_removal(canonical_request)
    if (
        not isinstance(response, bytes) or not response
        or len(response) > MAXIMUM_NATIVE_PRODUCT_REMOVAL_RECEIPT_BYTES
    ):
        raise InstallerProductWorkerUnavailable("product removal receipt is unavailable")
    try:
        payload = json.loads(
            response.decode("utf-8"), object_pairs_hook=_unique_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
        )
        expected = {
            "schema", "request_fingerprint", "operation_id", "deployment_id",
            "action", "plan_fingerprint", "state", "registry_revision", "components",
        }
        if (
            not isinstance(payload, dict) or set(payload) != expected
            or _canonical(payload) != response
            or payload["schema"] != NATIVE_PRODUCT_REMOVAL_RECEIPT_SCHEMA
            or payload["request_fingerprint"] != request.request_fingerprint
            or payload["operation_id"] != request.operation_id
            or payload["deployment_id"] != request.deployment_id
            or payload["action"] != request.action
            or payload["plan_fingerprint"] != "sha256:" + request.reviewed_plan_sha256
            or payload["state"] not in {"COMPLETE", "RECOVERY_PENDING"}
            or not isinstance(payload["components"], list)
            or not payload["components"]
        ):
            raise ValueError("removal receipt identity changed")
        revision = payload["registry_revision"]
        if (
            payload["state"] == "RECOVERY_PENDING" and revision is not None
            or payload["state"] == "COMPLETE" and (
                isinstance(revision, bool) or not isinstance(revision, int)
                or request.action == "REMOVE_DEPLOYMENT" and revision != 0
                or request.action == "REMOVE_COMPONENT" and revision != request.reviewed_revision + 1
            )
        ):
            raise ValueError("removal registry disposition changed")
        components = payload["components"]
        expected_components = (
            {"forge-runtime", "engineering-platform-server"}
            if request.engineering_platform_instance_id is not None
            else {"forge-runtime"}
        )
        if (
            len(components) != len(expected_components)
            or [item.get("component") for item in components if isinstance(item, dict)]
            != sorted(expected_components)
        ):
            raise ValueError("removal receipt component identities are ambiguous")
        for item in components:
            if (
                not isinstance(item, dict)
                or set(item) != {
                    "component", "instance_id", "action", "state", "product_receipt_digest",
                }
                or item["component"] not in {"forge-runtime", "engineering-platform-server"}
                or item["instance_id"] != (
                    request.forge_instance_id if item["component"] == "forge-runtime"
                    else request.engineering_platform_instance_id
                )
                or item["action"] != (
                    "NO_CHANGE" if request.action == "REMOVE_COMPONENT"
                    and item["component"] == "engineering-platform-server"
                    else "REMOVE_COMPONENT"
                )
                or item["state"] not in {
                    "COMPLETE", "RECOVERY_PENDING", "PENDING", "FAILED", "UNCHANGED",
                }
                or item["action"] == "NO_CHANGE" and (
                    item["state"] != "UNCHANGED" or item["product_receipt_digest"] is not None
                )
                or item["action"] == "REMOVE_COMPONENT" and (
                    item["state"] == "UNCHANGED"
                    or payload["state"] == "COMPLETE" and (
                        item["state"] != "COMPLETE"
                        or item["product_receipt_digest"] is None
                    )
                )
                or item["product_receipt_digest"] is not None and (
                    not isinstance(item["product_receipt_digest"], str)
                    or len(item["product_receipt_digest"]) != 71
                    or not item["product_receipt_digest"].startswith("sha256:")
                    or any(character not in "0123456789abcdef" for character in item["product_receipt_digest"][7:])
                )
            ):
                raise ValueError("removal receipt component changed")
    except (UnicodeError, json.JSONDecodeError, TypeError, ValueError) as error:
        raise InstallerProductWorkerUnavailable("product removal receipt was rejected") from error
    return response


def execute_removal_review_intent(
    canonical_intent: bytes,
    *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    """Return only a correlated read-only proposal from released helper state."""

    intent = decode_native_product_removal_review_intent(canonical_intent)
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("product removal review service is unavailable")
    response = service.prepare_removal_review(canonical_intent)
    try:
        decode_native_product_removal_review_proposal(response, intent=intent)
    except Exception as error:
        raise InstallerProductWorkerUnavailable(
            "product removal review proposal was rejected"
        ) from error
    return response


def execute_preserved_lifecycle_review_intent(
    canonical_intent: bytes,
    *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    """Emit only a correlated read-only proposal from released worker state."""
    intent = decode_native_preserved_lifecycle_review_intent(canonical_intent)
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("lifecycle review service is unavailable")
    response = service.prepare_preserved_lifecycle_review(canonical_intent)
    try:
        decode_native_preserved_lifecycle_review_proposal(response, intent=intent)
    except Exception as error:
        raise InstallerProductWorkerUnavailable(
            "product lifecycle review proposal was rejected"
        ) from error
    return response


def execute_preserved_lifecycle_request(
    canonical_request: bytes, *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    """Bind an executed lifecycle receipt to the exact reviewed native request."""
    request = decode_native_preserved_lifecycle_request(canonical_request)
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("lifecycle execution service is unavailable")
    response = service.execute_preserved_lifecycle(canonical_request)
    if (
        not isinstance(response, bytes) or not response
        or len(response) > MAXIMUM_NATIVE_PRESERVED_LIFECYCLE_RECEIPT_BYTES
    ):
        raise InstallerProductWorkerUnavailable("lifecycle execution receipt is unavailable")
    try:
        decode_native_preserved_lifecycle_receipt(response, request=request)
    except Exception as error:
        raise InstallerProductWorkerUnavailable(
            "lifecycle execution receipt was rejected"
        ) from error
    return response


def read_terminal_preserve_recovery_request(
    canonical_request: bytes, *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    """Read only helper-owned terminal recovery proof for one exact operation."""
    request = decode_native_preserve_recovery_request(canonical_request)
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("preserve recovery service is unavailable")
    response = service.read_terminal_preserve_recovery(canonical_request)
    if (
        not isinstance(response, bytes) or not response
        or len(response) > MAXIMUM_NATIVE_PRESERVE_RECOVERY_RECEIPT_BYTES
    ):
        raise InstallerProductWorkerUnavailable("preserve recovery receipt is unavailable")
    try:
        decode_native_preserve_recovery_receipt(response, request=request)
    except Exception as error:
        raise InstallerProductWorkerUnavailable(
            "preserve recovery receipt was rejected"
        ) from error
    return response


def read_terminal_purge_recovery_request(
    canonical_request: bytes, *,
    service_loader: ServiceLoader = load_released_product_service,
) -> bytes:
    """Read only terminal proof for the original exact confirmed PURGE."""
    request = decode_native_purge_recovery_request(canonical_request)
    service = service_loader()
    if not isinstance(service, ManagedProductOperationHelperService):
        raise InstallerProductWorkerUnavailable("purge recovery service is unavailable")
    response = service.read_terminal_purge_recovery(canonical_request)
    if (
        not isinstance(response, bytes) or not response
        or len(response) > MAXIMUM_NATIVE_PURGE_RECOVERY_RECEIPT_BYTES
    ):
        raise InstallerProductWorkerUnavailable("purge recovery receipt is unavailable")
    try:
        decode_native_purge_recovery_receipt(response, request=request)
    except Exception as error:
        raise InstallerProductWorkerUnavailable(
            "purge recovery receipt was rejected"
        ) from error
    return response


def run(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    service_loader: ServiceLoader = load_released_product_service,
) -> int:
    try:
        request = input_stream.read(MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES + 1)
        try:
            envelope = json.loads(request)
        except (UnicodeError, json.JSONDecodeError, TypeError, ValueError):
            envelope = None
        if isinstance(envelope, dict) and envelope.get("schema") == PRODUCT_WHEEL_WORKER_SCHEMA:
            response = execute_wheel_request(request)
        elif isinstance(envelope, dict) and envelope.get("schema") == NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_SCHEMA:
            response = execute_removal_review_intent(request, service_loader=service_loader)
        elif isinstance(envelope, dict) and envelope.get("schema") == NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_SCHEMA:
            response = execute_preserved_lifecycle_review_intent(
                request, service_loader=service_loader,
            )
        elif isinstance(envelope, dict) and envelope.get("schema") in {
            NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA,
            NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA,
        }:
            response = execute_preserved_lifecycle_request(
                request, service_loader=service_loader,
            )
        elif isinstance(envelope, dict) and envelope.get("schema") == NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA:
            response = read_terminal_preserve_recovery_request(
                request, service_loader=service_loader,
            )
        elif isinstance(envelope, dict) and envelope.get("schema") == NATIVE_PURGE_RECOVERY_REQUEST_SCHEMA:
            response = read_terminal_purge_recovery_request(
                request, service_loader=service_loader,
            )
        elif isinstance(envelope, dict) and envelope.get("schema") == NATIVE_PRODUCT_REMOVAL_REQUEST_SCHEMA:
            response = execute_removal_request(request, service_loader=service_loader)
        else:
            response = execute_product_request(request, service_loader=service_loader)
        output_stream.write(response)
        output_stream.flush()
        return 0
    except Exception:
        return 1


def main() -> None:
    raise SystemExit(run(sys.stdin.buffer, sys.stdout.buffer))


if __name__ == "__main__":
    main()
