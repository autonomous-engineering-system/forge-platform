"""Bounded entrypoint for the privileged managed-installer product worker.

The zipapp receives exactly one canonical native request on stdin and emits at
most one canonical terminal receipt on stdout.  Construction of the released
helper service remains a separate helper-owned authority boundary.
"""

from __future__ import annotations

from typing import BinaryIO, Callable
import sys

from .managed_product_operation_admission import MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES
from .managed_product_operation_service import (
    MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES,
    ManagedProductOperationHelperService,
)


class InstallerProductWorkerUnavailable(RuntimeError):
    """The released helper authority has not been loaded safely."""


ServiceLoader = Callable[[], ManagedProductOperationHelperService]


def load_released_product_service() -> ManagedProductOperationHelperService:
    """Fail closed until the fixed helper-owned authority loader is supplied."""

    raise InstallerProductWorkerUnavailable(
        "released product-worker authority is unavailable"
    )


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


def run(
    input_stream: BinaryIO,
    output_stream: BinaryIO,
    *,
    service_loader: ServiceLoader = load_released_product_service,
) -> int:
    try:
        request = input_stream.read(MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES + 1)
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
