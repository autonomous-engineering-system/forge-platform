"""Materialize an exact product wheel inside an unpublished helper-owned venv.

The caller holds the installer operation lock and supplies only names derived
from its own venv-slot layout. An incomplete pending directory is never
published; retry creates a fresh pending directory. This module never touches
product data roots, credentials, services, or an already published venv.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess

from .managed_product_wheel_inspection import inspect_product_wheel


_PENDING = re.compile(r"pending-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
_SLOT = re.compile(r"venv-[0-9a-f]{64}\Z")
_SCRIPT = re.compile(r"[a-z][a-z0-9-]*\Z")
_TARGET = re.compile(r"[a-z_][a-z0-9_.]*:main\Z")
HELPER_VENV_ROOT = Path(
    "/Library/Application Support/AutonomousEngineeringSystem/"
    "ForgePlatformInstaller/managed-python-product-venvs"
)
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
_FILE_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW


class ManagedProductWheelMaterializationError(ValueError):
    """The unpublished venv or exact inspected wheel could not be admitted."""


@dataclass(frozen=True)
class ManagedProductWheelMaterializationReceipt:
    component_identity: str
    version: str
    artifact_sha256: str
    wheel_inspection_evidence: str
    pending_name: str
    published_slot_name: str
    python_minor: str
    file_count: int
    evidence_reference: str


def materialize_product_wheel(
    wheel: bytes, *, component_identity: str, version: str,
    artifact_sha256: str, pending_name: str, published_slot_name: str,
    interpreter_sha256: str,
    venv_root: Path = HELPER_VENV_ROOT, expected_owner: int = 0,
) -> ManagedProductWheelMaterializationReceipt:
    """Write an inspected purelib wheel only under a fresh private pending venv."""

    inventory = inspect_product_wheel(
        wheel, component_identity=component_identity, version=version,
        artifact_sha256=artifact_sha256,
    )
    if (
        not isinstance(pending_name, str) or _PENDING.fullmatch(pending_name) is None
        or not isinstance(published_slot_name, str)
        or _SLOT.fullmatch(published_slot_name) is None
        or not isinstance(venv_root, Path) or not venv_root.is_absolute()
        or not isinstance(interpreter_sha256, str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", interpreter_sha256) is None
        or not isinstance(expected_owner, int) or isinstance(expected_owner, bool)
        or os.geteuid() != expected_owner
    ):
        raise ManagedProductWheelMaterializationError("venv authority is invalid")
    root = _open_private_directory(venv_root, expected_owner, 0o700)
    try:
        try:
            os.stat(published_slot_name, dir_fd=root, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ManagedProductWheelMaterializationError("product venv is already published")
        pending = _open_child(root, pending_name, expected_owner, 0o700)
        try:
            before = os.fstat(pending)
            bin_directory = _open_child(pending, "bin", expected_owner)
            try:
                if _interpreter_digest(bin_directory, expected_owner) != interpreter_sha256:
                    raise ManagedProductWheelMaterializationError(
                        "pending interpreter identity changed"
                    )
                python_minor = _python_minor(venv_root / pending_name / "bin/python3")
                if _interpreter_digest(bin_directory, expected_owner) != interpreter_sha256:
                    raise ManagedProductWheelMaterializationError(
                        "pending interpreter changed during probe"
                    )
                site = _site_packages(pending, python_minor, expected_owner)
                try:
                    if os.listdir(site):
                        raise ManagedProductWheelMaterializationError(
                            "pending venv site-packages is not empty"
                        )
                    for member in inventory.members:
                        _write_relative(site, member.path, member.contents, expected_owner)
                    scripts = _scripts(
                        inventory.entrypoints,
                        venv_root / published_slot_name / "bin/python3",
                    )
                    for name, contents in scripts:
                        _write_file(bin_directory, name, contents, 0o755)
                    for member in inventory.members:
                        if _read_relative(site, member.path, expected_owner, 0o644) != member.contents:
                            raise ManagedProductWheelMaterializationError(
                                "installed wheel bytes changed"
                            )
                    for name, contents in scripts:
                        if _read_file(bin_directory, name, expected_owner, 0o755) != contents:
                            raise ManagedProductWheelMaterializationError(
                                "installed console script changed"
                            )
                    if set(os.listdir(site)) != {
                        member.path.split("/", 1)[0] for member in inventory.members
                    }:
                        raise ManagedProductWheelMaterializationError(
                            "installed product roots are ambiguous"
                        )
                    if os.fstat(pending).st_ino != before.st_ino or (
                        os.fstat(pending).st_dev != before.st_dev
                    ):
                        raise ManagedProductWheelMaterializationError(
                            "pending venv identity changed"
                        )
                    for descriptor in (site, bin_directory, pending, root):
                        os.fsync(descriptor)
                    material = {
                        "schema": "forge-platform.product-wheel-materialization/v1",
                        "component": component_identity,
                        "version": version,
                        "artifact": artifact_sha256,
                        "inspection": inventory.evidence_reference,
                        "pending": pending_name,
                        "slot": published_slot_name,
                        "python_minor": python_minor,
                        "interpreter": interpreter_sha256,
                        "files": [(member.path, sha256(member.contents).hexdigest())
                                  for member in inventory.members],
                        "scripts": [(name, sha256(contents).hexdigest())
                                    for name, contents in scripts],
                    }
                    evidence = "sha256:" + sha256(json.dumps(
                        material, sort_keys=True, separators=(",", ":"),
                        ensure_ascii=True,
                    ).encode("ascii")).hexdigest()
                    return ManagedProductWheelMaterializationReceipt(
                        component_identity, version, artifact_sha256,
                        inventory.evidence_reference, pending_name,
                        published_slot_name, python_minor,
                        len(inventory.members) + len(scripts), evidence,
                    )
                finally:
                    os.close(site)
            finally:
                os.close(bin_directory)
        finally:
            os.close(pending)
    except (OSError, subprocess.SubprocessError) as error:
        raise ManagedProductWheelMaterializationError(
            "pending product venv is unavailable"
        ) from error
    finally:
        os.close(root)


def _open_private_directory(path: Path, owner: int, mode: int) -> int:
    descriptor = os.open(path, _DIRECTORY_FLAGS)
    try:
        _require_directory(descriptor, owner, mode)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _open_child(parent: int, name: str, owner: int, mode: int | None = None) -> int:
    descriptor = os.open(name, _DIRECTORY_FLAGS, dir_fd=parent)
    try:
        _require_directory(descriptor, owner, mode)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _require_directory(descriptor: int, owner: int, mode: int | None) -> None:
    details = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(details.st_mode) or details.st_uid != owner
        or (details.st_mode & 0o022)
        or mode is not None and details.st_mode & 0o7777 != mode
    ):
        raise ManagedProductWheelMaterializationError("venv directory is unsafe")


def _interpreter_digest(parent: int, owner: int) -> str:
    descriptor = os.open("python3", _FILE_FLAGS, dir_fd=parent)
    try:
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode) or details.st_uid != owner
            or details.st_nlink != 1 or details.st_mode & 0o022
            or details.st_size <= 0 or details.st_size > 100 * 1024 * 1024
        ):
            raise ManagedProductWheelMaterializationError("venv interpreter is unsafe")
        digest = sha256()
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            while block := stream.read(64 * 1024):
                digest.update(block)
        after = os.fstat(descriptor)
        if (
            details.st_dev != after.st_dev or details.st_ino != after.st_ino
            or details.st_size != after.st_size
            or details.st_mtime_ns != after.st_mtime_ns
        ):
            raise ManagedProductWheelMaterializationError("venv interpreter changed")
        return "sha256:" + digest.hexdigest()
    finally:
        os.close(descriptor)


def _python_minor(interpreter: Path) -> str:
    result = subprocess.run(
        [str(interpreter), "-I", "-S", "-B", "-c",
         "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
        cwd="/", env={"LANG": "C", "LC_ALL": "C", "HOME": "/var/empty"},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=10, check=True,
    )
    if len(result.stdout) > 16:
        raise ManagedProductWheelMaterializationError("venv runtime changed")
    value = result.stdout.decode("ascii").rstrip("\n")
    if re.fullmatch(r"3\.[0-9]{1,2}", value) is None:
        raise ManagedProductWheelMaterializationError("venv runtime changed")
    return value


def _site_packages(pending: int, python_minor: str, owner: int) -> int:
    current = os.dup(pending)
    try:
        for name in ("lib", f"python{python_minor}", "site-packages"):
            try:
                os.mkdir(name, 0o755, dir_fd=current)
                os.fsync(current)
            except FileExistsError:
                pass
            child = _open_child(current, name, owner)
            os.close(current)
            current = child
        return current
    except BaseException:
        os.close(current)
        raise


def _write_relative(root: int, path: str, contents: bytes, owner: int) -> None:
    parts = path.split("/")
    current = os.dup(root)
    try:
        for name in parts[:-1]:
            try:
                os.mkdir(name, 0o755, dir_fd=current)
                os.fsync(current)
            except FileExistsError:
                pass
            child = _open_child(current, name, owner)
            os.close(current)
            current = child
        _write_file(current, parts[-1], contents, 0o644)
    finally:
        os.close(current)


def _write_file(parent: int, name: str, contents: bytes, mode: int) -> None:
    descriptor = os.open(
        name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        mode, dir_fd=parent,
    )
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(os.dup(descriptor), "wb") as stream:
            stream.write(contents)
            stream.flush()
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(parent)


def _read_relative(root: int, path: str, owner: int, expected_mode: int) -> bytes:
    parts = path.split("/")
    current = os.dup(root)
    try:
        for name in parts[:-1]:
            child = _open_child(current, name, owner)
            os.close(current)
            current = child
        return _read_file(current, parts[-1], owner, expected_mode)
    finally:
        os.close(current)


def _read_file(parent: int, name: str, owner: int, expected_mode: int) -> bytes:
    descriptor = os.open(name, _FILE_FLAGS, dir_fd=parent)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode) or before.st_uid != owner
            or before.st_nlink != 1
            or before.st_mode & 0o7777 != expected_mode
        ):
            raise ManagedProductWheelMaterializationError("installed file is unsafe")
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            contents = stream.read(before.st_size + 1)
        after = os.fstat(descriptor)
        if (
            len(contents) != before.st_size or before.st_dev != after.st_dev
            or before.st_ino != after.st_ino or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
        ):
            raise ManagedProductWheelMaterializationError("installed file changed")
        return contents
    finally:
        os.close(descriptor)


def _scripts(
    entrypoints: tuple[tuple[str, str], ...], interpreter: Path,
) -> tuple[tuple[str, bytes], ...]:
    result = []
    for name, target in entrypoints:
        if _SCRIPT.fullmatch(name) is None or _TARGET.fullmatch(target) is None:
            raise ManagedProductWheelMaterializationError("entrypoint is unsafe")
        module = target.removesuffix(":main")
        # The fixed helper root contains "Application Support". A direct
        # shebang would stop at that space; this bounded trampoline executes
        # only the helper-derived interpreter, with no request-supplied shell.
        quoted_interpreter = shlex.quote(str(interpreter))
        result.append((name, (
            "#!/bin/sh\n"
            f"'''exec' {quoted_interpreter} -B \"$0\" \"$@\"\n"
            "' '''\n"
            f"from {module} import main\n"
            "if __name__ == '__main__':\n"
            "    raise SystemExit(main())\n"
        ).encode("ascii")))
    return tuple(result)
