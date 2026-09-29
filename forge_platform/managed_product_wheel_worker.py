"""Fixed privileged-worker boundary for exact staged product wheel bytes.

The native helper selects the binding under its operation lock. This worker
accepts only names within the helper's private roots; it never accepts a path,
URL, shell command, credential, or account from the request.
"""

from __future__ import annotations

from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat

from .managed_product_wheel_materialization import (
    HELPER_VENV_ROOT, materialize_product_wheel,
)
from .managed_product_wheel_readback import read_published_product_wheel


SCHEMA = "forge-platform.product-wheel-worker/v1"
MAXIMUM_REQUEST_BYTES = 8192
MAXIMUM_WHEEL_BYTES = 256 * 1024 * 1024
HELPER_STAGED_ROOT = HELPER_VENV_ROOT.parent / "staged"
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_PENDING = re.compile(r"pending-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
_SLOT = re.compile(r"venv-[0-9a-f]{64}\Z")
_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){2}\Z")


class ManagedProductWheelWorkerError(ValueError):
    """The fixed wheel request or staged bytes failed closed."""


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, value in pairs:
        if name in result:
            raise ManagedProductWheelWorkerError("duplicate wheel request field")
        result[name] = value
    return result


def _private_directory(path: Path, owner: int) -> int:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        details = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(details.st_mode) or details.st_uid != owner
            or details.st_mode & 0o7777 != 0o700
        ):
            raise ManagedProductWheelWorkerError("staging directory is unsafe")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _read_staged_wheel(root: Path, digest: str, owner: int) -> bytes:
    directory = _private_directory(root, owner)
    try:
        name = digest.removeprefix("sha256:") + ".artifact"
        descriptor = os.open(
            name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=directory,
        )
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode) or before.st_uid != owner
                or before.st_mode & 0o7777 != 0o600 or before.st_nlink != 1
                or before.st_size < 1 or before.st_size > MAXIMUM_WHEEL_BYTES
            ):
                raise ManagedProductWheelWorkerError("staged wheel is unsafe")
            chunks = []
            length = 0
            while block := os.read(descriptor, 64 * 1024):
                length += len(block)
                if length > MAXIMUM_WHEEL_BYTES:
                    raise ManagedProductWheelWorkerError("staged wheel is oversized")
                chunks.append(block)
            after = os.fstat(descriptor)
            if (
                length != before.st_size
                or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns,
                    before.st_ctime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns,
                    after.st_ctime_ns)
            ):
                raise ManagedProductWheelWorkerError("staged wheel changed during read")
            data = b"".join(chunks)
            if "sha256:" + sha256(data).hexdigest() != digest:
                raise ManagedProductWheelWorkerError("staged wheel digest changed")
            return data
        finally:
            os.close(descriptor)
    finally:
        os.close(directory)


def execute_wheel_request(
    raw: bytes, *, staged_root: Path = HELPER_STAGED_ROOT,
    venv_root: Path = HELPER_VENV_ROOT, expected_owner: int = 0,
) -> bytes:
    """Install only into pending or independently read an exact published slot."""

    if (
        not isinstance(raw, bytes) or not 0 < len(raw) <= MAXIMUM_REQUEST_BYTES
        or not isinstance(staged_root, Path) or not staged_root.is_absolute()
        or not isinstance(venv_root, Path) or not venv_root.is_absolute()
        or not isinstance(expected_owner, int) or isinstance(expected_owner, bool)
        or os.geteuid() != expected_owner
    ):
        raise ManagedProductWheelWorkerError("wheel request authority is invalid")
    try:
        request = json.loads(
            raw.decode("ascii"), object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, ValueError) as error:
        raise ManagedProductWheelWorkerError("wheel request is not canonical JSON") from error
    if (
        not isinstance(request, dict)
        or set(request) != {
            "schema", "action", "component_identity", "version", "artifact_sha256",
            "pending_name", "published_slot_name", "interpreter_sha256",
        }
        or _canonical(request) != raw or request["schema"] != SCHEMA
        or not isinstance(request["action"], str)
        or request["action"] not in {"INSTALL_PENDING", "READ_PUBLISHED"}
        or not isinstance(request["component_identity"], str)
        or request["component_identity"] not in {
            "forge-runtime", "engineering-platform-server",
        }
        or not isinstance(request["version"], str)
        or _VERSION.fullmatch(request["version"]) is None
        or not isinstance(request["artifact_sha256"], str)
        or _DIGEST.fullmatch(request["artifact_sha256"]) is None
        or not isinstance(request["interpreter_sha256"], str)
        or _DIGEST.fullmatch(request["interpreter_sha256"]) is None
        or not isinstance(request["published_slot_name"], str)
        or _SLOT.fullmatch(request["published_slot_name"]) is None
        or (request["action"] == "INSTALL_PENDING" and (
            not isinstance(request["pending_name"], str)
            or _PENDING.fullmatch(request["pending_name"]) is None
        ))
        or (request["action"] == "READ_PUBLISHED" and request["pending_name"] is not None)
    ):
        raise ManagedProductWheelWorkerError("wheel request binding is invalid")
    wheel = _read_staged_wheel(staged_root, request["artifact_sha256"], expected_owner)
    arguments = dict(
        component_identity=request["component_identity"],
        version=request["version"], artifact_sha256=request["artifact_sha256"],
        published_slot_name=request["published_slot_name"],
        interpreter_sha256=request["interpreter_sha256"],
        venv_root=venv_root, expected_owner=expected_owner,
    )
    if request["action"] == "INSTALL_PENDING":
        receipt = materialize_product_wheel(
            wheel, pending_name=request["pending_name"], **arguments,
        )
    else:
        receipt = read_published_product_wheel(wheel, **arguments)
    binding = {
        "schema": SCHEMA, "component_identity": request["component_identity"],
        "version": request["version"], "artifact_sha256": request["artifact_sha256"],
        "published_slot_name": request["published_slot_name"],
        "interpreter_sha256": request["interpreter_sha256"],
        "wheel_inspection_evidence": receipt.wheel_inspection_evidence,
    }
    return _canonical({
        "schema": "forge-platform.product-wheel-worker-receipt/v1",
        "action": request["action"],
        "request_sha256": "sha256:" + sha256(raw).hexdigest(),
        "binding_evidence": "sha256:" + sha256(_canonical(binding)).hexdigest(),
        "verification_evidence": receipt.evidence_reference,
        "file_count": receipt.file_count,
    })
