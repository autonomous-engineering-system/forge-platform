"""Durable standalone EP RESTORE through the owning lifecycle and repair CLI.

The restored service remains inactive until EP itself verifies providers and
completes repair. No provider secret or product filesystem path enters this
journal. The released helper must separately supply the sealed product routes.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Mapping

from .component_operations import ComponentOperationRequest
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .managed_deployments import ManagedDeploymentRegistry
from .managed_install_flow import InstallerMutationCurrencyGuard
from .managed_preserve_execution import (
    ManagedPreserveExecutionRecord, read_terminal_preserve_evidence,
)
from .managed_preserved_lifecycle_plan import (
    ManagedPreservedLifecycleReview, require_current_preserved_lifecycle_review,
)
from .managed_preserved_product_adapters import EPPreservedProductAdapter
from .product_preserved_lifecycle import EP_COMPONENT, EP_CONTRACT
from .universal_installer import CompositionManifest


_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_REPAIR_REFERENCE = re.compile(r"ep-receipt:[0-9a-f]{64}\Z")
_MAX_JOURNAL_BYTES = 4096
_STATES = frozenset({"PREPARED", "PRODUCT_TERMINAL", "REPAIRED", "COMPLETE"})
_RECEIPT_FIELDS = frozenset({
    "contract", "operation", "operation_id", "instance_id",
    "request_digest", "state", "evidence", "receipt_sha256",
})
_EVIDENCE_FIELDS = frozenset({
    "lifecycle_state", "instance_identity", "mutable_instance_data",
    "mutable_instance_data_digest", "restored_from_preserve_operation",
    "restored", "restorable", "service_state", "shared_immutable_runtime_slots",
    "provider_auth_state", "ready", "release",
})
_RELEASE_FIELDS = frozenset({"version", "artifact_digest", "source_revision"})


class ManagedEPRestoreExecutionError(RuntimeError):
    """The exact EP RESTORE continuation is unavailable or stale."""


@dataclass(frozen=True)
class _RestoreJournal:
    operation_id: str
    deployment_id: str
    review_fingerprint: str
    instance_id: str
    preserve_operation_id: str
    composition_digest: str
    state: str
    restore_receipt: dict[str, object] | None
    repair_reference: str | None
    registry_revision: int | None


def _safe_restore_receipt(value: object, review: ManagedPreservedLifecycleReview) -> dict[str, object]:
    if not isinstance(value, Mapping) or frozenset(value) != _RECEIPT_FIELDS:
        raise ManagedEPRestoreExecutionError("EP restore journal receipt shape changed")
    receipt = dict(value)
    evidence = receipt["evidence"]
    if not isinstance(evidence, Mapping) or frozenset(evidence) != _EVIDENCE_FIELDS:
        raise ManagedEPRestoreExecutionError("EP restore journal evidence shape changed")
    release = evidence["release"]
    if not isinstance(release, Mapping) or frozenset(release) != _RELEASE_FIELDS:
        raise ManagedEPRestoreExecutionError("EP restore journal release shape changed")
    if (
        receipt["contract"] != EP_CONTRACT
        or receipt["operation"] != "RESTORE"
        or receipt["operation_id"] != review.operation_id
        or receipt["instance_id"] != review.instance_id
        or evidence["restored_from_preserve_operation"] != review.preserve_operation_id
        or evidence["lifecycle_state"] != "RESTORED_REQUIRES_PROVIDER_REVERIFICATION"
        or receipt["state"] != "COMPLETE"
        or not isinstance(receipt["request_digest"], str)
        or _DIGEST.fullmatch(receipt["request_digest"]) is None
        or evidence["instance_identity"] != "PRESERVED"
        or evidence["mutable_instance_data"] != "PRESERVED"
        or not isinstance(evidence["mutable_instance_data_digest"], str)
        or _DIGEST.fullmatch(evidence["mutable_instance_data_digest"]) is None
        or evidence["restored"] is not True
        or evidence["ready"] is not False
        or evidence["restorable"] is not False
        or evidence["service_state"] != "REGISTERED_INACTIVE"
        or evidence["shared_immutable_runtime_slots"] != "PRESERVED"
        or evidence["provider_auth_state"] != "PRESERVED_REQUIRES_REVERIFICATION"
        or release != {
            "version": review.artifact.version,
            "artifact_digest": review.artifact.digest,
            "source_revision": review.artifact.source_revision,
        }
        or not isinstance(receipt["receipt_sha256"], str)
        or _DIGEST.fullmatch(receipt["receipt_sha256"]) is None
    ):
        raise ManagedEPRestoreExecutionError("EP restore journal target changed")
    try:
        raw = json.dumps(receipt, sort_keys=True, separators=(",", ":"), allow_nan=False)
        if len(raw.encode("utf-8")) > _MAX_JOURNAL_BYTES // 2:
            raise ValueError("receipt too large")
    except (TypeError, ValueError, UnicodeError) as error:
        raise ManagedEPRestoreExecutionError("EP restore journal receipt is unsafe") from error
    return json.loads(raw)


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate restore journal field")
        result[key] = value
    return result


def _read(path: Path, owner_uid: int, review: ManagedPreservedLifecycleReview) -> _RestoreJournal | None:
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
            raise ManagedEPRestoreExecutionError("EP restore journal is unsafe")
        raw = os.read(fd, _MAX_JOURNAL_BYTES + 1)
    finally:
        os.close(fd)
    try:
        value = json.loads(raw, object_pairs_hook=_unique)
        if (
            not isinstance(value, dict)
            or frozenset(value) != frozenset(_RestoreJournal.__dataclass_fields__)
            or json.dumps(value, sort_keys=True, separators=(",", ":"),
                          allow_nan=False).encode("utf-8") != raw
        ):
            raise ValueError("journal shape changed")
        record = _RestoreJournal(**value)
    except (UnicodeError, ValueError, TypeError) as error:
        raise ManagedEPRestoreExecutionError("EP restore journal is invalid") from error
    if (
        record.operation_id != review.operation_id
        or record.deployment_id != review.deployment_id
        or record.review_fingerprint != review.review_fingerprint
        or record.instance_id != review.instance_id
        or record.preserve_operation_id != review.preserve_operation_id
        or record.composition_digest != review.composition_digest
        or record.state not in _STATES
        or record.state == "PREPARED" and record.restore_receipt is not None
        or record.state != "PREPARED" and record.restore_receipt is None
        or record.state in {"PREPARED", "PRODUCT_TERMINAL"}
            and record.repair_reference is not None
        or record.state in {"REPAIRED", "COMPLETE"}
            and (not isinstance(record.repair_reference, str)
                 or _REPAIR_REFERENCE.fullmatch(record.repair_reference) is None)
        or record.state != "COMPLETE" and record.registry_revision is not None
        or record.state == "COMPLETE" and (
            type(record.registry_revision) is not int
            or record.registry_revision != review.registry_revision + 1
        )
    ):
        raise ManagedEPRestoreExecutionError("EP restore journal identity changed")
    if record.restore_receipt is not None:
        _safe_restore_receipt(record.restore_receipt, review)
    return record


def _write(path: Path, record: _RestoreJournal) -> None:
    raw = json.dumps(asdict(record), sort_keys=True, separators=(",", ":"),
                     allow_nan=False).encode("utf-8")
    if len(raw) > _MAX_JOURNAL_BYTES:
        raise ManagedEPRestoreExecutionError("EP restore journal exceeds bound")
    fd, name = tempfile.mkstemp(prefix=".ep-restore-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
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


class ManagedEPRestoreExecutionCoordinator:
    """Resume one exact EP restore; commit only after EP repair/readiness."""

    def __init__(
        self, *, operations_root: Path, preserve_operations_root: Path,
        registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        expected_owner_uid: int = 0,
    ) -> None:
        if (
            not isinstance(operations_root, Path) or not operations_root.is_absolute()
            or not isinstance(preserve_operations_root, Path)
            or not preserve_operations_root.is_absolute()
            or not isinstance(registry, ManagedDeploymentRegistry)
            or not callable(getattr(currency_guard, "require_current", None))
            or type(expected_owner_uid) is not int or expected_owner_uid < 0
        ):
            raise ValueError("EP restore coordinator authority is invalid")
        self.operations_root = operations_root
        self.preserve_operations_root = preserve_operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.expected_owner_uid = expected_owner_uid

    def _current(self, review: ManagedPreservedLifecycleReview,
                 manifest: CompositionManifest) -> None:
        current = self.registry.load(review.deployment_id)
        if current is None or current.peer_binding is not None or (
            getattr(current, "historical_peer_binding", None) is not None
        ) or current.active_by_component or set(current.preserved_by_component) != {EP_COMPONENT}:
            raise ManagedEPRestoreExecutionError("standalone EP restore inventory changed")
        try:
            require_current_preserved_lifecycle_review(
                review, current=current, installed_manifest=manifest,
            )
        except Exception as error:
            raise ManagedEPRestoreExecutionError("reviewed EP restore target is stale") from error

    def _currency(self, review: ManagedPreservedLifecycleReview) -> None:
        self.currency_guard.require_current(
            deployment_id=review.deployment_id, mutation="RESTORE",
            component=EP_COMPONENT, instance_id=review.instance_id,
            operation_id=review.operation_id,
        )

    @staticmethod
    def _repair_request(review: ManagedPreservedLifecycleReview) -> ComponentOperationRequest:
        digest = sha256((review.operation_id + "/" + review.review_fingerprint).encode()).hexdigest()
        return ComponentOperationRequest(
            "ep-repair-" + digest, EP_COMPONENT, "repair", review.artifact,
            review.instance_id, "server", {},
        )

    def restore(
        self, review: ManagedPreservedLifecycleReview, *,
        installed_manifest: CompositionManifest,
        lifecycle: EPPreservedProductAdapter,
        system: EngineeringPlatformSystemProvisionerAdapter,
    ) -> ManagedPreserveExecutionRecord:
        if (
            not isinstance(review, ManagedPreservedLifecycleReview)
            or review.operation != "RESTORE" or review.component != EP_COMPONENT
            or not isinstance(review.operation_id, str)
            or _ID.fullmatch(review.operation_id) is None
            or not isinstance(review.deployment_id, str)
            or _ID.fullmatch(review.deployment_id) is None
            or not isinstance(review.instance_id, str)
            or _ID.fullmatch(review.instance_id) is None
            or not isinstance(review.preserve_operation_id, str)
            or _ID.fullmatch(review.preserve_operation_id) is None
            or not isinstance(installed_manifest, CompositionManifest)
            or (review.composition_id, review.composition_digest) !=
                (installed_manifest.composition_id, installed_manifest.manifest_digest)
            or not isinstance(lifecycle, EPPreservedProductAdapter)
            or not isinstance(system, EngineeringPlatformSystemProvisionerAdapter)
            or lifecycle.target != system.target
            or lifecycle.target.instance_id != review.instance_id
            or lifecycle.artifact != review.artifact
        ):
            raise ManagedEPRestoreExecutionError("EP restore route is not sealed")
        root = self.operations_root
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = os.lstat(root)
        if (
            not stat.S_ISDIR(info.st_mode) or info.st_uid != self.expected_owner_uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise ManagedEPRestoreExecutionError("EP restore journal root is unsafe")
        lock = os.open(root / f".{review.deployment_id}.lock",
                       os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(lock)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedEPRestoreExecutionError("EP restore lock is unsafe")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self._locked_restore(
                root / f"restore-{review.operation_id}.json", review,
                installed_manifest, lifecycle, system,
            )
        finally:
            os.close(lock)

    def _locked_restore(
        self, path: Path, review: ManagedPreservedLifecycleReview,
        manifest: CompositionManifest, lifecycle: EPPreservedProductAdapter,
        system: EngineeringPlatformSystemProvisionerAdapter,
    ) -> ManagedPreserveExecutionRecord:
        record = _read(path, self.expected_owner_uid, review)
        current = self.registry.load(review.deployment_id)
        active_replay = (
            current is not None and current.revision == review.registry_revision + 1
            and set(current.active_by_component) == {EP_COMPONENT}
            and not current.preserved_by_component
        )
        if active_replay:
            if record is None or record.state not in {"REPAIRED", "COMPLETE"}:
                raise ManagedEPRestoreExecutionError("EP restore registry outran its journal")
        else:
            if record is not None and record.state == "COMPLETE":
                raise ManagedEPRestoreExecutionError("completed EP restore lost its inventory")
            self._current(review, manifest)
            preserved = read_terminal_preserve_evidence(
                operations_root=self.preserve_operations_root, registry=self.registry,
                deployment_id=review.deployment_id,
                operation_id=review.preserve_operation_id,
                component=EP_COMPONENT, instance_id=review.instance_id,
                review_fingerprint=None,
                composition_id=review.composition_id,
                manifest_digest=review.composition_digest,
                expected_owner_uid=self.expected_owner_uid,
            )
            if preserved.receipt_digest != review.preserve_receipt_digest:
                raise ManagedEPRestoreExecutionError("EP preserve receipt changed")
            lifecycle.require_terminal_preserve_status(
                operation_id=review.preserve_operation_id,
                receipt_digest=preserved.receipt_digest,
            )
        if record is None:
            record = _RestoreJournal(
                review.operation_id, review.deployment_id, review.review_fingerprint,
                review.instance_id, review.preserve_operation_id,
                review.composition_digest, "PREPARED", None, None, None,
            )
            _write(path, record)
        if record.restore_receipt is None:
            self._currency(review)
            self._current(review, manifest)
            invoked = lifecycle.invoke(
                review, registry=self.registry, installed_manifest=manifest,
            )
            receipt = _safe_restore_receipt(invoked.receipt, review)
            lifecycle.read_terminal_restore(
                review, receipt=receipt,
                receipt_digest=invoked.terminal.receipt_digest,
            )
            record = replace(record, state="PRODUCT_TERMINAL", restore_receipt=receipt)
            _write(path, record)
        else:
            receipt = record.restore_receipt
        terminal = lifecycle.read_terminal_restore(
            review, receipt=receipt,
            receipt_digest=receipt["receipt_sha256"],
        )
        repair = self._repair_request(review)
        if not active_replay:
            self._currency(review)
            self._current(review, manifest)
            repaired = system.execute(repair)
            if (
                repaired.state != "COMPLETED"
                or repaired.product_operation_id != repair.operation_id
                or repaired.installation_identity != review.instance_id
                or repaired.artifact != review.artifact.correlation
                or record.repair_reference is not None
                    and record.repair_reference != repaired.evidence_reference
            ):
                raise ManagedEPRestoreExecutionError("EP repair terminal identity changed")
            record = replace(record, state="REPAIRED",
                             repair_reference=repaired.evidence_reference)
            _write(path, record)
        self._currency(review)
        readback = system.readback(repair)
        committed = self.registry.commit_ep_restored(
            deployment_id=review.deployment_id,
            expected_revision=review.registry_revision,
            instance_id=review.instance_id,
            operation_id=review.operation_id,
            preserve_operation_id=review.preserve_operation_id,
            artifact=review.artifact, installed_manifest=manifest,
            receipt=receipt, status=terminal.status, readback=readback,
        )
        record = replace(record, state="COMPLETE", registry_revision=committed.revision)
        _write(path, record)
        return ManagedPreserveExecutionRecord(
            review.operation_id, review.deployment_id, review.review_fingerprint,
            EP_COMPONENT, review.instance_id, "COMPLETE",
            terminal.terminal.receipt_digest, committed.revision,
        )
