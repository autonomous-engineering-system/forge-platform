"""Exact staged-wheel worker transport, positive paths and fail-closed cases."""

from __future__ import annotations

from hashlib import sha256
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import TestCase
from unittest.mock import patch
from uuid import uuid4

from forge_platform.installer_product_worker import run
from forge_platform.managed_product_wheel_worker import (
    ManagedProductWheelWorkerError, SCHEMA, execute_wheel_request,
)
from tests.installer.test_managed_product_wheel_inspection import wheel_bytes


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("ascii")


class ManagedProductWheelWorkerTests(TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.staged = root / "staged"
        self.staged.mkdir(mode=0o700)
        self.venvs = root / "managed-python-product-venvs"
        self.venvs.mkdir(mode=0o700)
        self.owner = os.geteuid()
        self.pending_name = "pending-" + str(uuid4())
        self.slot = "venv-" + "a" * 64
        pending = self.venvs / self.pending_name
        pending.mkdir(mode=0o700)
        subprocess.run(
            [sys.executable, "-m", "venv", "--copies", "--without-pip", str(pending)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.interpreter = "sha256:" + sha256((pending / "bin/python3").read_bytes()).hexdigest()
        self.wheel = wheel_bytes(extra={
            "forge/__main__.py": b"def main():\n    return 0\n",
        })
        self.digest = "sha256:" + sha256(self.wheel).hexdigest()
        self.staged_file = self.staged / (self.digest[7:] + ".artifact")
        self.staged_file.write_bytes(self.wheel)
        self.staged_file.chmod(0o600)

    def request(self, action: str = "INSTALL_PENDING", **changes: object) -> bytes:
        value = dict(
            schema=SCHEMA, action=action, component_identity="forge-runtime",
            version="2.7.38", artifact_sha256=self.digest,
            pending_name=self.pending_name if action == "INSTALL_PENDING" else None,
            published_slot_name=self.slot, interpreter_sha256=self.interpreter,
        )
        value.update(changes)
        return canonical(value)

    def execute(self, raw: bytes) -> dict[str, object]:
        return json.loads(execute_wheel_request(
            raw, staged_root=self.staged, venv_root=self.venvs,
            expected_owner=self.owner,
        ))

    def test_install_then_published_readback_binds_same_exact_wheel(self) -> None:
        installed = self.execute(self.request())
        self.assertEqual(installed["action"], "INSTALL_PENDING")
        self.assertEqual(installed["request_sha256"],
                         "sha256:" + sha256(self.request()).hexdigest())
        self.assertEqual(installed["file_count"], 7)
        self.assertFalse((self.venvs / self.slot).exists())
        (self.venvs / self.pending_name).rename(self.venvs / self.slot)
        published = self.execute(self.request("READ_PUBLISHED"))
        self.assertEqual(published["action"], "READ_PUBLISHED")
        self.assertEqual(published["binding_evidence"], installed["binding_evidence"])
        self.assertNotEqual(published["verification_evidence"],
                            installed["verification_evidence"])
        self.assertEqual(published, self.execute(self.request("READ_PUBLISHED")))

    def test_worker_dispatches_fixed_wheel_schema_without_loading_product_service(self) -> None:
        with patch("forge_platform.installer_product_worker.execute_wheel_request",
                   return_value=b'{"ok":true}') as wheel:
            output = io.BytesIO()
            self.assertEqual(run(io.BytesIO(self.request()), output,
                                 service_loader=lambda: self.fail("service loaded")), 0)
            self.assertEqual(output.getvalue(), b'{"ok":true}')
            wheel.assert_called_once_with(self.request())

    def test_noncanonical_and_foreign_requests_fail_before_staging(self) -> None:
        for raw in [
            self.request() + b"\n", b"{}", b"[]", b"\xff",
            self.request().replace(b'"action":"INSTALL_PENDING"',
                                   b'"action":"READ_PUBLISHED"'),
            self.request().replace(b'"version":"2.7.38"',
                                   b'"version":"2.7.38","version":"2.7.38"'),
            self.request(component_identity="foreign"),
            self.request(component_identity=[]),
            self.request(pending_name="../foreign"),
            self.request(published_slot_name="venv-foreign"),
            self.request(interpreter_sha256="sha256:" + "f" * 64),
            self.request(artifact_sha256="sha256:" + "f" * 64),
            self.request(action="FOREIGN"),
        ]:
            with self.subTest(raw=raw[:70]), self.assertRaises((ValueError, OSError)):
                self.execute(raw)
        self.assertFalse((self.venvs / self.pending_name / "bin/forge").exists())

    def test_worker_dispatch_rejects_noncanonical_wheel_request_without_output(self) -> None:
        output = io.BytesIO()
        with patch("forge_platform.installer_product_worker.execute_wheel_request",
                   side_effect=ManagedProductWheelWorkerError("invalid")):
            self.assertEqual(run(io.BytesIO(self.request()), output,
                                 service_loader=lambda: self.fail("service loaded")), 1)
        self.assertEqual(output.getvalue(), b"")

    def test_staged_wheel_digest_mode_link_and_owner_are_checked(self) -> None:
        with patch("forge_platform.managed_product_wheel_worker.os.geteuid",
                   return_value=self.owner + 1):
            with self.assertRaises(ManagedProductWheelWorkerError):
                self.execute(self.request())
        self.staged_file.chmod(0o644)
        with self.assertRaises(ManagedProductWheelWorkerError):
            self.execute(self.request())
        self.staged_file.chmod(0o600)
        self.staged_file.write_bytes(b"changed")
        with self.assertRaises(ManagedProductWheelWorkerError):
            self.execute(self.request())
        self.staged_file.write_bytes(self.wheel)
        alias = self.staged / "alias"
        os.link(self.staged_file, alias)
        with self.assertRaises(ManagedProductWheelWorkerError):
            self.execute(self.request())
        alias.unlink()
        self.staged_file.unlink()
        self.staged_file.symlink_to(self.venvs / self.pending_name)
        with self.assertRaises(OSError):
            self.execute(self.request())

    def test_published_drift_and_other_slot_isolation(self) -> None:
        self.execute(self.request())
        (self.venvs / self.pending_name).rename(self.venvs / self.slot)
        other = self.venvs / ("venv-" + "b" * 64)
        other.mkdir(mode=0o700)
        sentinel = other / "sentinel"
        sentinel.write_bytes(b"foreign deployment")
        product = self.venvs / self.slot / "bin/forge"
        product.write_bytes(b"tamper")
        with self.assertRaises(ValueError):
            self.execute(self.request("READ_PUBLISHED"))
        self.assertEqual(sentinel.read_bytes(), b"foreign deployment")

    def test_missing_pending_or_oversize_request_fails_closed(self) -> None:
        with self.assertRaises(ManagedProductWheelWorkerError):
            self.execute(b"x" * 8193)
        with self.assertRaises(ValueError):
            self.execute(self.request(pending_name="pending-" + str(uuid4())))
        self.assertFalse((self.venvs / self.slot).exists())


if __name__ == "__main__":
    from unittest import main
    main()
