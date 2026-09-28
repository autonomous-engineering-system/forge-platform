"""Durable, exact-instance PRESERVE continuation inside the privileged worker.

The owning product preserves data. Forge Platform controls only its own Forge
LaunchDaemon and commits the product-proven inventory transition. A journal
binds retries to the original reviewed operation without storing product data.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Protocol

from .forge_server_adapter import ForgeServiceSupervisor, ForgeServerTarget
from .managed_deployments import ManagedDeployment, ManagedDeploymentRegistry
from .managed_install_flow import InstallerMutationCurrencyGuard
from .managed_preserved_lifecycle_plan import (
    ManagedPreservedLifecycleReview, require_current_preserved_lifecycle_review,
)
from .managed_preserved_product_adapters import (
    EPPreservedProductAdapter, ForgePreservedProductAdapter,
    ProductPreservedLifecycleInvocation,
)
from .product_preserved_lifecycle import EP_COMPONENT, FORGE_COMPONENT
from .universal_installer import CompositionManifest


_MAX_JOURNAL_BYTES = 4096
_STATES = ("PREPARED", "PRODUCT_TERMINAL", "SERVICE_REMOVED", "COMPLETE")
_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")


class ManagedPreserveExecutionError(RuntimeError):
    """Preserve continuation has no current exact authority or terminal proof."""


class PreservedProductAdapter(Protocol):
    target: object

    def invoke(
        self, review: ManagedPreservedLifecycleReview, *,
        registry: ManagedDeploymentRegistry, installed_manifest: CompositionManifest,
    ) -> ProductPreservedLifecycleInvocation: ...


@dataclass(frozen=True)
class ManagedPreserveExecutionRecord:
    operation_id: str
    deployment_id: str
    review_fingerprint: str
    component: str
    instance_id: str
    state: str
    receipt_digest: str | None
    registry_revision: int | None


def _read(path: Path, owner_uid: int) -> ManagedPreserveExecutionRecord | None:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode) or info.st_uid != owner_uid
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_size > _MAX_JOURNAL_BYTES
        ):
            raise ManagedPreserveExecutionError("preserve journal is unsafe")
        raw = os.read(fd, _MAX_JOURNAL_BYTES + 1)
    finally:
        os.close(fd)
    if len(raw) > _MAX_JOURNAL_BYTES:
        raise ManagedPreserveExecutionError("preserve journal exceeds bound")
    try:
        def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
            result: dict[str, object] = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate journal field")
                result[key] = value
            return result

        pairs = json.loads(raw, object_pairs_hook=unique)
        if not isinstance(pairs, dict) or set(pairs) != set(ManagedPreserveExecutionRecord.__dataclass_fields__):
            raise ValueError("unexpected journal fields")
        record = ManagedPreserveExecutionRecord(**pairs)
    except (UnicodeError, ValueError, TypeError) as error:
        raise ManagedPreserveExecutionError("preserve journal is invalid") from error
    if record.state not in _STATES:
        raise ManagedPreserveExecutionError("preserve journal state is invalid")
    if (
        any(not isinstance(value, str) or not value for value in (
            record.operation_id, record.deployment_id, record.review_fingerprint,
            record.component, record.instance_id,
        ))
        or record.receipt_digest is not None and not isinstance(record.receipt_digest, str)
        or record.registry_revision is not None and (
            isinstance(record.registry_revision, bool)
            or not isinstance(record.registry_revision, int)
        )
        or record.receipt_digest is not None and _DIGEST.fullmatch(record.receipt_digest) is None
        or record.state == "PREPARED" and (
            record.receipt_digest is not None or record.registry_revision is not None
        )
        or record.state != "PREPARED" and record.receipt_digest is None
        or record.state == "COMPLETE" and record.registry_revision is None
    ):
        raise ManagedPreserveExecutionError("preserve journal identity is invalid")
    return record


def _write(path: Path, record: ManagedPreserveExecutionRecord) -> None:
    raw = json.dumps(asdict(record), sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(raw) > _MAX_JOURNAL_BYTES:
        raise ManagedPreserveExecutionError("preserve journal exceeds bound")
    descriptor, name = tempfile.mkstemp(prefix=".preserve-", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(name).unlink(missing_ok=True)


class ManagedPreserveExecutionCoordinator:
    """Resume one product-owned PRESERVE and commit only its exact instance."""

    def __init__(
        self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        forge_supervisor: ForgeServiceSupervisor | None = None,
        expected_owner_uid: int = 0,
    ) -> None:
        if (
            not isinstance(operations_root, Path) or not operations_root.is_absolute()
            or isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int)
            or expected_owner_uid < 0
        ):
            raise ValueError("preserve journal authority is invalid")
        self.operations_root = operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.forge_supervisor = forge_supervisor
        self.expected_owner_uid = expected_owner_uid

    def _current(self, review: ManagedPreservedLifecycleReview, manifest: CompositionManifest) -> ManagedDeployment:
        current = self.registry.load(review.deployment_id)
        if current is None:
            raise ManagedPreserveExecutionError("reviewed preserve deployment is unavailable")
        try:
            require_current_preserved_lifecycle_review(
                review, current=current, installed_manifest=manifest,
            )
        except Exception as error:
            raise ManagedPreserveExecutionError("reviewed preserve target is stale") from error
        return current

    def _currency(self, review: ManagedPreservedLifecycleReview) -> None:
        self.currency_guard.require_current(
            deployment_id=review.deployment_id, mutation="PRESERVE",
            component=review.component, instance_id=review.instance_id,
            operation_id=review.operation_id,
        )

    def preserve(
        self, review: ManagedPreservedLifecycleReview, *,
        installed_manifest: CompositionManifest, adapter: PreservedProductAdapter,
    ) -> ManagedPreserveExecutionRecord:
        if (
            not isinstance(review, ManagedPreservedLifecycleReview)
            or review.operation != "PRESERVE"
            or not isinstance(review.operation_id, str)
            or _ID.fullmatch(review.operation_id) is None
            or not isinstance(review.deployment_id, str)
            or _ID.fullmatch(review.deployment_id) is None
            or review.component not in {FORGE_COMPONENT, EP_COMPONENT}
            or not isinstance(installed_manifest, CompositionManifest)
            or getattr(getattr(adapter, "target", None), "instance_id", None) != review.instance_id
            or review.component == FORGE_COMPONENT and (
                self.forge_supervisor is None
                or not isinstance(adapter, ForgePreservedProductAdapter)
                or not isinstance(adapter.target, ForgeServerTarget)
            )
            or review.component == EP_COMPONENT and not isinstance(adapter, EPPreservedProductAdapter)
        ):
            raise ManagedPreserveExecutionError("preserve product target is not sealed")
        root = self.operations_root
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = os.lstat(root)
        if (
            not stat.S_ISDIR(info.st_mode) or info.st_uid != self.expected_owner_uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise ManagedPreserveExecutionError("preserve journal root is unsafe")
        path = root / f"{review.operation_id}.json"
        lock_path = root / f".{review.deployment_id}.lock"
        lock = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(lock)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedPreserveExecutionError("preserve lock is unsafe")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self._locked_preserve(path, review, installed_manifest, adapter)
        finally:
            os.close(lock)

    def _locked_preserve(
        self, path: Path, review: ManagedPreservedLifecycleReview,
        manifest: CompositionManifest, adapter: PreservedProductAdapter,
    ) -> ManagedPreserveExecutionRecord:
        intended = ManagedPreserveExecutionRecord(
            review.operation_id, review.deployment_id, review.review_fingerprint,
            review.component, review.instance_id, "PREPARED", None, None,
        )
        existing = _read(path, self.expected_owner_uid)
        if existing is not None and replace(
            existing, state="PREPARED", receipt_digest=None, registry_revision=None,
        ) != intended:
            raise ManagedPreserveExecutionError("preserve operation identity changed")
        current = self.registry.load(review.deployment_id)
        if current is None:
            raise ManagedPreserveExecutionError("reviewed preserve deployment is unavailable")
        preserved = current.preserved_by_component.get(review.component)
        if preserved is not None:
            if (
                existing is None or existing.receipt_digest is None
                or current.revision != review.registry_revision + 1
                or preserved.instance_id != review.instance_id
                or preserved.preserve_operation_id != review.operation_id
                or preserved.preserve_receipt_digest != existing.receipt_digest
                or preserved.previous_receipt_reference != review.previous_receipt_reference
                or (preserved.version, preserved.source_revision, preserved.artifact_digest)
                    != (review.artifact.version, review.artifact.source_revision, review.artifact.digest)
                or current.composition_binding is None
                or (current.composition_binding.composition_id, current.composition_binding.manifest_digest)
                    != (review.composition_id, review.composition_digest)
                or (manifest.composition_id, manifest.manifest_digest)
                    != (review.composition_id, review.composition_digest)
                or review.component == FORGE_COMPONENT and self.forge_supervisor.loaded(adapter.target)
            ):
                raise ManagedPreserveExecutionError("preserve replay has no exact terminal state")
            complete = replace(existing, state="COMPLETE", registry_revision=current.revision)
            _write(path, complete)
            return complete
        if existing is not None and existing.state == "COMPLETE":
            raise ManagedPreserveExecutionError("completed preserve lost its inventory")
        self._current(review, manifest)
        if existing is None:
            _write(path, intended)
        if review.component == FORGE_COMPONENT:
            self._currency(review)
            self._current(review, manifest)
            self.forge_supervisor.stop(adapter.target)
            if self.forge_supervisor.loaded(adapter.target):
                raise ManagedPreserveExecutionError("Forge service remains loaded")
        self._currency(review)
        self._current(review, manifest)
        evidence = adapter.invoke(review, registry=self.registry, installed_manifest=manifest)
        if (
            evidence.terminal.component != review.component
            or evidence.terminal.operation != "PRESERVE"
            or evidence.terminal.operation_id != review.operation_id
            or evidence.terminal.instance_id != review.instance_id
            or evidence.terminal.lifecycle_state != "UNINSTALLED_DATA_PRESERVED"
        ):
            raise ManagedPreserveExecutionError("owning preserve result changed")
        if existing is not None and existing.receipt_digest is not None and (
            existing.receipt_digest != evidence.terminal.receipt_digest
        ):
            raise ManagedPreserveExecutionError("preserve replay changed owning receipt")
        record = replace(intended, state="PRODUCT_TERMINAL", receipt_digest=evidence.terminal.receipt_digest)
        _write(path, record)
        if review.component == FORGE_COMPONENT:
            self._currency(review)
            self._current(review, manifest)
            if self.forge_supervisor.loaded(adapter.target):
                raise ManagedPreserveExecutionError("Forge service restarted during preserve")
            self.forge_supervisor.remove(adapter.target)
            if self.forge_supervisor.loaded(adapter.target):
                raise ManagedPreserveExecutionError("Forge service remains loaded after removal")
        record = replace(record, state="SERVICE_REMOVED")
        _write(path, record)
        self._currency(review)
        self._current(review, manifest)
        committed = self.registry.commit_preserved(
            deployment_id=review.deployment_id, expected_revision=review.registry_revision,
            component=review.component, instance_id=review.instance_id,
            operation_id=review.operation_id, artifact=review.artifact,
            installed_manifest=manifest, request_digest=evidence.receipt["request_digest"],
            receipt=evidence.receipt, status=evidence.status,
        )
        record = replace(record, state="COMPLETE", registry_revision=committed.revision)
        _write(path, record)
        return record
