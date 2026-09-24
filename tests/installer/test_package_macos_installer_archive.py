#!/usr/bin/env python3
"""Behavioural checks for the strict stored-ZIP macOS app archive producer."""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package_macos_installer_archive.py"
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
import package_macos_installer_archive as archive_producer  # noqa: E402
from forge_platform.macos_platform_contract import thin_arm64_macho_test_bytes  # noqa: E402


class PackageMacOSInstallerArchiveTests(unittest.TestCase):
    def test_produces_a_deterministic_stored_profile_from_paths_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "workspace with spaces"
            workspace.mkdir()
            app_bundle = self._app_bundle(workspace, name="Forge Platform Installer.app")
            before = self._snapshot(app_bundle)
            first = workspace / "first archive" / "Forge Platform Installer.zip"
            second = workspace / "second archive" / "Forge Platform Installer.zip"
            first.parent.mkdir()
            second.parent.mkdir()

            first_result = self._run(app_bundle, first)
            second_result = self._run(app_bundle, second)

            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertIn("INSTALLER_APP_ARCHIVE=PASS", first_result.stdout)
            self.assertIn("profile=stored-zip-v1", first_result.stdout)
            self.assertEqual(self._snapshot(app_bundle), before)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o600)

            with zipfile.ZipFile(first) as archive:
                self.assertEqual(archive.comment, b"")
                entries = archive.infolist()
                names = {entry.filename for entry in entries}
                self.assertTrue(
                    {
                        "Forge Platform Installer.app/",
                        "Forge Platform Installer.app/Contents/",
                        "Forge Platform Installer.app/Contents/MacOS/",
                        "Forge Platform Installer.app/Contents/Resources/",
                        "Forge Platform Installer.app/Contents/Info.plist",
                        "Forge Platform Installer.app/Contents/MacOS/ForgePlatformInstaller",
                        "Forge Platform Installer.app/Contents/MacOS/forge-platform-installer",
                        "Forge Platform Installer.app/Contents/Resources/Read Me.txt",
                    }.issubset(names)
                )
                for entry in entries:
                    self.assertEqual(entry.compress_type, zipfile.ZIP_STORED)
                    self.assertEqual(entry.extra, b"")
                    self.assertEqual(entry.comment, b"")
                    self.assertEqual(entry.flag_bits, 0)
                    self.assertEqual(entry.create_system, 3)
                    self.assertLess(entry.extract_version, 45)
                    unix_mode = entry.external_attr >> 16
                    self.assertEqual(unix_mode & 0o022, 0)
                    expected_type = stat.S_IFDIR if entry.is_dir() else stat.S_IFREG
                    self.assertEqual(stat.S_IFMT(unix_mode), expected_type)
            # The fixture has controlled bytes, so either Zip64 signature
            # would be an archive-format feature rather than payload data.
            self.assertNotIn(b"PK\x06\x06", first.read_bytes())
            self.assertNotIn(b"PK\x06\x07", first.read_bytes())

    def test_rejects_a_selected_or_descendant_symlink_without_writing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            selected_link = workspace / "Selected Installer.app"
            selected_link.symlink_to(app_bundle, target_is_directory=True)
            output = workspace / "selected.zip"

            selected = self._run(selected_link, output)

            self.assertNotEqual(selected.returncode, 0)
            self.assertIn("must not be selected through a symlink", selected.stderr)
            self.assertFalse(output.exists())

            binary = app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller"
            binary.unlink()
            binary.symlink_to(app_bundle / "Contents" / "Info.plist")
            descendant_output = workspace / "descendant.zip"

            descendant = self._run(app_bundle, descendant_output)

            self.assertNotEqual(descendant.returncode, 0)
            self.assertIn("must not contain symlinks", descendant.stderr)
            self.assertFalse(descendant_output.exists())

    def test_rejects_group_or_world_writable_input_without_mutating_the_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            binary = app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller"
            binary.chmod(0o775)
            before = self._snapshot(app_bundle)
            output = workspace / "installer.zip"

            result = self._run(app_bundle, output)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("group- or world-writable", result.stderr)
            self.assertFalse(output.exists())
            self.assertEqual(self._snapshot(app_bundle), before)

    def test_rejects_metadata_sidecars_and_never_serializes_source_extended_attributes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            sidecar = app_bundle / "Contents" / "Resources" / "._FinderInfo"
            sidecar.write_bytes(b"appledouble sidecar")
            sidecar.chmod(0o644)
            sidecar_result = self._run(app_bundle, workspace / "sidecar.zip")

            self.assertNotEqual(sidecar_result.returncode, 0)
            self.assertIn("metadata sidecar", sidecar_result.stderr)
            self.assertFalse((workspace / "sidecar.zip").exists())

            # macOS can attach provenance xattrs to normal newly-created
            # files. They are source filesystem metadata, not ZIP payload.
            # The strict producer must never emit them as ZIP extra fields.
            xattr_bundle = self._app_bundle(workspace, name="Xattr Installer.app")
            xattr_archive = workspace / "xattr.zip"
            xattr_result = self._run(xattr_bundle, xattr_archive)
            self.assertEqual(xattr_result.returncode, 0, xattr_result.stderr)
            with zipfile.ZipFile(xattr_archive) as archive:
                self.assertTrue(all(entry.extra == b"" for entry in archive.infolist()))

    def test_refuses_to_overwrite_or_write_inside_the_app_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            existing = workspace / "existing.zip"
            existing.write_bytes(b"keep this existing archive")

            overwrite = self._run(app_bundle, existing)

            self.assertNotEqual(overwrite.returncode, 0)
            self.assertIn("must not already exist", overwrite.stderr)
            self.assertEqual(existing.read_bytes(), b"keep this existing archive")

            inside = app_bundle / "Contents" / "installer.zip"
            nested = self._run(app_bundle, inside)
            self.assertNotEqual(nested.returncode, 0)
            self.assertIn("must not be inside the app bundle", nested.stderr)
            self.assertFalse(inside.exists())

    def test_rejects_a_bundle_beyond_the_bounded_archive_profile_without_mutating_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            payload = app_bundle / "Contents" / "Resources" / "Large Payload.bin"
            payload.write_bytes(b"x" * 512)
            payload.chmod(0o644)
            before = self._snapshot(app_bundle)
            output = workspace / "bounded.zip"
            original_limit = archive_producer.MAXIMUM_ARCHIVE_BYTES
            archive_producer.MAXIMUM_ARCHIVE_BYTES = 256
            try:
                with self.assertRaisesRegex(ValueError, "strict archive size limit"):
                    archive_producer.package_archive(app_bundle=app_bundle, output=output)
            finally:
                archive_producer.MAXIMUM_ARCHIVE_BYTES = original_limit
            self.assertFalse(output.exists())
            self.assertEqual(self._snapshot(app_bundle), before)

    def test_removes_the_new_output_when_stream_construction_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            before = self._snapshot(app_bundle)
            output = workspace / "stream-construction.zip"

            with mock.patch.object(
                archive_producer.os,
                "fdopen",
                side_effect=OSError("simulated stream construction failure"),
            ):
                with self.assertRaisesRegex(OSError, "simulated stream construction failure"):
                    archive_producer.package_archive(app_bundle=app_bundle, output=output)

            self.assertFalse(output.exists())
            self.assertEqual(self._snapshot(app_bundle), before)

    def test_rejects_a_non_arm64_or_universal_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            binary = app_bundle / "Contents" / "MacOS" / "ForgePlatformInstaller"
            for name, header in (
                ("x86_64", bytes.fromhex("cffaedfe070000010300000002000000") + bytes(16)),
                ("universal", bytes.fromhex("cafebabe00000002") + bytes(24)),
            ):
                binary.write_bytes(header)
                binary.chmod(0o755)
                output = workspace / f"{name}.zip"

                result = self._run(app_bundle, output)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("thin arm64 Mach-O executable", result.stderr)
                self.assertFalse(output.exists())

    def test_refuses_to_remove_a_replacement_output_after_a_write_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            app_bundle = self._app_bundle(workspace)
            before = self._snapshot(app_bundle)
            output = workspace / "replacement.zip"
            replacement = b"not owned by the archive producer"

            def replace_then_fail(_entries: object) -> None:
                output.unlink()
                output.write_bytes(replacement)
                output.chmod(0o600)
                raise ValueError("simulated archive write failure")

            with mock.patch.object(
                archive_producer,
                "_verify_directories_unchanged",
                side_effect=replace_then_fail,
            ):
                with self.assertRaisesRegex(ValueError, "output changed before safe cleanup"):
                    archive_producer.package_archive(app_bundle=app_bundle, output=output)

            self.assertEqual(output.read_bytes(), replacement)
            self.assertEqual(self._snapshot(app_bundle), before)

    @staticmethod
    def _app_bundle(workspace: Path, *, name: str = "ForgePlatformInstaller.app") -> Path:
        app_bundle = workspace / name
        macos = app_bundle / "Contents" / "MacOS"
        resources = app_bundle / "Contents" / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        for directory in (app_bundle, app_bundle / "Contents", macos, resources):
            directory.chmod(0o755)
        (app_bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "ForgePlatformInstaller",
            "LSMinimumSystemVersion": "26.0",
        }))
        (app_bundle / "Contents" / "Info.plist").chmod(0o644)
        binary = macos / "ForgePlatformInstaller"
        binary.write_bytes(thin_arm64_macho_test_bytes(b"native installer candidate bytes\n"))
        binary.chmod(0o755)
        cli_binary = macos / "forge-platform-installer"
        cli_binary.write_bytes(thin_arm64_macho_test_bytes(b"native installer cli candidate bytes\n"))
        cli_binary.chmod(0o755)
        readme = resources / "Read Me.txt"
        readme.write_bytes(b"strict archive input\n")
        readme.chmod(0o644)
        return app_bundle

    @staticmethod
    def _snapshot(app_bundle: Path) -> dict[str, tuple[int, bytes | None]]:
        snapshot: dict[str, tuple[int, bytes | None]] = {}
        for path in sorted(app_bundle.rglob("*")):
            details = path.lstat()
            relative = path.relative_to(app_bundle).as_posix()
            snapshot[relative] = (
                details.st_mode,
                path.read_bytes() if stat.S_ISREG(details.st_mode) else None,
            )
        return snapshot

    @staticmethod
    def _run(app_bundle: Path, output: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--app-bundle",
                str(app_bundle),
                "--output",
                str(output),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


if __name__ == "__main__":
    unittest.main()
