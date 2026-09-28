"""Durable helper-owned reviewed snapshot for crash-safe removal replay.

The snapshot is written before any product mutation. It contains only the
registered public deployment topology and exact request identity; product
credentials, executable paths and private data never enter the journal.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Mapping

from .managed_deployments import (
    ManagedComponentBinding, ManagedCompositionBinding, ManagedDeployment,
    ManagedDeploymentRegistry, ManagedPeerBinding,
)
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .managed_product_removal_admission import (
    AdmittedNativeProductRemoval, NativeProductRemovalRequest,
    admit_native_product_removal,
)
from .universal_installer import CompositionManifest


REVIEW_SCHEMA = "forge-platform.managed-product-removal-review/v1"
_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_MAX_BYTES = 32 * 1024
_FIELDS = frozenset({
    "schema", "operation_id", "request_fingerprint", "installed_composition_identity",
    "installed_manifest_sha256", "reviewed_plan_sha256", "reviewed_current",
})


class ManagedProductRemovalReviewError(RuntimeError):
    """The durable reviewed removal identity is unavailable or unsafe."""


@dataclass(frozen=True)
class RemovalReviewSnapshot:
    request_fingerprint: str
    installed_composition_identity: str
    installed_manifest_sha256: str
    reviewed_plan_sha256: str
    reviewed_current: ManagedDeployment


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("utf-8")


def _decode_deployment(value: object) -> ManagedDeployment:
    if not isinstance(value, dict) or frozenset(value) != {
        "deployment_id", "revision", "label", "components", "peer_binding",
        "schema", "composition_binding",
    }:
        raise ValueError("reviewed deployment shape is invalid")
    components = value["components"]
    if not isinstance(components, list):
        raise ValueError("reviewed components are invalid")
    peer = value["peer_binding"]
    composition = value["composition_binding"]
    return ManagedDeployment(
        value["deployment_id"], value["revision"], value["label"],
        tuple(ManagedComponentBinding(**item) for item in components),
        None if peer is None else ManagedPeerBinding(**peer),
        value["schema"],
        None if composition is None else ManagedCompositionBinding(**composition),
    )


class ManagedProductRemovalReviewJournal:
    """Persist one exact reviewed removal under a root-owned operation ID."""

    def __init__(
        self, *, root: Path, registry: ManagedDeploymentRegistry,
        expected_owner_uid: int = 0,
    ) -> None:
        if not isinstance(root, Path) or not root.is_absolute():
            raise ValueError("removal review root must be absolute")
        if not isinstance(registry, ManagedDeploymentRegistry):
            raise TypeError("managed deployment registry is required")
        if isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0:
            raise ValueError("removal review owner is invalid")
        self.root = root
        self.registry = registry
        self.expected_owner_uid = expected_owner_uid

    def prepare(
        self, admitted: AdmittedNativeProductRemoval, *,
        current_installer_release: NativeInstallerReleaseBinding,
    ) -> RemovalReviewSnapshot:
        if not isinstance(admitted, AdmittedNativeProductRemoval):
            raise TypeError("admitted removal is required")
        request = admitted.request
        fresh = admit_native_product_removal(
            request, installed_manifest=admitted.installed_manifest,
            registry=self.registry,
            current_installer_release=current_installer_release,
        )
        if fresh != admitted:
            raise ManagedProductRemovalReviewError("reviewed removal changed before journal")
        snapshot = RemovalReviewSnapshot(
            request.request_fingerprint,
            request.installed_composition_identity,
            request.installed_manifest_sha256,
            request.reviewed_plan_sha256,
            admitted.reviewed_current,
        )
        self._secure_root(create=True)
        path = self._path(request.operation_id)
        lock = self.root / f".{request.operation_id}.lock"
        descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            self._require_secure_file(descriptor)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            existing = self._read(path, request)
            if existing is not None:
                if existing != snapshot:
                    raise ManagedProductRemovalReviewError("removal operation identity changed")
                return existing
            payload = {
                "schema": REVIEW_SCHEMA,
                "operation_id": request.operation_id,
                "request_fingerprint": snapshot.request_fingerprint,
                "installed_composition_identity": snapshot.installed_composition_identity,
                "installed_manifest_sha256": snapshot.installed_manifest_sha256,
                "reviewed_plan_sha256": snapshot.reviewed_plan_sha256,
                "reviewed_current": asdict(snapshot.reviewed_current),
            }
            raw = _canonical(payload)
            if len(raw) > _MAX_BYTES:
                raise ManagedProductRemovalReviewError("removal review exceeds its bound")
            temporary_fd, temporary_name = tempfile.mkstemp(prefix=".removal-review-", dir=self.root)
            try:
                os.fchmod(temporary_fd, 0o600)
                with os.fdopen(temporary_fd, "wb") as handle:
                    handle.write(raw)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary_name, path)
                directory_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            finally:
                if os.path.exists(temporary_name):
                    os.unlink(temporary_name)
            return snapshot
        finally:
            os.close(descriptor)

    def load(
        self, request: NativeProductRemovalRequest, *,
        installed_manifest: CompositionManifest,
        current_installer_release: NativeInstallerReleaseBinding,
    ) -> RemovalReviewSnapshot | None:
        if not isinstance(request, NativeProductRemovalRequest):
            raise TypeError("decoded removal request is required")
        if (
            not isinstance(installed_manifest, CompositionManifest)
            or not isinstance(current_installer_release, NativeInstallerReleaseBinding)
            or request.installer_release != current_installer_release
            or request.installed_composition_identity != installed_manifest.composition_id
            or request.installed_manifest_sha256 != installed_manifest.manifest_digest
        ):
            raise ManagedProductRemovalReviewError("removal authority changed")
        self._secure_root(create=False)
        return self._read(self._path(request.operation_id), request)

    def _path(self, operation_id: str) -> Path:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise ManagedProductRemovalReviewError("removal operation ID is invalid")
        return self.root / f"{operation_id}.json"

    def _secure_root(self, *, create: bool) -> None:
        if create:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            info = os.lstat(self.root)
        except OSError as error:
            raise ManagedProductRemovalReviewError("removal review root is unavailable") from error
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != self.expected_owner_uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise ManagedProductRemovalReviewError("removal review root is unsafe")

    def _require_secure_file(self, descriptor: int) -> None:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise ManagedProductRemovalReviewError("removal review file is unsafe")

    def _read(
        self, path: Path, request: NativeProductRemovalRequest,
    ) -> RemovalReviewSnapshot | None:
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        try:
            self._require_secure_file(descriptor)
            raw = os.read(descriptor, _MAX_BYTES + 1)
            if not raw or len(raw) > _MAX_BYTES or os.read(descriptor, 1):
                raise ManagedProductRemovalReviewError("removal review size is invalid")
        finally:
            os.close(descriptor)
        try:
            payload = json.loads(raw)
            if (
                not isinstance(payload, Mapping)
                or frozenset(payload) != _FIELDS
                or _canonical(payload) != raw
                or payload["schema"] != REVIEW_SCHEMA
                or payload["operation_id"] != request.operation_id
                or payload["request_fingerprint"] != request.request_fingerprint
                or payload["installed_composition_identity"]
                != request.installed_composition_identity
                or payload["installed_manifest_sha256"]
                != request.installed_manifest_sha256
                or payload["reviewed_plan_sha256"] != request.reviewed_plan_sha256
            ):
                raise ValueError("removal review identity changed")
            current = _decode_deployment(payload["reviewed_current"])
            snapshot = RemovalReviewSnapshot(
                payload["request_fingerprint"],
                payload["installed_composition_identity"],
                payload["installed_manifest_sha256"],
                payload["reviewed_plan_sha256"], current,
            )
            if (
                current.deployment_id != request.deployment_id
                or sha256(_canonical(asdict(current))).hexdigest()
                != request.reviewed_deployment_sha256
            ):
                raise ValueError("removal review target changed")
            return snapshot
        except (TypeError, ValueError, KeyError, UnicodeError) as error:
            raise ManagedProductRemovalReviewError("removal review is invalid") from error
