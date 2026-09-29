"""Pending-only exact product wheel placement and negative safety cases."""

from __future__ import annotations

from hashlib import sha256
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import TestCase
from unittest.mock import patch
from uuid import uuid4

from forge_platform.managed_product_wheel_inspection import (
    ManagedProductWheelInspectionError,
)
from forge_platform.managed_product_wheel_materialization import (
    ManagedProductWheelMaterializationError,
    materialize_product_wheel,
)
from tests.installer.test_managed_product_wheel_inspection import wheel_bytes


class ManagedProductWheelMaterializationTests(TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "managed-python-product-venvs"
        self.root.mkdir(mode=0o700)
        self.owner = os.geteuid()
        self.slot = "venv-" + "a" * 64
        self.pending_name = "pending-" + str(uuid4())
        self.pending = self.root / self.pending_name
        self._make_venv(self.pending)

    def _make_venv(self, path: Path) -> None:
        path.mkdir(mode=0o700)
        subprocess.run(
            [sys.executable, "-m", "venv", "--copies", "--without-pip", str(path)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def _install(
        self, data: bytes, *, component: str = "forge-runtime",
        version: str = "2.7.38", pending_name: str | None = None,
        slot: str | None = None, digest: str | None = None,
        interpreter_digest: str | None = None,
    ):
        selected_pending = pending_name or self.pending_name
        return materialize_product_wheel(
            data, component_identity=component, version=version,
            artifact_sha256=digest or "sha256:" + sha256(data).hexdigest(),
            pending_name=selected_pending,
            published_slot_name=slot or self.slot,
            interpreter_sha256=interpreter_digest or "sha256:" + sha256(
                (self.root / selected_pending / "bin/python3").read_bytes()
            ).hexdigest(),
            venv_root=self.root, expected_owner=self.owner,
        )

    def test_forge_wheel_materializes_into_only_pending_venv(self) -> None:
        data = wheel_bytes(extra={
            "forge/__main__.py": b"def main():\n    print('forge-fixture-ok')\n    return 0\n",
        })
        receipt = self._install(data)
        self.assertEqual(receipt.component_identity, "forge-runtime")
        self.assertEqual(receipt.version, "2.7.38")
        self.assertEqual(receipt.artifact_sha256, "sha256:" + sha256(data).hexdigest())
        self.assertEqual(receipt.file_count, 7)
        self.assertEqual(len(receipt.evidence_reference), 71)
        self.assertFalse((self.root / self.slot).exists())
        site = self.pending / "lib" / f"python{receipt.python_minor}" / "site-packages"
        self.assertEqual((site / "forge/__main__.py").read_bytes(),
                         b"def main():\n    print('forge-fixture-ok')\n    return 0\n")
        self.assertIn(str(self.root / self.slot / "bin/python3"),
                      (self.pending / "bin/forge").read_text())
        self.pending.rename(self.root / self.slot)
        process = subprocess.run(
            [str(self.root / self.slot / "bin/forge")],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(process.stdout.strip(), "forge-fixture-ok")

    def test_ep_wheel_materializes_all_product_owned_entrypoints(self) -> None:
        data = wheel_bytes(
            "engineering-platform-server", "2.3.104",
            extra={"engineering_platform/system_instance_provisioner.py":
                   b"def main():\n    print('ep-fixture-ok')\n    return 0\n"},
        )
        receipt = self._install(
            data, component="engineering-platform-server", version="2.3.104",
        )
        self.assertEqual(receipt.file_count, 14)
        self.assertTrue((self.pending / "bin/engineering-platform-system-provisioner").exists())
        self.pending.rename(self.root / self.slot)
        process = subprocess.run(
            [str(self.root / self.slot / "bin/engineering-platform-system-provisioner")],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(process.stdout.strip(), "ep-fixture-ok")

    def test_wrong_archive_or_target_authority_fails_before_mutation(self) -> None:
        data = wheel_bytes()
        with self.assertRaises(ManagedProductWheelInspectionError):
            self._install(data, digest="sha256:" + "0" * 64)
        with self.assertRaises(ManagedProductWheelMaterializationError):
            self._install(data, interpreter_digest="sha256:" + "0" * 64)
        for pending_name, slot in [
            ("../outside", self.slot),
            (self.pending_name, "venv-wrong"),
        ]:
            with self.assertRaises(ManagedProductWheelMaterializationError):
                self._install(data, pending_name=pending_name, slot=slot,
                              interpreter_digest="sha256:" + "1" * 64)
        self.assertFalse((self.pending / "bin/forge").exists())

    def test_published_slot_and_nonempty_site_packages_fail_closed(self) -> None:
        data = wheel_bytes()
        (self.root / self.slot).mkdir()
        with self.assertRaises(ManagedProductWheelMaterializationError):
            self._install(data)
        (self.root / self.slot).rmdir()
        site = self.pending / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages"
        (site / "foreign.py").write_bytes(b"x")
        with self.assertRaises(ManagedProductWheelMaterializationError):
            self._install(data)
        self.assertEqual((site / "foreign.py").read_bytes(), b"x")

    def test_partial_retry_stops_and_another_pending_slot_stays_untouched(self) -> None:
        data = wheel_bytes()
        second_name = "pending-" + str(uuid4())
        second = self.root / second_name
        self._make_venv(second)
        second_before = (second / "pyvenv.cfg").read_bytes()
        first = self._install(data)
        self.assertEqual(first.pending_name, self.pending_name)
        with self.assertRaises(ManagedProductWheelMaterializationError):
            self._install(data)
        self.assertEqual((second / "pyvenv.cfg").read_bytes(), second_before)
        self.assertFalse((second / "bin/forge").exists())
        self.assertFalse((self.root / self.slot).exists())
        second_slot = "venv-" + "b" * 64
        other = self._install(data, pending_name=second_name, slot=second_slot)
        self.assertEqual(other.published_slot_name, second_slot)
        self.assertFalse((self.root / second_slot).exists())

    def test_symlinked_pending_and_missing_interpreter_fail_closed(self) -> None:
        data = wheel_bytes()
        alias = "pending-" + str(uuid4())
        (self.root / alias).symlink_to(self.pending, target_is_directory=True)
        with self.assertRaises(ManagedProductWheelMaterializationError):
            self._install(data, pending_name=alias,
                          interpreter_digest="sha256:" + "1" * 64)
        (self.pending / "bin/python3").unlink()
        with self.assertRaises(ManagedProductWheelMaterializationError):
            self._install(data, interpreter_digest="sha256:" + "1" * 64)

    def test_interpreter_change_during_probe_fails_before_wheel_write(self) -> None:
        data = wheel_bytes()
        interpreter = self.pending / "bin/python3"
        digest = "sha256:" + sha256(interpreter.read_bytes()).hexdigest()

        def change_interpreter(_path: Path) -> str:
            interpreter.write_bytes(b"changed")
            return f"{sys.version_info.major}.{sys.version_info.minor}"

        with patch(
            "forge_platform.managed_product_wheel_materialization._python_minor",
            side_effect=change_interpreter,
        ):
            with self.assertRaises(ManagedProductWheelMaterializationError):
                self._install(data, interpreter_digest=digest)
        self.assertFalse((self.pending / "bin/forge").exists())
