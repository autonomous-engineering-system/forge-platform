#!/usr/bin/env python3
"""Behavioural coverage for the independent installer version authority."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "installer_versioning", ROOT / "scripts/advance_installer_version.py"
)
assert SPEC and SPEC.loader
installer_versioning = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer_versioning)

VALIDATION_SPEC = importlib.util.spec_from_file_location(
    "installer_version_validation", ROOT / "scripts/validate_installer_version.py"
)
assert VALIDATION_SPEC and VALIDATION_SPEC.loader
installer_version_validation = importlib.util.module_from_spec(VALIDATION_SPEC)
VALIDATION_SPEC.loader.exec_module(installer_version_validation)


class InstallerVersionPreparationTests(unittest.TestCase):
    def repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path, str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        (root / "installer-version.json").write_text(
            json.dumps(
                {
                    "schema": "forge-platform.installer-version/v1",
                    "product": "forge-platform-installer",
                    "version": "0.1.0",
                    "channel": "stable",
                    "capabilities": ["composition/v1", "provider-gate/v1"],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self._write_package_projection_helper(root)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            [
                "git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x",
                "commit", "-qm", "base",
            ],
            check=True,
        )
        return temporary, root, installer_versioning._head(root)

    @staticmethod
    def _write_package_projection_helper(root: Path, *, version_override: str | None = None) -> None:
        """Create a hermetic package helper for operation-journal tests.

        The real package-time mapping is exercised separately below. These
        temporary Git repositories only need a deliberately small CLI that
        fulfils the validator/packager boundary, so the durable-operation tests
        never depend on an unrelated checkout or global import path.
        """

        scripts = root / "scripts"
        scripts.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "scripts" / "validate_installer_version.py", scripts / "validate_installer_version.py")
        assigned_version = repr(version_override)
        (scripts / "package_macos_installer_app.py").write_text(
            "import argparse\n"
            "import json\n"
            "from pathlib import Path\n"
            "import plistlib\n"
            "parser = argparse.ArgumentParser()\n"
            "parser.add_argument('--executable', required=True)\n"
            "parser.add_argument('--cli-executable', required=True)\n"
            "parser.add_argument('--output', required=True)\n"
            "parser.add_argument('--bundle-identifier', required=True)\n"
            "args = parser.parse_args()\n"
            "root = Path(__file__).resolve().parents[1]\n"
            "version = json.loads((root / 'installer-version.json').read_text(encoding='utf-8'))['version']\n"
            f"override = {assigned_version}\n"
            "if override is not None:\n"
            "    version = override\n"
            "output = Path(args.output)\n"
            "contents = output / 'Contents'\n"
            "(contents / 'MacOS').mkdir(parents=True)\n"
            "(contents / 'MacOS' / 'ForgePlatformInstaller').write_bytes(Path(args.executable).read_bytes())\n"
            "(contents / 'MacOS' / 'forge-platform-installer').write_bytes(Path(args.cli_executable).read_bytes())\n"
            "with (contents / 'Info.plist').open('wb') as stream:\n"
            "    plistlib.dump({\n"
            "        'CFBundleExecutable': 'ForgePlatformInstaller',\n"
            "        'CFBundleIdentifier': args.bundle_identifier,\n"
            "        'CFBundleShortVersionString': version,\n"
            "        'CFBundleVersion': version,\n"
            "    }, stream)\n",
            encoding="utf-8",
        )

    @staticmethod
    def commit(root: Path, subject: str) -> str:
        subprocess.run(["git", "-C", str(root), "add", "."], check=True)
        subprocess.run(
            [
                "git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@x",
                "commit", "-qm", subject,
            ],
            check=True,
        )
        return installer_versioning._head(root)

    def test_plan_is_read_only_and_retry_completes_a_crash_after_manifest_projection(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            operation_id = "installer-version-0001"
            planned = installer_versioning.plan(root, operation_id, "increment:self-update", head, "patch", None)
            self.assertEqual(planned["target_version"], "0.1.1")
            self.assertFalse((root / installer_versioning.OPERATIONS_DIRECTORY).exists())

            original_projection = installer_versioning._runtime_projection

            def interrupted_projection(source_root: Path, version: str) -> dict[str, str]:
                if version == "0.1.1":
                    raise RuntimeError("simulated interruption after manifest write")
                return original_projection(source_root, version)

            with patch.object(installer_versioning, "_runtime_projection", side_effect=interrupted_projection):
                with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                    installer_versioning.apply(root, operation_id, "increment:self-update", head, "patch", None)
            self.assertEqual(json.loads((root / "installer-version.json").read_text())["version"], "0.1.1")
            receipt = json.loads(
                (root / installer_versioning.OPERATIONS_DIRECTORY / f"{operation_id}.json").read_text()
            )
            self.assertEqual(receipt["state"], "PREPARED")

            recovered = installer_versioning.apply(root, operation_id, "increment:self-update", head, "patch", None)
            self.assertEqual(recovered["target_version"], "0.1.1")
            self.assertEqual(recovered["state"], "APPLIED")
            self.assertEqual(
                installer_versioning.plan(root, operation_id, "increment:self-update", head, "patch", None)["target_version"],
                "0.1.1",
            )

    def test_receipt_binds_the_packager_and_its_info_plist_runtime_projection(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            operation = installer_versioning.apply(
                root,
                "installer-version-0011",
                "increment:package-time-projection",
                head,
                "patch",
                None,
            )
            self.assertEqual(operation["schema"], "forge-platform.installer-version-operation/v2")
            self.assertEqual(operation["allowed_projection_paths"], ["installer-version.json"])
            self.assertEqual(
                operation["runtime_projection_schema"],
                "forge-platform-installer-info-plist-version-projection/v1",
            )
            self.assertEqual(operation["runtime_info_plist_path"], "Contents/Info.plist")
            self.assertEqual(operation["packager_sha256_before"], operation["packager_sha256_after"])
            self.assertNotEqual(
                operation["runtime_projection_sha256_before"],
                operation["runtime_projection_sha256_after"],
            )
            self.assertNotIn("Swift", json.dumps(operation, sort_keys=True))
            self.assertFalse((root / "scripts" / "__pycache__").exists())

    def test_recovery_rejects_a_packager_change_after_preparation(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            operation_id = "installer-version-0012"
            original_projection = installer_versioning._runtime_projection

            def interrupted_projection(source_root: Path, version: str) -> dict[str, str]:
                if version == "0.1.1":
                    raise RuntimeError("simulated interruption after manifest write")
                return original_projection(source_root, version)

            with patch.object(installer_versioning, "_runtime_projection", side_effect=interrupted_projection):
                with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                    installer_versioning.apply(root, operation_id, "increment:package-drift", head, "patch", None)
            packager = root / installer_versioning.PACKAGER_PATH
            packager.write_text(packager.read_text(encoding="utf-8") + "\n# changed after preparation\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "app packager changed after preparation"):
                installer_versioning.apply(root, operation_id, "increment:package-drift", head, "patch", None)

    def test_stale_or_conflicting_preparation_fails_closed(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            with self.assertRaisesRegex(RuntimeError, "stale source head"):
                installer_versioning.apply(root, "installer-version-0002", "increment:self-update", "0" * 40, "patch", None)
            installer_versioning.apply(root, "installer-version-0002", "increment:self-update", head, "patch", None)
            with self.assertRaisesRegex(RuntimeError, "operation ID conflict"):
                installer_versioning.apply(root, "installer-version-0002", "increment:self-update", head, "minor", None)

    def test_qualification_binds_exact_changed_projection_set(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            installer_versioning.apply(root, "installer-version-0003", "increment:self-update", head, "patch", None)
            candidate = self.commit(root, "prepare installer version")
            installer_versioning.verify_operation(root, candidate)

            (root / "unrelated.txt").write_text("outside version preparation\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "requires a version-preparation receipt"):
                installer_versioning.verify_operation(
                    root, self.commit(root, "unrelated"), require_operation=True
                )

    def test_historical_receipts_do_not_block_the_next_exact_candidate_receipt(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            installer_versioning.apply(root, "installer-version-0005", "increment:first", head, "patch", None)
            first_candidate = self.commit(root, "prepare first installer version")
            installer_versioning.verify_operation(root, first_candidate, require_operation=True)

            installer_versioning.apply(
                root,
                "installer-version-0006",
                "increment:second",
                first_candidate,
                "patch",
                None,
            )
            second_candidate = self.commit(root, "prepare second installer version")
            installer_versioning.verify_operation(root, second_candidate, require_operation=True)

    def test_no_bump_receipt_has_no_phantom_projection_changes(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            installer_versioning.apply(root, "installer-version-0004", "increment:documentation", head, "none", None)
            candidate = self.commit(root, "record no-bump installer decision")
            installer_versioning.verify_operation(root, candidate)
            with self.assertRaisesRegex(RuntimeError, "advancing version-preparation receipt"):
                installer_versioning.verify_operation(
                    root,
                    candidate,
                    require_version_advance=True,
                )

    def test_qualification_rejects_dirty_worktree_instead_of_certifying_uncommitted_bytes(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            installer_versioning.apply(root, "installer-version-0007", "increment:clean", head, "patch", None)
            candidate = self.commit(root, "prepare clean installer version")
            (root / "installer-version.json").write_text(
                (root / "installer-version.json").read_text(encoding="utf-8").replace("0.1.1", "9.9.9"),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "requires a clean worktree"):
                installer_versioning.verify_operation(root, candidate, require_version_advance=True)

    def test_qualification_rejects_forged_baseline_or_release_classification(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            operation_id = "installer-version-0008"
            installer_versioning.apply(root, operation_id, "increment:forged", head, "patch", None)
            receipt_path = root / installer_versioning.OPERATIONS_DIRECTORY / f"{operation_id}.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["baseline_version"] = "0.0.1"
            receipt["requested_bump"] = None
            receipt["requested_exact_version"] = "0.1.1"
            receipt["release_class"] = "EXACT"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            candidate = self.commit(root, "forge installer version baseline")
            with self.assertRaisesRegex(RuntimeError, "baseline does not match"):
                installer_versioning.verify_operation(root, candidate, require_version_advance=True)

        temporary, root, head = self.repo()
        with temporary:
            operation_id = "installer-version-0009"
            installer_versioning.apply(root, operation_id, "increment:classification", head, "patch", None)
            receipt_path = root / installer_versioning.OPERATIONS_DIRECTORY / f"{operation_id}.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["release_class"] = "NO_BUMP"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            candidate = self.commit(root, "forge installer release class")
            with self.assertRaisesRegex(RuntimeError, "invalid identity or requested release semantics"):
                installer_versioning.verify_operation(root, candidate, require_version_advance=True)

    def test_preparation_lock_serializes_two_processes_and_releases_after_holder_exit(self) -> None:
        temporary, root, head = self.repo()
        with temporary:
            child_source = (
                "import importlib.util\n"
                "from pathlib import Path\n"
                "import sys\n"
                f"spec = importlib.util.spec_from_file_location('versioning', {str(ROOT / 'scripts' / 'advance_installer_version.py')!r})\n"
                "module = importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(module)\n"
                "with module._preparation_lock(Path(sys.argv[1])):\n"
                "    print('LOCKED', flush=True)\n"
                "    sys.stdin.read()\n"
            )
            holder = subprocess.Popen(
                ["python3", "-c", child_source, str(root)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                assert holder.stdout is not None
                self.assertEqual(holder.stdout.readline().strip(), "LOCKED")
                with self.assertRaisesRegex(RuntimeError, "another installer version preparation owns the lock"):
                    installer_versioning.apply(
                        root,
                        "installer-version-0010",
                        "increment:contender",
                        head,
                        "patch",
                        None,
                    )
            finally:
                assert holder.stdin is not None
                holder.stdin.close()
                return_code = holder.wait(timeout=10)
                stderr = holder.stderr.read() if holder.stderr else ""
                if holder.stdout is not None:
                    holder.stdout.close()
                if holder.stderr is not None:
                    holder.stderr.close()
                self.assertEqual(return_code, 0, stderr)

            applied = installer_versioning.apply(
                root,
                "installer-version-0010",
                "increment:contender",
                head,
                "patch",
                None,
            )
            self.assertEqual(applied["state"], "APPLIED")


class InstallerVersionProjectionValidationTests(unittest.TestCase):
    def test_real_packager_projects_the_sole_manifest_version_into_info_plist(self) -> None:
        manifest = installer_version_validation.load_manifest(ROOT)
        projection = installer_version_validation.validate(ROOT, expected_version=manifest["version"])
        self.assertEqual(projection["short_version"], manifest["version"])
        self.assertEqual(projection["build_version"], manifest["version"])
        self.assertEqual(projection["info_plist_path"], "Contents/Info.plist")
        self.assertRegex(projection["sha256"], r"^[0-9a-f]{64}$")

    def test_validation_rejects_a_packager_that_writes_a_different_runtime_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "installer-version.json").write_text(
                json.dumps(
                    {
                        "schema": "forge-platform.installer-version/v1",
                        "product": "forge-platform-installer",
                        "version": "2.4.6",
                        "channel": "stable",
                        "capabilities": ["composition/v1"],
                    }
                ),
                encoding="utf-8",
            )
            InstallerVersionPreparationTests._write_package_projection_helper(
                root,
                version_override="9.9.9",
            )
            with self.assertRaisesRegex(RuntimeError, "does not project installer-version.json"):
                installer_version_validation.validate(root, expected_version="2.4.6")

    def test_validation_rejects_a_manifest_that_differs_from_a_durable_expected_target(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "does not match the expected version"):
            installer_version_validation.validate(ROOT, expected_version="9.9.9")


if __name__ == "__main__":
    unittest.main()
