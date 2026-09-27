"""Durable EP pairing-consumer revocation before paired Forge removal.

This stage never removes a product or changes the deployment registry. It
records the reviewed exact target before invoking EP's idempotent product-owned
consumer-revoke boundary, then records its terminal independent readback.
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
from typing import Mapping, Protocol

from .ep_consumer_revocation import EPConsumerScope
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, InstallerMutationCurrencyGuard


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_RECEIPT = re.compile(r"^ep-consumer-revoke:sha256:[0-9a-f]{64}$")
_MAX_JOURNAL_BYTES = 16 * 1024


class ManagedPairingRevocationError(RuntimeError):
    """The selected pairing cannot be safely revoked or resumed."""


class EPConsumerRevoker(Protocol):
    scope: EPConsumerScope
    provisioner: object

    def revoke(self) -> str: ...
    def status(self) -> Mapping[str, object]: ...


@dataclass(frozen=True)
class PairingRevocationRecord:
    operation_id: str
    deployment_id: str
    plan_fingerprint: str
    reviewed_deployment_fingerprint: str
    forge_instance_id: str
    ep_instance_id: str
    consumer_id: str
    project_id: str
    state: str
    receipt_reference: str | None


class ManagedPairingRevocationCoordinator:
    """One helper-owned EP consumer scope and exact reviewed deployment."""

    def __init__(
        self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        scope_claims: Mapping[str, EPConsumerScope],
        expected_owner_uid: int = 0,
    ) -> None:
        if not isinstance(operations_root, Path) or not operations_root.is_absolute():
            raise ValueError("pairing revocation journal root must be absolute")
        claims = dict(scope_claims)
        if not claims or any(
            not isinstance(key, str) or _OPERATION_ID.fullmatch(key) is None
            or not isinstance(value, EPConsumerScope)
            for key, value in claims.items()
        ) or len(set(claims.values())) != len(claims):
            raise ValueError("EP consumer scopes are not exclusively owned")
        if isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0:
            raise ValueError("pairing revocation journal owner is invalid")
        self.operations_root = operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.scope_claims = claims
        self.expected_owner_uid = expected_owner_uid

    def revoke(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment, revoker: EPConsumerRevoker,
    ) -> PairingRevocationRecord:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise ManagedPairingRevocationError("pairing revocation operation id is invalid")
        if not isinstance(plan, ManagedDeploymentPlan) or not isinstance(reviewed_current, ManagedDeployment):
            raise ManagedPairingRevocationError("reviewed paired removal is invalid")
        peer = reviewed_current.peer_binding
        if (
            peer is None or reviewed_current.deployment_id != plan.deployment_id
            or reviewed_current.revision != plan.current_revision
            or ManagedDeploymentPlanner.plan(reviewed_current, plan.desired) != plan
            or plan.deployment_action not in {"CREATE_OR_UPDATE", "REMOVE_DEPLOYMENT"}
            or not any(
                diff.component == FORGE_COMPONENT and diff.action == "REMOVE_COMPONENT"
                and diff.instance_id == peer.forge_instance_id
                for diff in plan.component_diffs
            )
            or plan.desired is not None and (
                plan.desired.peer_binding is not None
                or FORGE_COMPONENT in plan.desired.by_component
            )
            or any(
                diff.action != (
                    "REMOVE_COMPONENT" if diff.component == FORGE_COMPONENT else
                    "REMOVE_COMPONENT" if plan.desired is None else "NO_CHANGE"
                )
                for diff in plan.component_diffs
            )
            or set(diff.component for diff in plan.component_diffs)
            != {FORGE_COMPONENT, EP_COMPONENT}
            or self.scope_claims.get(plan.deployment_id) != getattr(revoker, "scope", None)
            or getattr(getattr(revoker, "provisioner", None), "target", None) is None
            or revoker.provisioner.target.instance_id != peer.ep_instance_id
        ):
            raise ManagedPairingRevocationError("paired removal target or scope changed")
        fingerprint = _digest(asdict(plan))
        reviewed_fingerprint = _digest(asdict(reviewed_current))
        intended = PairingRevocationRecord(
            operation_id, plan.deployment_id, fingerprint, reviewed_fingerprint,
            peer.forge_instance_id, peer.ep_instance_id,
            revoker.scope.consumer_id, revoker.scope.project_id, "PREPARED", None,
        )
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root_stat = os.lstat(self.operations_root)
        if (
            not stat.S_ISDIR(root_stat.st_mode)
            or root_stat.st_uid != self.expected_owner_uid
            or stat.S_IMODE(root_stat.st_mode) != 0o700
        ):
            raise ManagedPairingRevocationError("pairing revocation journal root is unsafe")
        path = self.operations_root / f"{operation_id}.json"
        lock = self.operations_root / f".{operation_id}.lock"
        descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            lock_stat = os.fstat(descriptor)
            if (
                not stat.S_ISREG(lock_stat.st_mode)
                or lock_stat.st_uid != self.expected_owner_uid
                or lock_stat.st_nlink != 1
                or stat.S_IMODE(lock_stat.st_mode) != 0o600
            ):
                raise ManagedPairingRevocationError("pairing revocation lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            existing = _read(path, owner_uid=self.expected_owner_uid)
            if existing is not None and (
                replace(existing, state="PREPARED", receipt_reference=None) != intended
            ):
                raise ManagedPairingRevocationError("pairing revocation operation identity changed")
            if self.registry.load(plan.deployment_id) != reviewed_current or (
                reviewed_current not in self.registry.inventory()
            ):
                raise ManagedPairingRevocationError("reviewed paired deployment changed")
            if existing is not None and existing.state == "COMPLETE":
                observed = revoker.status()
                if (
                    observed.get("consumer_id") != intended.consumer_id
                    or observed.get("project_id") != intended.project_id
                    or observed.get("status") != "REVOKED"
                    or not observed.get("revoked_at")
                    or revoker.revoke() != existing.receipt_reference
                ):
                    raise ManagedPairingRevocationError("terminal EP consumer readback changed")
                return existing
            if existing is None:
                _write(path, intended)
            self.currency_guard.require_current(
                deployment_id=plan.deployment_id,
                mutation="pairing-consumer-revoke",
                component="engineering-platform-server",
                instance_id=peer.ep_instance_id,
                operation_id=operation_id,
            )
            if self.registry.load(plan.deployment_id) != reviewed_current:
                raise ManagedPairingRevocationError("reviewed paired deployment changed before mutation")
            receipt = revoker.revoke()
            if not isinstance(receipt, str) or _RECEIPT.fullmatch(receipt) is None:
                raise ManagedPairingRevocationError("EP consumer terminal receipt is invalid")
            observed = revoker.status()
            if (
                observed.get("consumer_id") != intended.consumer_id
                or observed.get("project_id") != intended.project_id
                or observed.get("status") != "REVOKED"
                or not observed.get("revoked_at")
            ):
                raise ManagedPairingRevocationError("EP consumer terminal readback is invalid")
            completed = replace(intended, state="COMPLETE", receipt_reference=receipt)
            _write(path, completed)
            return completed
        finally:
            os.close(descriptor)


def _digest(value: object) -> str:
    return "sha256:" + sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    ).hexdigest()


def _read(path: Path, *, owner_uid: int) -> PairingRevocationRecord | None:
    if not os.path.lexists(path):
        return None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != owner_uid
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= _MAX_JOURNAL_BYTES
            ):
                raise ManagedPairingRevocationError("pairing revocation journal is unsafe")
            raw = os.read(descriptor, _MAX_JOURNAL_BYTES + 1)
            after = os.fstat(descriptor)
            if (
                len(raw) != info.st_size
                or (info.st_dev, info.st_ino, info.st_size)
                != (after.st_dev, after.st_ino, after.st_size)
            ):
                raise ManagedPairingRevocationError("pairing revocation journal changed while read")
        finally:
            os.close(descriptor)
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != set(PairingRevocationRecord.__dataclass_fields__):
            raise ValueError("fields")
        record = PairingRevocationRecord(**value)
        if record.state not in {"PREPARED", "COMPLETE"} or (
            record.state == "COMPLETE" and (
                not isinstance(record.receipt_reference, str)
                or _RECEIPT.fullmatch(record.receipt_reference) is None
            )
        ) or (record.state == "PREPARED" and record.receipt_reference is not None):
            raise ValueError("state")
        return record
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        raise ManagedPairingRevocationError("pairing revocation journal is invalid") from error


def _write(path: Path, record: PairingRevocationRecord) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".pairing-revoke-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(asdict(record), stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
