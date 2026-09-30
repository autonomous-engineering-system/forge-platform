"""Durable, exact-instance PRESERVE and PURGE inside the privileged worker.

The owning product controls data. Forge Platform controls only its own Forge
LaunchDaemon and commits product-proven inventory transitions. A journal binds
retries to the original reviewed operation without storing product data.
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
from typing import Protocol

from .forge_server_adapter import ForgeServiceSupervisor, ForgeServerTarget
from .managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2, MANAGED_DEPLOYMENT_SCHEMA_V3,
    ManagedDeployment, ManagedDeploymentPlanner, ManagedDeploymentRegistry,
    prior_paired_forge_candidates,
)
from .managed_install_flow import InstallerMutationCurrencyGuard
from .managed_pairing_revocation import PairingRevocationRecord
from .managed_preserved_lifecycle_plan import (
    ManagedPreservedLifecycleReview, require_current_preserved_lifecycle_review,
)
from .managed_preserved_product_adapters import (
    EPPreservedProductAdapter, ForgePreservedProductAdapter,
    ProductPreservedLifecycleInvocation,
)
from .product_preserved_lifecycle import EP_COMPONENT, FORGE_COMPONENT, frozen_preserved_release
from .universal_installer import CompositionManifest


_MAX_JOURNAL_BYTES = 4096
_STATES = ("PREPARED", "PRODUCT_TERMINAL", "SERVICE_REMOVED", "COMMITTING", "COMPLETE")
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

    def require_terminal_preserve_status(
        self, *, operation_id: str, receipt_digest: str,
    ) -> None: ...

    def require_terminal_purge_status(
        self, review: ManagedPreservedLifecycleReview, *, receipt_digest: str,
    ) -> None: ...


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


def read_terminal_preserve_evidence(
    *, operations_root: Path, registry: ManagedDeploymentRegistry,
    deployment_id: str, operation_id: str, component: str, instance_id: str,
    review_fingerprint: str | None, composition_id: str, manifest_digest: str,
    expected_owner_uid: int = 0,
) -> ManagedPreserveExecutionRecord:
    """Read a committed exact PRESERVE from helper-owned journal and V3 registry.

    This is a recovery observation, never authority to perform a new product
    mutation. A missing, in-flight, stale or ambiguous record fails closed.
    """
    if (
        not isinstance(operations_root, Path) or not operations_root.is_absolute()
        or not isinstance(registry, ManagedDeploymentRegistry)
        or any(not isinstance(value, str) or _ID.fullmatch(value) is None for value in (
            deployment_id, operation_id, instance_id, composition_id,
        ))
        or component not in {FORGE_COMPONENT, EP_COMPONENT}
        or review_fingerprint is not None and (
            not isinstance(review_fingerprint, str)
            or _DIGEST.fullmatch(review_fingerprint) is None
        )
        or not isinstance(manifest_digest, str)
        or _DIGEST.fullmatch(manifest_digest) is None
        or isinstance(expected_owner_uid, bool)
        or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0
    ):
        raise ManagedPreserveExecutionError("terminal preserve selector is invalid")
    try:
        root_info = os.lstat(operations_root)
        if (
            not stat.S_ISDIR(root_info.st_mode)
            or root_info.st_uid != expected_owner_uid
            or stat.S_IMODE(root_info.st_mode) != 0o700
        ):
            raise ManagedPreserveExecutionError("preserve journal root is unsafe")
        lock_path = operations_root / f".{deployment_id}.lock"
        lock = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW)
    except (FileNotFoundError, OSError) as error:
        raise ManagedPreserveExecutionError("terminal preserve evidence is unavailable") from error
    try:
        lock_info = os.fstat(lock)
        if (
            not stat.S_ISREG(lock_info.st_mode)
            or lock_info.st_uid != expected_owner_uid
            or lock_info.st_nlink != 1
            or stat.S_IMODE(lock_info.st_mode) != 0o600
        ):
            raise ManagedPreserveExecutionError("preserve lock is unsafe")
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        record = _read(operations_root / f"{operation_id}.json", expected_owner_uid)
        current = registry.load(deployment_id)
        if (
            record is None or record.state != "COMPLETE"
            or record.operation_id != operation_id
            or record.deployment_id != deployment_id
            or record.component != component
            or record.instance_id != instance_id
            or review_fingerprint is not None
                and record.review_fingerprint != review_fingerprint
            or record.receipt_digest is None
            or record.registry_revision is None
            or current is None or current.schema != MANAGED_DEPLOYMENT_SCHEMA_V3
            or current.revision != record.registry_revision
            or current.active_by_component.get(component) is not None
            or current.composition_binding is None
            or current.composition_binding.composition_id != composition_id
            or current.composition_binding.manifest_digest != manifest_digest
        ):
            raise ManagedPreserveExecutionError("terminal preserve evidence is stale")
        preserved = current.preserved_by_component.get(component)
        if (
            preserved is None or preserved.instance_id != instance_id
            or preserved.preserve_operation_id != operation_id
            or preserved.preserve_receipt_digest != record.receipt_digest
        ):
            raise ManagedPreserveExecutionError("terminal preserve registry receipt changed")
        return record
    finally:
        os.close(lock)


def read_terminal_purge_evidence(
    *, operations_root: Path, registry: ManagedDeploymentRegistry,
    deployment_id: str, operation_id: str, component: str, instance_id: str,
    review_fingerprint: str, expected_registry_revision: int,
    composition_id: str, manifest_digest: str, expected_owner_uid: int = 0,
) -> ManagedPreserveExecutionRecord:
    """Observe one exact committed PURGE even when its deployment is gone.

    The caller must already hold the original reviewed identity. This read-only
    check never grants mutation authority or reconstructs a missing review.
    """
    if (
        not isinstance(operations_root, Path) or not operations_root.is_absolute()
        or not isinstance(registry, ManagedDeploymentRegistry)
        or any(not isinstance(value, str) or _ID.fullmatch(value) is None for value in (
            deployment_id, operation_id, instance_id, composition_id,
        ))
        or component not in {FORGE_COMPONENT, EP_COMPONENT}
        or not isinstance(review_fingerprint, str)
        or _DIGEST.fullmatch(review_fingerprint) is None
        or isinstance(expected_registry_revision, bool)
        or not isinstance(expected_registry_revision, int)
        or expected_registry_revision < 1
        or not isinstance(manifest_digest, str)
        or _DIGEST.fullmatch(manifest_digest) is None
        or isinstance(expected_owner_uid, bool)
        or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0
    ):
        raise ManagedPreserveExecutionError("terminal purge selector is invalid")
    try:
        root_info = os.lstat(operations_root)
        if (
            not stat.S_ISDIR(root_info.st_mode)
            or root_info.st_uid != expected_owner_uid
            or stat.S_IMODE(root_info.st_mode) != 0o700
        ):
            raise ManagedPreserveExecutionError("purge journal root is unsafe")
        lock = os.open(
            operations_root / f".{deployment_id}.lock", os.O_RDWR | os.O_NOFOLLOW,
        )
    except (FileNotFoundError, OSError) as error:
        raise ManagedPreserveExecutionError("terminal purge evidence is unavailable") from error
    try:
        lock_info = os.fstat(lock)
        if (
            not stat.S_ISREG(lock_info.st_mode)
            or lock_info.st_uid != expected_owner_uid
            or lock_info.st_nlink != 1
            or stat.S_IMODE(lock_info.st_mode) != 0o600
        ):
            raise ManagedPreserveExecutionError("purge lock is unsafe")
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        record = _read(operations_root / f"{operation_id}.json", expected_owner_uid)
        registry_info = os.lstat(registry.root)
        if (
            not stat.S_ISDIR(registry_info.st_mode)
            or registry_info.st_uid != expected_owner_uid
            or stat.S_IMODE(registry_info.st_mode) != 0o700
        ):
            raise ManagedPreserveExecutionError("purge registry root is unsafe")
        registry_lock = os.open(
            registry.root / ".registry.lock", os.O_RDWR | os.O_NOFOLLOW,
        )
        try:
            registry_lock_info = os.fstat(registry_lock)
            if (
                not stat.S_ISREG(registry_lock_info.st_mode)
                or registry_lock_info.st_uid != expected_owner_uid
                or registry_lock_info.st_nlink != 1
                or stat.S_IMODE(registry_lock_info.st_mode) != 0o600
            ):
                raise ManagedPreserveExecutionError("purge registry lock is unsafe")
            fcntl.flock(registry_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            current = registry.load(deployment_id)
            inventory = registry.inventory()
        finally:
            os.close(registry_lock)
        if (
            record is None or record.state != "COMPLETE"
            or record.operation_id != operation_id
            or record.deployment_id != deployment_id
            or record.component != component
            or record.instance_id != instance_id
            or record.review_fingerprint != review_fingerprint
            or record.receipt_digest is None
            or record.registry_revision != expected_registry_revision
            or current is not None and (
                current.schema not in {
                    MANAGED_DEPLOYMENT_SCHEMA_V2, MANAGED_DEPLOYMENT_SCHEMA_V3,
                }
                or current.revision != expected_registry_revision
                or current.composition_binding is None
                or current.composition_binding.composition_id != composition_id
                or current.composition_binding.manifest_digest != manifest_digest
                or current.peer_binding is not None
                or getattr(current, "historical_peer_binding", None) is not None
                or current.active_by_component.get(component) is not None
                or current.preserved_by_component.get(component) is not None
            )
            or any(
                binding.instance_id == instance_id
                for deployment in inventory
                for binding in deployment.components
                    + getattr(deployment, "preserved_components", ())
            )
        ):
            raise ManagedPreserveExecutionError("terminal purge evidence is stale")
        return record
    finally:
        os.close(lock)


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

    @staticmethod
    def _require_pairing_proof(
        current: ManagedDeployment, review: ManagedPreservedLifecycleReview,
        proof: PairingRevocationRecord | None,
    ) -> None:
        peer = current.peer_binding or getattr(current, "historical_peer_binding", None)
        if peer is None:
            if proof is not None:
                raise ManagedPreserveExecutionError("unpaired preserve carried pairing authority")
            return
        if (
            review.component != FORGE_COMPONENT
            or proof is None or proof.state != "COMPLETE"
            or proof.operation_id != review.operation_id
            or proof.deployment_id != review.deployment_id
            or proof.reviewed_deployment_fingerprint != review.registry_fingerprint
            or proof.forge_instance_id != review.instance_id
            or proof.ep_instance_id != peer.ep_instance_id
            or peer.forge_instance_id != review.instance_id
            or peer.receipt_reference != review.historical_peer_reference
            or not isinstance(proof.receipt_reference, str)
            or re.fullmatch(r"ep-consumer-revoke:sha256:[0-9a-f]{64}", proof.receipt_reference) is None
            or current.peer_binding is None
                and current.preserved_by_component.get(FORGE_COMPONENT) is None
        ):
            raise ManagedPreserveExecutionError(
                "paired preserve lacks exact product-owned consumer revocation"
            )

    def preserve(
        self, review: ManagedPreservedLifecycleReview, *,
        installed_manifest: CompositionManifest, adapter: PreservedProductAdapter,
        pairing_revocation: PairingRevocationRecord | None = None,
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
        current = self.registry.load(review.deployment_id)
        if current is None:
            raise ManagedPreserveExecutionError("reviewed preserve deployment is unavailable")
        self._require_pairing_proof(current, review, pairing_revocation)
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
            return self._locked_preserve(
                path, review, installed_manifest, adapter, pairing_revocation,
            )
        finally:
            os.close(lock)

    def _locked_preserve(
        self, path: Path, review: ManagedPreservedLifecycleReview,
        manifest: CompositionManifest, adapter: PreservedProductAdapter,
        pairing_revocation: PairingRevocationRecord | None,
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
        self._require_pairing_proof(current, review, pairing_revocation)
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
            adapter.require_terminal_preserve_status(
                operation_id=review.operation_id,
                receipt_digest=existing.receipt_digest,
            )
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


class ManagedPurgeExecutionCoordinator(ManagedPreserveExecutionCoordinator):
    """Resume one exact product-owned PURGE without deleting product data here."""

    def purge(
        self, review: ManagedPreservedLifecycleReview, *,
        installed_manifest: CompositionManifest, adapter: PreservedProductAdapter,
        pairing_revocation: PairingRevocationRecord | None = None,
    ) -> ManagedPreserveExecutionRecord:
        if (
            not isinstance(review, ManagedPreservedLifecycleReview)
            or review.operation != "PURGE"
            or review.destructive_confirmation_required is not True
            or not isinstance(review.operation_id, str)
            or _ID.fullmatch(review.operation_id) is None
            or not isinstance(review.deployment_id, str)
            or _ID.fullmatch(review.deployment_id) is None
            or review.component not in {FORGE_COMPONENT, EP_COMPONENT}
            or not isinstance(installed_manifest, CompositionManifest)
            or (installed_manifest.composition_id, installed_manifest.manifest_digest)
                != (review.composition_id, review.composition_digest)
            or not frozen_preserved_release(review.component, review.artifact)
            or [item.artifact for item in installed_manifest.components
                if item.identity == review.component] != [review.artifact]
            or getattr(getattr(adapter, "target", None), "instance_id", None) != review.instance_id
            or review.component == FORGE_COMPONENT and (
                self.forge_supervisor is None
                or not isinstance(adapter, ForgePreservedProductAdapter)
                or not isinstance(adapter.target, ForgeServerTarget)
            )
            or review.component == EP_COMPONENT and not isinstance(adapter, EPPreservedProductAdapter)
        ):
            raise ManagedPreserveExecutionError("purge product target is not sealed")
        root = self.operations_root
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = os.lstat(root)
        if (
            not stat.S_ISDIR(info.st_mode) or info.st_uid != self.expected_owner_uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise ManagedPreserveExecutionError("purge journal root is unsafe")
        path = root / f"{review.operation_id}.json"
        lock_path = root / f".{review.deployment_id}.lock"
        lock = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(lock)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedPreserveExecutionError("purge lock is unsafe")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self._locked_purge(
                path, review, installed_manifest, adapter, pairing_revocation,
            )
        finally:
            os.close(lock)

    def _locked_purge(
        self, path: Path, review: ManagedPreservedLifecycleReview,
        manifest: CompositionManifest, adapter: PreservedProductAdapter,
        pairing_revocation: PairingRevocationRecord | None,
    ) -> ManagedPreserveExecutionRecord:
        intended = ManagedPreserveExecutionRecord(
            review.operation_id, review.deployment_id, review.review_fingerprint,
            review.component, review.instance_id, "PREPARED", None, None,
        )
        existing = _read(path, self.expected_owner_uid)
        if existing is not None and replace(
            existing, state="PREPARED", receipt_digest=None, registry_revision=None,
        ) != intended:
            raise ManagedPreserveExecutionError("purge operation identity changed")
        current = self.registry.load(review.deployment_id)
        if current is not None and current.peer_binding is not None:
            self._require_pairing_proof(current, review, pairing_revocation)
        elif current is not None and getattr(current, "historical_peer_binding", None) is not None:
            peer = current.historical_peer_binding
            preserved = current.preserved_by_component.get(FORGE_COMPONENT)
            if (
                review.component != FORGE_COMPONENT
                or preserved is None
                or preserved.instance_id != review.instance_id
                or preserved.preserve_operation_id != review.preserve_operation_id
                or preserved.preserve_receipt_digest != review.preserve_receipt_digest
                or peer.receipt_reference != review.historical_peer_reference
                or pairing_revocation is None
                or pairing_revocation.state != "COMPLETE"
                or pairing_revocation.operation_id != review.preserve_operation_id
                or pairing_revocation.deployment_id != review.deployment_id
                or pairing_revocation.forge_instance_id != review.instance_id
                or pairing_revocation.ep_instance_id != peer.ep_instance_id
                or not isinstance(pairing_revocation.receipt_reference, str)
                or re.fullmatch(
                    r"ep-consumer-revoke:sha256:[0-9a-f]{64}",
                    pairing_revocation.receipt_reference,
                ) is None
                or sum(
                    pairing_revocation.reviewed_deployment_fingerprint ==
                        "sha256:" + sha256(json.dumps(
                            asdict(original), sort_keys=True, separators=(",", ":"),
                            allow_nan=False,
                        ).encode("utf-8")).hexdigest()
                    and pairing_revocation.plan_fingerprint ==
                        "sha256:" + sha256(json.dumps(
                            asdict(ManagedDeploymentPlanner.plan(
                                original, replace(
                                    original,
                                    components=(original.active_by_component[EP_COMPONENT],),
                                    peer_binding=None,
                                ),
                            )), sort_keys=True, separators=(",", ":"),
                            allow_nan=False,
                        ).encode("utf-8")).hexdigest()
                    for original in prior_paired_forge_candidates(current)
                ) != 1
            ):
                raise ManagedPreserveExecutionError("historical paired purge proof changed")
        elif review.historical_peer_reference is not None:
            if (
                current is None
                or getattr(current, "historical_peer_binding", None) is not None
                or pairing_revocation is None
                or pairing_revocation.state != "COMPLETE"
                or pairing_revocation.operation_id != (
                    review.preserve_operation_id or review.operation_id
                )
                or pairing_revocation.deployment_id != review.deployment_id
                or review.preserve_operation_id is None and
                    pairing_revocation.reviewed_deployment_fingerprint != review.registry_fingerprint
                or pairing_revocation.forge_instance_id != review.instance_id
                or current.active_by_component.get(EP_COMPONENT) is None
                or current.active_by_component[EP_COMPONENT].instance_id != pairing_revocation.ep_instance_id
            ):
                raise ManagedPreserveExecutionError("paired purge replay lost EP proof")
        elif pairing_revocation is not None:
            raise ManagedPreserveExecutionError("unpaired purge carried pairing proof")
        if current is None or review.component not in (
            set(current.active_by_component) | set(current.preserved_by_component)
        ):
            if (
                existing is None or existing.state not in {"COMMITTING", "COMPLETE"}
                or existing.receipt_digest is None
                or existing.registry_revision != review.registry_revision + 1
                or current is not None and (
                    current.revision != existing.registry_revision
                    or current.composition_binding is None
                    or (current.composition_binding.composition_id,
                        current.composition_binding.manifest_digest)
                        != (review.composition_id, review.composition_digest)
                    or current.peer_binding is not None
                    or getattr(current, "historical_peer_binding", None) is not None
                )
                or any(
                    binding.component == review.component
                    and binding.instance_id == review.instance_id
                    for deployment in self.registry.inventory()
                    for binding in deployment.components
                        + getattr(deployment, "preserved_components", ())
                )
                or review.component == FORGE_COMPONENT
                    and self.forge_supervisor.loaded(adapter.target)
            ):
                raise ManagedPreserveExecutionError("purge replay lacks exact terminal inventory")
            complete = replace(existing, state="COMPLETE")
            adapter.require_terminal_purge_status(
                review, receipt_digest=existing.receipt_digest,
            )
            _write(path, complete)
            return complete
        if existing is not None and existing.state == "COMPLETE":
            raise ManagedPreserveExecutionError("completed purge regained its inventory")
        self._current(review, manifest)
        if existing is None:
            _write(path, intended)
        if review.component == FORGE_COMPONENT:
            self._purge_currency(review)
            self._current(review, manifest)
            self.forge_supervisor.stop(adapter.target)
            if self.forge_supervisor.loaded(adapter.target):
                raise ManagedPreserveExecutionError("Forge service remains loaded during purge")
        self._purge_currency(review)
        self._current(review, manifest)
        evidence = adapter.invoke(review, registry=self.registry, installed_manifest=manifest)
        if (
            evidence.terminal.component != review.component
            or evidence.terminal.operation != "PURGE"
            or evidence.terminal.operation_id != review.operation_id
            or evidence.terminal.instance_id != review.instance_id
            or evidence.terminal.lifecycle_state != "PURGED"
            or existing is not None and existing.receipt_digest is not None
                and existing.receipt_digest != evidence.terminal.receipt_digest
        ):
            raise ManagedPreserveExecutionError("owning purge evidence changed")
        record = replace(
            intended, state="PRODUCT_TERMINAL",
            receipt_digest=evidence.terminal.receipt_digest,
        )
        _write(path, record)
        if review.component == FORGE_COMPONENT:
            self._purge_currency(review)
            self._current(review, manifest)
            if self.forge_supervisor.loaded(adapter.target):
                raise ManagedPreserveExecutionError("Forge service restarted during purge")
            self.forge_supervisor.remove(adapter.target)
            if self.forge_supervisor.loaded(adapter.target):
                raise ManagedPreserveExecutionError("Forge service remains after purge")
        record = replace(record, state="SERVICE_REMOVED")
        _write(path, record)
        self._purge_currency(review)
        self._current(review, manifest)
        committing = replace(
            record, state="COMMITTING", registry_revision=review.registry_revision + 1,
        )
        _write(path, committing)
        committed = self.registry.commit_purged(
            deployment_id=review.deployment_id,
            expected_revision=review.registry_revision,
            component=review.component, instance_id=review.instance_id,
            operation_id=review.operation_id, artifact=review.artifact,
            installed_manifest=manifest,
            request_digest=evidence.receipt["request_digest"],
            receipt=evidence.receipt, status=evidence.status,
            pairing_revocation=pairing_revocation,
        )
        if committed is not None and committed.revision != committing.registry_revision:
            raise ManagedPreserveExecutionError("purge registry revision changed")
        complete = replace(committing, state="COMPLETE")
        _write(path, complete)
        return complete

    def _purge_currency(self, review: ManagedPreservedLifecycleReview) -> None:
        self.currency_guard.require_current(
            deployment_id=review.deployment_id, mutation="PURGE",
            component=review.component, instance_id=review.instance_id,
            operation_id=review.operation_id,
        )
