"""Independent exact-byte readback of a published helper-owned product venv.

This read-only gate reconstructs expected files from the frozen wheel. It does
not infer installation from an executable's presence, version string, process
exit, or a materialization receipt from an earlier process.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import re

from .managed_product_wheel_inspection import inspect_product_wheel
from .managed_product_wheel_materialization import (
    HELPER_VENV_ROOT, ManagedProductWheelMaterializationError,
    _SLOT, _interpreter_digest, _open_child,
    _open_private_directory, _python_minor, _read_file, _read_relative, _scripts,
)


class ManagedProductWheelReadbackError(ValueError):
    """The published slot does not contain the exact qualified product wheel."""


@dataclass(frozen=True)
class ManagedProductWheelReadbackReceipt:
    component_identity: str
    version: str
    artifact_sha256: str
    published_slot_name: str
    interpreter_sha256: str
    wheel_inspection_evidence: str
    file_count: int
    evidence_reference: str


def read_published_product_wheel(
    wheel: bytes, *, component_identity: str, version: str,
    artifact_sha256: str, published_slot_name: str,
    interpreter_sha256: str, venv_root: Path = HELPER_VENV_ROOT,
    expected_owner: int = 0,
) -> ManagedProductWheelReadbackReceipt:
    """Reconstruct and verify every package, metadata, and script byte."""

    inventory = inspect_product_wheel(
        wheel, component_identity=component_identity, version=version,
        artifact_sha256=artifact_sha256,
    )
    if (
        not isinstance(published_slot_name, str)
        or _SLOT.fullmatch(published_slot_name) is None
        or not isinstance(interpreter_sha256, str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", interpreter_sha256) is None
        or not isinstance(venv_root, Path) or not venv_root.is_absolute()
        or not isinstance(expected_owner, int) or isinstance(expected_owner, bool)
        or os.geteuid() != expected_owner
    ):
        raise ManagedProductWheelReadbackError("published product authority is invalid")
    try:
        root = _open_private_directory(venv_root, expected_owner, 0o700)
        try:
            slot = _open_child(root, published_slot_name, expected_owner, 0o700)
            try:
                bin_directory = _open_child(slot, "bin", expected_owner)
                try:
                    if _interpreter_digest(bin_directory, expected_owner) != interpreter_sha256:
                        raise ManagedProductWheelReadbackError(
                            "published interpreter differs from qualified runtime"
                        )
                    python_minor = _python_minor(
                        venv_root / published_slot_name / "bin/python3"
                    )
                    if _interpreter_digest(bin_directory, expected_owner) != interpreter_sha256:
                        raise ManagedProductWheelReadbackError(
                            "published interpreter changed during probe"
                        )
                    site = _open_site(slot, python_minor, expected_owner)
                    try:
                        _require_exact_tree(
                            site, {member.path for member in inventory.members},
                            expected_owner,
                        )
                        for member in inventory.members:
                            if _read_relative(site, member.path, expected_owner, 0o644) != member.contents:
                                raise ManagedProductWheelReadbackError(
                                    "published wheel member changed"
                                )
                        scripts = _scripts(
                            inventory.entrypoints,
                            venv_root / published_slot_name / "bin/python3",
                        )
                        for name, contents in scripts:
                            if _read_file(bin_directory, name, expected_owner, 0o755) != contents:
                                raise ManagedProductWheelReadbackError(
                                    "published product entrypoint changed"
                                )
                        material = {
                            "schema": "forge-platform.product-wheel-published-readback/v1",
                            "component": component_identity,
                            "version": version,
                            "artifact": artifact_sha256,
                            "inspection": inventory.evidence_reference,
                            "slot": published_slot_name,
                            "interpreter": interpreter_sha256,
                            "python_minor": python_minor,
                            "files": [(member.path, sha256(member.contents).hexdigest())
                                      for member in inventory.members],
                            "scripts": [(name, sha256(contents).hexdigest())
                                        for name, contents in scripts],
                        }
                        evidence = "sha256:" + sha256(json.dumps(
                            material, sort_keys=True, separators=(",", ":"),
                            ensure_ascii=True,
                        ).encode("ascii")).hexdigest()
                        return ManagedProductWheelReadbackReceipt(
                            component_identity, version, artifact_sha256,
                            published_slot_name, interpreter_sha256,
                            inventory.evidence_reference,
                            len(inventory.members) + len(scripts), evidence,
                        )
                    finally:
                        os.close(site)
                finally:
                    os.close(bin_directory)
            finally:
                os.close(slot)
        finally:
            os.close(root)
    except (OSError, ManagedProductWheelMaterializationError, UnicodeError) as error:
        raise ManagedProductWheelReadbackError(
            "published product wheel is unavailable"
        ) from error


def _open_site(slot: int, python_minor: str, owner: int) -> int:
    current = os.dup(slot)
    try:
        for name in ("lib", f"python{python_minor}", "site-packages"):
            child = _open_child(current, name, owner)
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


def _require_exact_tree(root: int, files: set[str], owner: int) -> None:
    children: dict[str, set[str]] = {"": set()}
    for path in files:
        parts = path.split("/")
        for index, name in enumerate(parts):
            parent = "/".join(parts[:index])
            children.setdefault(parent, set()).add(name)
            if index < len(parts) - 1:
                children.setdefault("/".join(parts[:index + 1]), set())
    for directory, expected in children.items():
        current = os.dup(root)
        try:
            for name in directory.split("/") if directory else ():
                child = _open_child(current, name, owner)
                os.close(current)
                current = child
            if set(os.listdir(current)) != expected:
                raise ManagedProductWheelReadbackError(
                    "published wheel file tree changed"
                )
        finally:
            os.close(current)
