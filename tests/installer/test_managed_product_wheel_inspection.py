"""Positive and fail-closed tests for exact frozen product-wheel inspection."""

from __future__ import annotations

from base64 import urlsafe_b64encode
from hashlib import sha256
from io import BytesIO, StringIO
from unittest import TestCase
from unittest.mock import patch
import csv
import stat
import zipfile

from forge_platform.managed_product_wheel_inspection import (
    ManagedProductWheelInspectionError,
    inspect_product_wheel,
)


ENTRYPOINTS = {
    "forge-runtime": (
        "forge_autonomy", "forge-autonomy", "forge",
        {"forge": "forge.__main__:main"},
    ),
    "engineering-platform-server": (
        "engineering_platform", "engineering-platform", "engineering_platform",
        {
            "engineering-execution-host": "engineering_platform.__main__:main",
            "engineering-platform": "engineering_platform.submission_cli:main",
            "engineering-platform-host": "engineering_platform.__main__:main",
            "engineering-platform-maintenance":
                "engineering_platform.central_operational_reset:main",
            "engineering-platform-server": "engineering_platform.server:main",
            "engineering-platform-system-provisioner":
                "engineering_platform.system_instance_provisioner:main",
            "engineering-project-agent": "engineering_platform.project_agent:main",
            "engineering-reconciliation-adopt":
                "engineering_platform.reconciliation_adoption:main",
        },
    ),
}


def wheel_bytes(
    component: str = "forge-runtime", version: str = "2.7.38",
    *, extra: dict[str, bytes] | None = None,
    metadata_override: bytes | None = None,
    entrypoint_override: bytes | None = None,
    record_override: bytes | None = None,
    symlink: str | None = None,
) -> bytes:
    distribution, package_name, package_root, entrypoints = ENTRYPOINTS[component]
    info = f"{distribution}-{version}.dist-info"
    contents = {
        f"{package_root}/__init__.py": b"VERSION = 'qualified'\n",
        f"{info}/WHEEL": b"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        f"{info}/METADATA": metadata_override or (
            f"Metadata-Version: 2.4\nName: {package_name}\nVersion: {version}\n"
        ).encode(),
        f"{info}/entry_points.txt": entrypoint_override or (
            "[console_scripts]\n"
            + "".join(f"{name} = {target}\n" for name, target in entrypoints.items())
        ).encode(),
    }
    contents.update(extra or {})
    record = f"{info}/RECORD"
    lines = StringIO()
    writer = csv.writer(lines, lineterminator="\n")
    for name, data in sorted(contents.items()):
        digest = urlsafe_b64encode(sha256(data).digest()).rstrip(b"=").decode()
        writer.writerow((name, "sha256=" + digest, str(len(data))))
    writer.writerow((record, "", ""))
    contents[record] = record_override or lines.getvalue().encode()
    output = BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in contents.items():
            item = zipfile.ZipInfo(name)
            item.create_system = 3
            item.external_attr = (
                (stat.S_IFLNK if name == symlink else stat.S_IFREG) | 0o644
            ) << 16
            archive.writestr(item, data)
    return output.getvalue()


def inspect(data: bytes, component: str = "forge-runtime", version: str = "2.7.38"):
    return inspect_product_wheel(
        data, component_identity=component, version=version,
        artifact_sha256="sha256:" + sha256(data).hexdigest(),
    )


class ManagedProductWheelInspectionTests(TestCase):
    def test_exact_forge_and_ep_purelib_wheels_are_read_only(self) -> None:
        for component, version in [
            ("forge-runtime", "2.7.38"),
            ("engineering-platform-server", "2.3.104"),
        ]:
            data = wheel_bytes(component, version)
            first = inspect(data, component, version)
            second = inspect(data, component, version)
            self.assertEqual(first, second)
            self.assertEqual(first.component_identity, component)
            self.assertEqual(first.version, version)
            self.assertEqual(first.wheel_sha256, "sha256:" + sha256(data).hexdigest())
            self.assertEqual(len(first.evidence_reference), 71)
            self.assertEqual(dict(first.entrypoints), ENTRYPOINTS[component][3])
            self.assertTrue(first.members)

    def test_wrong_digest_component_or_version_fails_closed(self) -> None:
        data = wheel_bytes()
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect_product_wheel(
                data, component_identity="forge-runtime", version="2.7.38",
                artifact_sha256="sha256:" + "0" * 64,
            )
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect(data, "engineering-platform-server")
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect(data, version="2.7.39")

    def test_path_traversal_case_collision_and_symlink_fail_closed(self) -> None:
        for extra, symlink in [
            ({"forge/../outside.py": b"x"}, None),
            ({"/forge/absolute.py": b"x"}, None),
            ({"forge\\bad.py": b"x"}, None),
            ({"FORGE/__init__.py": b"x"}, None),
            ({"forge/link.py": b"x"}, "forge/link.py"),
            ({"forge_autonomy-2.7.38.data/scripts/forge": b"x"}, None),
            ({"forge/__init__.py/child": b"x"}, None),
        ]:
            with self.subTest(extra=extra):
                with self.assertRaises(ManagedProductWheelInspectionError):
                    inspect(wheel_bytes(extra=extra, symlink=symlink))

    def test_record_tamper_and_missing_metadata_fail_closed(self) -> None:
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect(wheel_bytes(record_override=b"forge/__init__.py,sha256=wrong,1\n"))
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect(wheel_bytes(metadata_override=(
                b"Metadata-Version: 2.4\nName: forge-autonomy\n"
                b"Version: 2.7.38\nRequires-Dist: unknown\n"
            )))
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect(wheel_bytes(entrypoint_override=(
                b"[console_scripts]\nforge = foreign.module:main\n"
            )))

    def test_forge_281_optional_validation_extra_is_inactive_by_default(self) -> None:
        metadata = (
            'Metadata-Version: 2.4\nName: forge-autonomy\nVersion: 2.8.1\n'
            'Provides-Extra: validation\n'
            'Requires-Dist: coverage<8,>=7; extra == "validation"\n'
            'Requires-Dist: jsonschema<5,>=4; extra == "validation"\n'
        ).encode()
        entrypoints = (
            "[console_scripts]\nforge = forge.__main__:main\n"
            "forge-advisory = forge.advisory_cli:main\n"
            "forge-advisory-context = forge.advisory_context:main\n"
            "forge-advisory-grant = forge.advisory_grant:main\n"
            "forge-mission-derive-actions = forge.mission_no_dispatch:main\n"
            "forge-mission-lifecycle = forge.mission_lifecycle_cli:main\n"
            "forge-workspace-read-grant = forge.workspace_read_grant:main\n"
            "forge-workspace-review-grant = forge.workspace_review_grant:main\n"
            "forge-workspace-worklist-control-grant = forge.workspace_worklist_control_grant:main\n"
        ).encode()
        data = wheel_bytes(version="2.8.1", metadata_override=metadata, entrypoint_override=entrypoints)
        inspect_product_wheel(data, component_identity="forge-runtime", version="2.8.1",
                              artifact_sha256="sha256:" + sha256(data).hexdigest())
        for changed in (
            metadata.replace(b'; extra == "validation"', b''),
            metadata.replace(b'Provides-Extra: validation', b'Provides-Extra: runtime'),
            metadata.replace(b'coverage<8,>=7', b'unknown-package'),
            metadata + b'Requires-Dist: active-runtime-dependency\n',
        ):
            data = wheel_bytes(version="2.8.1", metadata_override=changed, entrypoint_override=entrypoints)
            with self.subTest(metadata=changed), self.assertRaises(ManagedProductWheelInspectionError):
                inspect_product_wheel(data, component_identity="forge-runtime", version="2.8.1",
                                      artifact_sha256="sha256:" + sha256(data).hexdigest())

        for changed in (entrypoints.replace(b"forge.advisory_cli:main", b"foreign.module:main"),
                        entrypoints + b"foreign-command = foreign.module:main\n"):
            data = wheel_bytes(version="2.8.1", metadata_override=metadata, entrypoint_override=changed)
            with self.subTest(entrypoints=changed), self.assertRaises(ManagedProductWheelInspectionError):
                inspect_product_wheel(data, component_identity="forge-runtime", version="2.8.1",
                                      artifact_sha256="sha256:" + sha256(data).hexdigest())

    def test_bounded_expansion_and_malformed_zip_fail_closed(self) -> None:
        with patch("forge_platform.managed_product_wheel_inspection.MAXIMUM_EXPANDED_BYTES", 10):
            with self.assertRaises(ManagedProductWheelInspectionError):
                inspect(wheel_bytes())
        with self.assertRaises(ManagedProductWheelInspectionError):
            inspect(b"not-a-zip")
