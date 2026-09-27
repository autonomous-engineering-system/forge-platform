#!/usr/bin/env python3
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
from hashlib import sha256
import io
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import build_installer_product_worker as builder  # noqa: E402


class BuildInstallerProductWorkerTests(unittest.TestCase):
    def test_build_is_byte_reproducible_and_contains_exact_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first" / "worker.pyz"
            second = root / "second" / "worker.pyz"

            first_digest = builder.build(first)
            second_digest = builder.build(second)

            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first_digest, second_digest)
            self.assertEqual(first_digest, "sha256:" + sha256(first.read_bytes()).hexdigest())
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o644)
            with zipfile.ZipFile(first, "r") as archive:
                entries = archive.infolist()
                names = [entry.filename for entry in entries]
                self.assertEqual(names, sorted(names))
                self.assertEqual(names[0], "__main__.py")
                self.assertIn("forge_platform/installer_product_worker.py", names)
                self.assertEqual(
                    set(names[1:]),
                    {
                        "forge_platform/" + path.name
                        for path in (ROOT / "forge_platform").glob("*.py")
                    },
                )
                self.assertTrue(all(entry.date_time == builder.FIXED_DATE_TIME for entry in entries))
                self.assertTrue(all(entry.compress_type == zipfile.ZIP_STORED for entry in entries))
                self.assertTrue(all(stat.S_IMODE(entry.external_attr >> 16) == 0o644 for entry in entries))

            result = subprocess.run(
                [sys.executable, "-I", "-S", str(first)],
                input=b"{}",
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")

    def test_rejects_output_reuse_suffix_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            existing = root / "existing.pyz"
            existing.write_bytes(b"preserve")
            with self.assertRaisesRegex(ValueError, "already exist"):
                builder.build(existing)
            self.assertEqual(existing.read_bytes(), b"preserve")
            with self.assertRaisesRegex(ValueError, "end in .pyz"):
                builder.output_path(str(root / "worker.zip"))
            linked = root / "linked.pyz"
            linked.symlink_to(existing)
            with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                builder.output_path(str(linked))

    def test_rejects_linked_missing_and_oversized_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "forge_platform"
            package.mkdir()
            (package / "installer_product_worker.py").write_bytes(b"pass\n")
            linked = package / "linked.py"
            linked.symlink_to(package / "installer_product_worker.py")
            with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                builder.collect_sources(package)
            linked.unlink()
            (package / "installer_product_worker.py").unlink()
            with self.assertRaisesRegex(ValueError, "entrypoint module is missing"):
                builder.collect_sources(package)
            oversized = package / "installer_product_worker.py"
            oversized.write_bytes(b"x" * (builder.MAXIMUM_SOURCE_BYTES + 1))
            with self.assertRaisesRegex(ValueError, "source is invalid"):
                builder.collect_sources(package)

    def test_cli_reports_digest_and_refuses_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "worker.pyz"
            stdout = io.StringIO()
            with patch.object(sys, "argv", ["builder", "--output", str(target)]), redirect_stdout(stdout):
                builder.main()
            self.assertIn("INSTALLER_PRODUCT_WORKER=PASS", stdout.getvalue())
            stderr = io.StringIO()
            with (
                patch.object(sys, "argv", ["builder", "--output", str(target)]),
                redirect_stderr(stderr),
                self.assertRaises(SystemExit) as stopped,
            ):
                builder.main()
            self.assertEqual(stopped.exception.code, 1)
            self.assertIn("INSTALLER_PRODUCT_WORKER=FAIL", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
