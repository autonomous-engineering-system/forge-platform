"""Fresh published-slot wheel readback and fail-closed drift tests."""

from __future__ import annotations

from hashlib import sha256
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest import TestCase
from uuid import uuid4

from forge_platform.managed_product_wheel_materialization import materialize_product_wheel
from forge_platform.managed_product_wheel_readback import (
    ManagedProductWheelReadbackError, read_published_product_wheel,
)
from tests.installer.test_managed_product_wheel_inspection import wheel_bytes


class ManagedProductWheelReadbackTests(TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "managed-python-product-venvs"
        self.root.mkdir(mode=0o700)
        self.owner = os.geteuid()
        self.pending_name = "pending-" + str(uuid4())
        self.slot_name = "venv-" + "a" * 64
        self.pending = self.root / self.pending_name
        self.pending.mkdir(mode=0o700)
        subprocess.run(
            [sys.executable, "-m", "venv", "--copies", "--without-pip",
             str(self.pending)], check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.interpreter_digest = "sha256:" + sha256(
            (self.pending / "bin/python3").read_bytes()
        ).hexdigest()

    def _install(
        self, component: str = "forge-runtime", version: str = "2.7.38",
    ) -> bytes:
        extra = (
            {"forge/__main__.py": b"def main():\n    return 0\n"}
            if component == "forge-runtime" else
            {"engineering_platform/system_instance_provisioner.py":
             b"def main():\n    return 0\n"}
        )
        data = wheel_bytes(component, version, extra=extra)
        materialize_product_wheel(
            data, component_identity=component, version=version,
            artifact_sha256="sha256:" + sha256(data).hexdigest(),
            pending_name=self.pending_name,
            published_slot_name=self.slot_name,
            interpreter_sha256=self.interpreter_digest,
            venv_root=self.root, expected_owner=self.owner,
        )
        self.pending.rename(self.root / self.slot_name)
        return data

    def _read(self, data: bytes, *, component: str = "forge-runtime",
              version: str = "2.7.38", interpreter_digest: str | None = None):
        return read_published_product_wheel(
            data, component_identity=component, version=version,
            artifact_sha256="sha256:" + sha256(data).hexdigest(),
            published_slot_name=self.slot_name,
            interpreter_sha256=interpreter_digest or self.interpreter_digest,
            venv_root=self.root, expected_owner=self.owner,
        )

    def test_exact_forge_and_ep_published_slots_read_back_independently(self) -> None:
        for component, version in [
            ("forge-runtime", "2.7.38"),
            ("engineering-platform-server", "2.3.104"),
        ]:
            with self.subTest(component=component):
                if (self.root / self.slot_name).exists():
                    self.slot_name = "venv-" + "b" * 64
                    self.pending_name = "pending-" + str(uuid4())
                    self.pending = self.root / self.pending_name
                    self.pending.mkdir(mode=0o700)
                    subprocess.run(
                        [sys.executable, "-m", "venv", "--copies", "--without-pip",
                         str(self.pending)], check=True,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    )
                data = self._install(component, version)
                first = self._read(data, component=component, version=version)
                second = self._read(data, component=component, version=version)
                self.assertEqual(first, second)
                self.assertEqual(first.artifact_sha256,
                                 "sha256:" + sha256(data).hexdigest())
                self.assertEqual(first.file_count, 7 if component == "forge-runtime" else 14)
                self.assertEqual(len(first.evidence_reference), 71)

    def test_package_metadata_script_and_extra_member_drift_fail_closed(self) -> None:
        data = self._install()
        site = self.root / self.slot_name / "lib" / (
            f"python{sys.version_info.major}.{sys.version_info.minor}/site-packages"
        )
        package = site / "forge/__init__.py"
        original = package.read_bytes()
        package.write_bytes(b"tampered")
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)
        package.write_bytes(original)
        script = self.root / self.slot_name / "bin/forge"
        script.write_bytes(b"changed")
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)
        script.write_bytes(b"restored")
        (site / "forge/foreign.py").write_bytes(b"x")
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)

    def test_drifted_file_mode_fails_even_when_bytes_match(self) -> None:
        data = self._install()
        script = self.root / self.slot_name / "bin/forge"
        script.chmod(0o644)
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)

    def test_wrong_runtime_missing_slot_and_symlink_fail_closed(self) -> None:
        data = self._install()
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data, interpreter_digest="sha256:" + "0" * 64)
        self.slot_name = "venv-" + "c" * 64
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)
        (self.root / self.slot_name).symlink_to(self.root / ("venv-" + "a" * 64))
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)

    def test_other_slot_is_untouched_when_selected_slot_drifts(self) -> None:
        data = self._install()
        selected = self.root / self.slot_name
        other = self.root / ("venv-" + "b" * 64)
        other.mkdir(mode=0o700)
        sentinel = other / "untouched"
        sentinel.write_bytes(b"other deployment")
        (selected / "bin/forge").unlink()
        with self.assertRaises(ManagedProductWheelReadbackError):
            self._read(data)
        self.assertEqual(sentinel.read_bytes(), b"other deployment")
