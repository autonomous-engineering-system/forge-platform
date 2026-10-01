"""Durable first EP consumer credential before a managed Forge↔EP pairing.

EP owns registration, issue, status and revoke. The signed helper owns the
secure store. This journal contains only exact target and product metadata;
it is written before either non-idempotent product mutation can begin.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import fcntl
from hashlib import sha256
import hmac
import json
import os
from pathlib import Path
import re
import stat
from typing import Mapping

from .ep_consumer_registration import (
    EPConsumerRegistrationError, EPInitialConsumerRegistrationAdapter,
)
from .ep_consumer_revocation import EPConsumerScope
from .ep_credential_recovery import EPCredentialRecoveryAdapter
from .managed_deployments import ManagedDeployment, ManagedDeploymentRegistry
from .managed_ep_credential_issuance import (
    SecureCredentialStore, _CREDENTIAL, _EP_FINGERPRINT_DOMAIN,
    _FINGERPRINT, _ID, _MAX_JOURNAL, _REFERENCE, _deployment_fingerprint, _write,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, InstallerMutationCurrencyGuard


class ManagedEPInitialCredentialError(RuntimeError):
    """The exact initial product credential cannot be proven safely."""


@dataclass(frozen=True)
class EPInitialCredentialRecord:
    operation_id: str
    deployment_id: str
    forge_instance_id: str
    ep_instance_id: str
    consumer_id: str
    project_id: str
    credential_reference: str
    reviewed_fingerprint: str
    state: str
    registration_reference: str | None
    baseline_credential_ids: tuple[str, ...]
    credential_id: str | None
    credential_fingerprint: str | None
    created_at: str | None


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate journal field")
        value[key] = item
    return value


def _read(path: Path, owner_uid: int) -> EPInitialCredentialRecord | None:
    if not os.path.lexists(path):
        return None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
                or not 0 < info.st_size <= _MAX_JOURNAL
            ):
                raise ValueError("unsafe journal")
            raw = os.read(descriptor, _MAX_JOURNAL + 1)
            if len(raw) != info.st_size or os.fstat(descriptor).st_mtime_ns != info.st_mtime_ns:
                raise ValueError("journal changed")
        finally:
            os.close(descriptor)
        value = json.loads(raw, object_pairs_hook=_strict_object)
        if not isinstance(value, dict) or set(value) != set(EPInitialCredentialRecord.__dataclass_fields__):
            raise ValueError("journal fields")
        if not isinstance(value["baseline_credential_ids"], list):
            raise ValueError("journal baseline")
        value["baseline_credential_ids"] = tuple(value["baseline_credential_ids"])
        record = EPInitialCredentialRecord(**value)
        if (
            any(not isinstance(item, str) or _ID.fullmatch(item) is None for item in (
                record.operation_id, record.deployment_id, record.forge_instance_id,
                record.ep_instance_id, record.consumer_id, record.project_id,
            ))
            or not isinstance(record.credential_reference, str)
            or _REFERENCE.fullmatch(record.credential_reference) is None
            or not isinstance(record.reviewed_fingerprint, str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", record.reviewed_fingerprint) is None
            or record.state not in {"PREPARED", "REGISTERED", "COMPLETE", "BLOCKED"}
            or not isinstance(record.baseline_credential_ids, tuple)
            or len(record.baseline_credential_ids) > 64
            or len(set(record.baseline_credential_ids)) != len(record.baseline_credential_ids)
            or any(not isinstance(item, str) or _CREDENTIAL.fullmatch(item) is None
                   for item in record.baseline_credential_ids)
            or record.state in {"PREPARED", "BLOCKED"} and (
                record.registration_reference is not None or record.baseline_credential_ids
            )
            or record.state in {"REGISTERED", "COMPLETE"} and (
                not isinstance(record.registration_reference, str)
                or re.fullmatch(r"ep-consumer-register:sha256:[0-9a-f]{64}", record.registration_reference) is None
            )
            or record.state != "COMPLETE" and any(item is not None for item in (
                record.credential_id, record.credential_fingerprint, record.created_at,
            ))
            or record.state == "COMPLETE" and (
                not isinstance(record.credential_id, str)
                or _CREDENTIAL.fullmatch(record.credential_id) is None
                or not isinstance(record.credential_fingerprint, str)
                or _FINGERPRINT.fullmatch(record.credential_fingerprint) is None
                or not isinstance(record.created_at, str) or not record.created_at
            )
        ):
            raise ValueError("journal identity")
        return record
    except (OSError, ValueError, TypeError) as error:
        raise ManagedEPInitialCredentialError("initial EP credential journal is invalid") from error


class ManagedEPInitialCredentialCoordinator:
    """Issue once, or revoke an uncertain disclosure and resume the exact ID."""

    def __init__(
        self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        registration: EPInitialConsumerRegistrationAdapter,
        recovery: EPCredentialRecoveryAdapter, store: SecureCredentialStore,
        scope_claims: Mapping[str, EPConsumerScope],
        reference_claims: Mapping[str, str], expected_owner_uid: int = 0,
    ) -> None:
        if (
            not isinstance(operations_root, Path) or not operations_root.is_absolute()
            or not isinstance(registry, ManagedDeploymentRegistry)
            or not callable(getattr(currency_guard, "require_current", None))
            or not isinstance(registration, EPInitialConsumerRegistrationAdapter)
            or not isinstance(recovery, EPCredentialRecoveryAdapter)
            or recovery.consumer is not registration.consumer
            or not all(callable(getattr(store, name, None)) for name in (
                "clear_owned", "put_verified", "fingerprint",
            ))
            or isinstance(expected_owner_uid, bool)
            or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0
        ):
            raise TypeError("exact initial EP credential authority is required")
        scopes = dict(scope_claims)
        references = dict(reference_claims)
        if (
            not scopes or set(scopes) != set(references)
            or any(not isinstance(key, str) or _ID.fullmatch(key) is None
                   or not isinstance(value, EPConsumerScope)
                   for key, value in scopes.items())
            or len(set(scopes.values())) != len(scopes)
            or any(not isinstance(value, str) or _REFERENCE.fullmatch(value) is None
                   for value in references.values())
            or len(set(references.values())) != len(references)
        ):
            raise ValueError("initial EP scope and secure reference claims are ambiguous")
        self.operations_root = operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.registration = registration
        self.recovery = recovery
        self.store = store
        self.scope_claims = scopes
        self.reference_claims = references
        self.expected_owner_uid = expected_owner_uid

    def _root(self) -> None:
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        info = os.lstat(self.operations_root)
        if (
            not stat.S_ISDIR(info.st_mode) or info.st_uid != self.expected_owner_uid
            or stat.S_IMODE(info.st_mode) != 0o700
        ):
            raise ManagedEPInitialCredentialError("initial EP journal root is unsafe")

    def _lock(self, identity: str, *, kind: str) -> int:
        descriptor = os.open(
            self.operations_root / f".{kind}-{identity}.lock",
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600,
        )
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
        ):
            os.close(descriptor)
            raise ManagedEPInitialCredentialError("initial EP journal lock is unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(descriptor)
            raise ManagedEPInitialCredentialError("initial EP credential operation is busy") from None
        return descriptor

    def _deployment_record(self, deployment_id: str) -> EPInitialCredentialRecord | None:
        matches: list[EPInitialCredentialRecord] = []
        count = 0
        for path in self.operations_root.iterdir():
            if not path.name.endswith(".json"):
                continue
            count += 1
            if count > 256:
                raise ManagedEPInitialCredentialError("initial EP journal inventory is unbounded")
            record = _read(path, self.expected_owner_uid)
            if record is not None and record.deployment_id == deployment_id:
                matches.append(record)
                if len(matches) > 1:
                    raise ManagedEPInitialCredentialError("initial EP deployment has ambiguous operations")
        return matches[0] if matches else None

    def _currency(self, record: EPInitialCredentialRecord, mutation: str) -> None:
        self.currency_guard.require_current(
            deployment_id=record.deployment_id, mutation=mutation,
            component=EP_COMPONENT, instance_id=record.ep_instance_id,
            operation_id=record.operation_id,
        )
        current = self.registry.load(record.deployment_id)
        if current is None or _deployment_fingerprint(current) != record.reviewed_fingerprint:
            raise ManagedEPInitialCredentialError("reviewed deployment changed before EP mutation")

    def _target(
        self, operation_id: str, current: ManagedDeployment,
        fingerprint: str, reference: str,
    ) -> EPInitialCredentialRecord:
        if not isinstance(current, ManagedDeployment):
            raise ManagedEPInitialCredentialError("reviewed initial EP target changed")
        consumer = self.registration.consumer
        forge = current.by_component.get(FORGE_COMPONENT)
        ep = current.by_component.get(EP_COMPONENT)
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or current.peer_binding is not None
            or forge is None or ep is None
            or ep.instance_id != consumer.provisioner.target.instance_id
            or not isinstance(fingerprint, str)
            or fingerprint != _deployment_fingerprint(current)
            or not isinstance(reference, str) or _REFERENCE.fullmatch(reference) is None
            or self.scope_claims.get(current.deployment_id) != consumer.scope
            or self.reference_claims.get(current.deployment_id) != reference
        ):
            raise ManagedEPInitialCredentialError("reviewed initial EP target changed")
        return EPInitialCredentialRecord(
            operation_id, current.deployment_id, forge.instance_id, ep.instance_id,
            consumer.scope.consumer_id, consumer.scope.project_id, reference,
            fingerprint, "PREPARED", None, (), None, None, None,
        )

    def issue(
        self, *, operation_id: str, reviewed_current: ManagedDeployment,
        reviewed_fingerprint: str, credential_reference: str,
    ) -> EPInitialCredentialRecord:
        intended = self._target(
            operation_id, reviewed_current, reviewed_fingerprint, credential_reference,
        )
        self._root()
        deployment_lock = self._lock(intended.deployment_id, kind="deployment")
        try:
            descriptor = self._lock(operation_id, kind="operation")
        except Exception:
            os.close(deployment_lock)
            raise
        try:
            path = self.operations_root / f"{operation_id}.json"
            claimed = self._deployment_record(intended.deployment_id)
            if claimed is not None and claimed.operation_id != operation_id:
                raise ManagedEPInitialCredentialError("initial EP deployment belongs to another operation")
            existing = _read(path, self.expected_owner_uid)
            if existing is not None and replace(
                existing, state="PREPARED", registration_reference=None,
                baseline_credential_ids=(), credential_id=None,
                credential_fingerprint=None, created_at=None,
            ) != intended:
                raise ManagedEPInitialCredentialError("initial EP operation identity changed")
            if existing is not None and existing.state == "BLOCKED":
                raise ManagedEPInitialCredentialError("initial EP registration is blocked")
            if existing is not None and existing.state == "COMPLETE":
                if self.registry.load(existing.deployment_id) != reviewed_current:
                    raise ManagedEPInitialCredentialError("reviewed deployment changed")
                self._check_complete(existing)
                return existing
            self._currency(intended, "ep-initial-credential-prepare")
            if existing is None:
                try:
                    occupied = self.store.fingerprint(credential_reference, operation_id)
                except Exception:
                    raise ManagedEPInitialCredentialError("initial secure reference is unavailable") from None
                if occupied is not None:
                    raise ManagedEPInitialCredentialError("initial secure reference is occupied")
                _write(path, intended)
            if existing is None or existing.state == "PREPARED":
                self._currency(intended, "ep-consumer-register")
                try:
                    registration_reference = self.registration.register(recovering=existing is not None)
                except EPConsumerRegistrationError:
                    _write(path, replace(intended, state="BLOCKED"))
                    raise ManagedEPInitialCredentialError("initial EP registration receipt is unsafe") from None
                except Exception:
                    raise ManagedEPInitialCredentialError("initial EP registration response is unavailable") from None
                baseline = self.recovery.status()
                if len(baseline) > 64 or any(item.active for item in baseline):
                    raise ManagedEPInitialCredentialError("initial EP credential history is unsafe")
                existing = replace(
                    intended, state="REGISTERED",
                    registration_reference=registration_reference,
                    baseline_credential_ids=tuple(item.credential_id for item in baseline),
                )
                _write(path, existing)
            assert existing is not None
            self._registered(existing)
            self._currency(existing, "ep-initial-credential-recovery")
            try:
                self.store.clear_owned(credential_reference, operation_id)
            except Exception:
                raise ManagedEPInitialCredentialError("initial secure reference cleanup failed") from None
            self._recover_uncertain(existing)
            self._currency(existing, "ep-credential-issue")
            try:
                disclosure = self.registration.consumer._command("credential-issue")
            except Exception:
                raise ManagedEPInitialCredentialError("initial EP credential response is unavailable") from None
            try:
                if (
                    not isinstance(disclosure, dict)
                    or set(disclosure) != {
                        "credential_id", "consumer_id", "project_id", "purpose",
                        "created_at", "credential",
                    }
                    or disclosure.get("consumer_id") != existing.consumer_id
                    or disclosure.get("project_id") != existing.project_id
                    or disclosure.get("purpose") != "PRODUCTION_CONSUMER"
                    or not isinstance(disclosure.get("credential_id"), str)
                    or _CREDENTIAL.fullmatch(disclosure["credential_id"]) is None
                    or not isinstance(disclosure.get("created_at"), str)
                    or not disclosure["created_at"]
                    or not isinstance(disclosure.get("credential"), str)
                    or re.fullmatch(r"[A-Za-z0-9_-]{32,256}", disclosure["credential"]) is None
                ):
                    raise ValueError("invalid EP disclosure")
                material = disclosure["credential"]
                fingerprint = sha256(_EP_FINGERPRINT_DOMAIN + material.encode("ascii")).hexdigest()
                observed = self.recovery.status()
                selected = next((item for item in observed if item.credential_id == disclosure["credential_id"]), None)
                if (
                    selected is None or not selected.active
                    or selected.fingerprint != fingerprint
                    or selected.created_at != disclosure["created_at"]
                    or sum(item.active for item in observed) != 1
                ):
                    raise ValueError("EP issue readback changed")
                if not self.store.put_verified(credential_reference, operation_id, material):
                    raise ValueError("secure store did not verify")
                if not hmac.compare_digest(
                    self.store.fingerprint(credential_reference, operation_id) or "", fingerprint,
                ):
                    raise ValueError("secure store readback changed")
                complete = replace(
                    existing, state="COMPLETE", credential_id=selected.credential_id,
                    credential_fingerprint=fingerprint, created_at=selected.created_at,
                )
                _write(path, complete)
                return complete
            except Exception:
                raise ManagedEPInitialCredentialError("initial EP credential lacks terminal secure readback") from None
        finally:
            os.close(descriptor)
            os.close(deployment_lock)

    def ensure(
        self, *, operation_id: str, reviewed_current: ManagedDeployment,
        reviewed_fingerprint: str, credential_reference: str,
    ) -> EPInitialCredentialRecord:
        """Reuse one terminal exact consumer or resume the same prepared operation."""
        intended = self._target(
            operation_id, reviewed_current, reviewed_fingerprint, credential_reference,
        )
        self._root()
        existing = self._deployment_record(intended.deployment_id)
        if existing is not None and existing.operation_id != operation_id:
            if existing.state != "COMPLETE":
                raise ManagedEPInitialCredentialError("initial EP deployment belongs to another operation")
            return self.read_terminal(operation_id=None, deployment=reviewed_current)
        return self.issue(
            operation_id=operation_id, reviewed_current=reviewed_current,
            reviewed_fingerprint=reviewed_fingerprint,
            credential_reference=credential_reference,
        )

    def _registered(self, record: EPInitialCredentialRecord) -> None:
        status = self.registration.consumer.status()
        if (
            status.get("status") != "ACTIVE"
            or status.get("consumer_id") != record.consumer_id
            or status.get("project_id") != record.project_id
            or status.get("disabled_at") is not None
            or status.get("revoked_at") is not None
        ):
            raise ManagedEPInitialCredentialError("initial EP consumer changed")

    def _recover_uncertain(self, record: EPInitialCredentialRecord) -> None:
        observed = self.recovery.status()
        baseline = set(record.baseline_credential_ids)
        if not baseline.issubset({item.credential_id for item in observed}):
            raise ManagedEPInitialCredentialError("initial EP baseline history changed")
        if any(item.credential_id in baseline and item.active for item in observed):
            raise ManagedEPInitialCredentialError("initial EP baseline credential became active")
        for item in observed:
            if item.credential_id not in baseline and item.active:
                self._currency(record, "ep-credential-revoke-uncertain")
                self.recovery.revoke_exact(item.credential_id)
        if any(item.active for item in self.recovery.status()):
            raise ManagedEPInitialCredentialError("uncertain EP credential remains active")

    def _check_complete(self, record: EPInitialCredentialRecord) -> None:
        self._registered(record)
        observed = self.recovery.status()
        try:
            stored = self.store.fingerprint(record.credential_reference, record.operation_id)
        except Exception:
            raise ManagedEPInitialCredentialError("terminal secure reference is unavailable") from None
        if (
            sum(item.active for item in observed) != 1
            or not any(
                item.credential_id == record.credential_id and item.active
                and item.fingerprint == record.credential_fingerprint
                and item.created_at == record.created_at for item in observed
            )
            or not hmac.compare_digest(stored or "", record.credential_fingerprint or "")
        ):
            raise ManagedEPInitialCredentialError("terminal initial EP credential changed")

    def read_terminal(self, *, operation_id: str | None, deployment: ManagedDeployment) -> EPInitialCredentialRecord:
        if operation_id is not None and (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
        ):
            raise ManagedEPInitialCredentialError("initial EP operation identity is invalid")
        if not isinstance(deployment, ManagedDeployment):
            raise ManagedEPInitialCredentialError("initial EP deployment is invalid")
        self._root()
        deployment_lock = self._lock(deployment.deployment_id, kind="deployment")
        try:
            if operation_id is None:
                selected = self._deployment_record(deployment.deployment_id)
                if selected is None:
                    raise ManagedEPInitialCredentialError("terminal initial EP credential is unavailable")
                operation_id = selected.operation_id
            descriptor = self._lock(operation_id, kind="operation")
        except Exception:
            os.close(deployment_lock)
            raise
        try:
            record = _read(self.operations_root / f"{operation_id}.json", self.expected_owner_uid)
            if (
                record is None or record.state != "COMPLETE"
                or record.deployment_id != deployment.deployment_id
                or deployment.by_component.get(FORGE_COMPONENT) is None
                or deployment.by_component[FORGE_COMPONENT].instance_id != record.forge_instance_id
                or deployment.by_component.get(EP_COMPONENT) is None
                or deployment.by_component[EP_COMPONENT].instance_id != record.ep_instance_id
                or deployment.peer_binding is not None and (
                    deployment.peer_binding.forge_instance_id != record.forge_instance_id
                    or deployment.peer_binding.ep_instance_id != record.ep_instance_id
                )
                or self.scope_claims.get(deployment.deployment_id) != EPConsumerScope(
                    record.consumer_id, record.project_id,
                )
                or self.reference_claims.get(deployment.deployment_id) != record.credential_reference
            ):
                raise ManagedEPInitialCredentialError("terminal initial EP target changed")
            self._check_complete(record)
            return record
        finally:
            os.close(descriptor)
            os.close(deployment_lock)
