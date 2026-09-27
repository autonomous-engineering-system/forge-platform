#!/usr/bin/env python3
from __future__ import annotations

import io
import unittest

from forge_platform.installer_product_worker import (
    InstallerProductWorkerUnavailable,
    execute_product_request,
    execute_removal_request,
    load_released_product_service,
    run,
)
from forge_platform.managed_product_operation_service import NATIVE_PRODUCT_REMOVAL_RECEIPT_SCHEMA
import tests.installer.test_managed_product_removal_admission as removal_fixtures
from forge_platform.managed_product_operation_admission import (
    MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES,
)
from forge_platform.managed_product_operation_service import (
    MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES,
    ManagedProductOperationHelperService,
)


class _BrokenOutput(io.BytesIO):
    def write(self, data):
        raise OSError("closed")


def _service(
    response: bytes | Exception, *, removal_response: bytes | Exception | None = None,
) -> ManagedProductOperationHelperService:
    service = object.__new__(ManagedProductOperationHelperService)

    def execute(_request: bytes) -> bytes:
        if isinstance(response, Exception):
            raise response
        return response

    service.execute = execute
    def execute_removal(_request: bytes) -> bytes:
        result = removal_response if removal_response is not None else response
        if isinstance(result, Exception):
            raise result
        return result

    service.execute_removal = execute_removal
    return service


class InstallerProductWorkerTests(unittest.TestCase):
    def test_exact_removal_request_and_receipt_use_same_worker(self) -> None:
        fixture = removal_fixtures.ManagedProductRemovalAdmissionTests(
            "test_exact_paired_component_removal_retains_ep_and_other_deployment"
        )
        fixture.setUp()
        try:
            payload = fixture.payload()
            request = removal_fixtures.canonical(payload)
            receipt = {
                "schema": NATIVE_PRODUCT_REMOVAL_RECEIPT_SCHEMA,
                "request_fingerprint": payload["request_fingerprint"],
                "operation_id": "remove-a",
                "deployment_id": "deployment-a",
                "action": "REMOVE_COMPONENT",
                "plan_fingerprint": "sha256:" + payload["reviewed_plan_sha256"],
                "state": "RECOVERY_PENDING",
                "registry_revision": None,
                "components": [
                    {
                        "component": "engineering-platform-server",
                        "instance_id": "ep-a",
                        "action": "NO_CHANGE",
                        "state": "UNCHANGED",
                        "product_receipt_digest": None,
                    },
                    {
                        "component": "forge-runtime",
                        "instance_id": "forge-a",
                        "action": "REMOVE_COMPONENT",
                        "state": "RECOVERY_PENDING",
                        "product_receipt_digest": None,
                    },
                ],
            }
            response = removal_fixtures.canonical(receipt)
            service = lambda: _service(b"unreachable", removal_response=response)
            self.assertEqual(
                execute_removal_request(request, service_loader=service), response,
            )
            output = io.BytesIO()
            self.assertEqual(run(io.BytesIO(request), output, service_loader=service), 0)
            self.assertEqual(output.getvalue(), response)
            for changes in (
                {"request_fingerprint": "0" * 64},
                {"registry_revision": 2},
                {"components": [{**receipt["components"][0], "instance_id": "ep-other"}, receipt["components"][1]]},
                {"secret": "never"},
            ):
                changed = {**receipt, **changes}
                with self.subTest(changes=changes), self.assertRaises(InstallerProductWorkerUnavailable):
                    execute_removal_request(
                        request,
                        service_loader=lambda: _service(
                            b"unreachable", removal_response=removal_fixtures.canonical(changed)
                        ),
                    )
        finally:
            fixture.tearDown()

    def test_executes_one_bounded_request_through_exact_service(self) -> None:
        request = b'{"request":"canonical"}'
        response = b'{"receipt":"canonical"}'

        self.assertEqual(
            execute_product_request(request, service_loader=lambda: _service(response)),
            response,
        )
        output = io.BytesIO()
        self.assertEqual(
            run(io.BytesIO(request), output, service_loader=lambda: _service(response)),
            0,
        )
        self.assertEqual(output.getvalue(), response)

    def test_default_released_loader_is_explicitly_unavailable(self) -> None:
        with self.assertRaisesRegex(InstallerProductWorkerUnavailable, "authority"):
            load_released_product_service()
        output = io.BytesIO()
        self.assertEqual(run(io.BytesIO(b"{}"), output), 1)
        self.assertEqual(output.getvalue(), b"")

    def test_rejects_request_service_and_response_drift(self) -> None:
        requests = (
            b"",
            b"x" * (MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES + 1),
        )
        for request in requests:
            with self.subTest(size=len(request)), self.assertRaises(
                InstallerProductWorkerUnavailable
            ):
                execute_product_request(
                    request,
                    service_loader=lambda: _service(b"{}"),
                )
        with self.assertRaisesRegex(InstallerProductWorkerUnavailable, "service"):
            execute_product_request(b"{}", service_loader=lambda: object())
        for response in (
            b"",
            b"x" * (MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES + 1),
        ):
            with self.subTest(response_size=len(response)), self.assertRaisesRegex(
                InstallerProductWorkerUnavailable, "receipt"
            ):
                execute_product_request(
                    b"{}",
                    service_loader=lambda response=response: _service(response),
                )

    def test_run_maps_backend_and_pipe_failures_without_output(self) -> None:
        for output, loader in (
            (io.BytesIO(), lambda: _service(ValueError("private backend detail"))),
            (_BrokenOutput(), lambda: _service(b"{}")),
        ):
            with self.subTest(output=type(output).__name__):
                self.assertEqual(run(io.BytesIO(b"{}"), output, service_loader=loader), 1)
                self.assertEqual(output.getvalue(), b"")


if __name__ == "__main__":
    unittest.main()
