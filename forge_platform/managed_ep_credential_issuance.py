"""Durable helper-owned recovery around EP's non-idempotent credential issue.

Only non-secret product metadata is journaled. A lost response leaves PREPARED;
replay revokes every uncertain credential on the exact new consumer before one
new issue. The injected secure store is the sole destination for plaintext.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
import fcntl
from hashlib import sha256
import hmac
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Mapping, Protocol

from .ep_consumer_registration import EPConsumerRegistrationAdapter
from .ep_consumer_revocation import EPConsumerScope
from .ep_credential_recovery import EPCredentialRecoveryAdapter
from .managed_deployments import ManagedDeployment, ManagedDeploymentRegistry
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, InstallerMutationCurrencyGuard


_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_CREDENTIAL = re.compile(r"^production-[0-9a-f]{32}$")
_FINGERPRINT = re.compile(r"^[0-9a-f]{64}$")
_REFERENCE = re.compile(r"^keychain://[A-Za-z0-9._-]{1,128}/[A-Za-z0-9._-]{1,128}$")
_MAX_JOURNAL = 16 * 1024
_EP_FINGERPRINT_DOMAIN = b"engineering-platform.local-api.fingerprint.v1\0"


class ManagedEPCredentialIssuanceError(RuntimeError):
    """The exact new EP credential cannot be issued or recovered safely."""


class SecureCredentialStore(Protocol):
    """Native helper-owned secure store; no material in paths or diagnostics."""

    def clear_owned(self, reference: str, operation_id: str) -> None: ...

    def put_verified(self, reference: str, operation_id: str, material: str) -> bool: ...

    def fingerprint(self, reference: str, operation_id: str) -> str | None: ...


@dataclass(frozen=True)
class EPCredentialIssueRecord:
    operation_id: str
    deployment_id: str
    forge_instance_id: str
    ep_instance_id: str
    old_consumer_id: str
    new_consumer_id: str
    project_id: str
    credential_reference: str
    reviewed_fingerprint: str
    baseline_credential_ids: tuple[str, ...]
    state: str
    credential_id: str | None
    credential_fingerprint: str | None
    created_at: str | None


def _read(path: Path, owner_uid: int) -> EPCredentialIssueRecord | None:
    if not os.path.lexists(path):
        return None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode) or before.st_uid != owner_uid
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600
                or not 0 < before.st_size <= _MAX_JOURNAL
            ):
                raise ValueError("unsafe journal")
            raw = os.read(descriptor, _MAX_JOURNAL + 1)
            after = os.fstat(descriptor)
            if len(raw) != before.st_size or (
                before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
            ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError("journal changed")
        finally:
            os.close(descriptor)
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != set(EPCredentialIssueRecord.__dataclass_fields__):
            raise ValueError("journal fields")
        if not isinstance(value["baseline_credential_ids"], list):
            raise ValueError("journal baseline")
        value["baseline_credential_ids"] = tuple(value["baseline_credential_ids"])
        record = EPCredentialIssueRecord(**value)
        if (
            any(not isinstance(item, str) or _ID.fullmatch(item) is None for item in (
                record.operation_id, record.deployment_id, record.forge_instance_id,
                record.ep_instance_id, record.old_consumer_id, record.new_consumer_id,
                record.project_id,
            ))
            or not isinstance(record.credential_reference, str)
            or _REFERENCE.fullmatch(record.credential_reference) is None
            or not isinstance(record.reviewed_fingerprint, str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", record.reviewed_fingerprint) is None
            or any(not isinstance(item, str) or _CREDENTIAL.fullmatch(item) is None
                   for item in record.baseline_credential_ids)
            or len(set(record.baseline_credential_ids)) != len(record.baseline_credential_ids)
            or len(record.baseline_credential_ids) > 64
            or record.state not in {"PREPARED", "COMPLETE"}
            or record.state == "PREPARED" and any(item is not None for item in (
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
        raise ManagedEPCredentialIssuanceError("EP credential journal is invalid") from error


def _write(path: Path, record: EPCredentialIssueRecord) -> None:
    encoded = (json.dumps(
        asdict(record), sort_keys=True, separators=(",", ":"),
    ) + "\n").encode("utf-8")
    if len(encoded) > _MAX_JOURNAL:
        raise ManagedEPCredentialIssuanceError("EP credential journal exceeds its bound")
    descriptor, temporary = tempfile.mkstemp(prefix=".ep-credential-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
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


def _deployment_fingerprint(deployment: ManagedDeployment) -> str:
    return "sha256:" + sha256(json.dumps(
        asdict(deployment), sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode()).hexdigest()


class ManagedEPCredentialIssuanceCoordinator:
    """Resume one exact product issue with a secret-free durable journal."""

    def __init__(
        self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        registration: EPConsumerRegistrationAdapter,
        recovery: EPCredentialRecoveryAdapter, store: SecureCredentialStore,
        scope_claims: Mapping[str, EPConsumerScope],
        reference_claims: Mapping[str, str],
        expected_owner_uid: int = 0,
    ) -> None:
        if not isinstance(operations_root, Path) or not operations_root.is_absolute():
            raise ValueError("EP credential journal root must be absolute")
        if (
            not isinstance(registry, ManagedDeploymentRegistry)
            or not callable(getattr(currency_guard, "require_current", None))
            or not isinstance(registration, EPConsumerRegistrationAdapter)
            or not isinstance(recovery, EPCredentialRecoveryAdapter)
            or recovery.consumer is not registration.new
        ):
            raise TypeError("exact EP credential product authority is required")
        if (
            isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int)
            or expected_owner_uid < 0
        ):
            raise ValueError("EP credential journal owner is invalid")
        if not all(callable(getattr(store, name, None)) for name in (
            "clear_owned", "put_verified", "fingerprint",
        )):
            raise TypeError("native secure credential store is required")
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
            raise ValueError("EP credential scopes and secure references are not exclusively owned")
        self.operations_root = operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.registration = registration
        self.recovery = recovery
        self.store = store
        self.scope_claims = scopes
        self.reference_claims = references
        self.expected_owner_uid = expected_owner_uid

    def issue(
        self, *, operation_id: str, reviewed_current: ManagedDeployment,
        reviewed_fingerprint: str, credential_reference: str,
    ) -> EPCredentialIssueRecord:
        peer = getattr(reviewed_current, "peer_binding", None)
        old = self.registration.old.scope
        new = self.registration.new.scope
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(reviewed_current, ManagedDeployment) or peer is None
            or not isinstance(reviewed_fingerprint, str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", reviewed_fingerprint) is None
            or reviewed_fingerprint != _deployment_fingerprint(reviewed_current)
            or not isinstance(credential_reference, str)
            or _REFERENCE.fullmatch(credential_reference) is None
            or peer.ep_instance_id != self.registration.new.provisioner.target.instance_id
            or reviewed_current.by_component[FORGE_COMPONENT].instance_id != peer.forge_instance_id
            or reviewed_current.by_component[EP_COMPONENT].instance_id != peer.ep_instance_id
            or old.consumer_id == new.consumer_id or old.project_id != new.project_id
            or self.scope_claims.get(reviewed_current.deployment_id) != new
            or self.reference_claims.get(reviewed_current.deployment_id) != credential_reference
        ):
            raise ManagedEPCredentialIssuanceError("reviewed EP credential target changed")
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root = os.lstat(self.operations_root)
        if (
            not stat.S_ISDIR(root.st_mode) or root.st_uid != self.expected_owner_uid
            or stat.S_IMODE(root.st_mode) != 0o700
        ):
            raise ManagedEPCredentialIssuanceError("EP credential journal root is unsafe")
        lock = self.operations_root / f".{operation_id}.lock"
        descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedEPCredentialIssuanceError("EP credential journal lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = self.operations_root / f"{operation_id}.json"
            existing = _read(path, self.expected_owner_uid)
            if self.registry.load(reviewed_current.deployment_id) != reviewed_current:
                raise ManagedEPCredentialIssuanceError("reviewed deployment changed")
            if existing is None:
                self.currency_guard.require_current(
                    deployment_id=reviewed_current.deployment_id,
                    mutation="ep-consumer-register", component=EP_COMPONENT,
                    instance_id=peer.ep_instance_id, operation_id=operation_id,
                )
                if self.registry.load(reviewed_current.deployment_id) != reviewed_current:
                    raise ManagedEPCredentialIssuanceError("reviewed deployment changed before registration")
                self.registration.register()
                baseline = self.recovery.status()
                if len(baseline) > 64 or any(item.active for item in baseline):
                    raise ManagedEPCredentialIssuanceError("new EP consumer credential history is unsafe")
                intended = EPCredentialIssueRecord(
                    operation_id, reviewed_current.deployment_id,
                    peer.forge_instance_id, peer.ep_instance_id,
                    old.consumer_id, new.consumer_id, new.project_id,
                    credential_reference, reviewed_fingerprint,
                    tuple(item.credential_id for item in baseline),
                    "PREPARED", None, None, None,
                )
                try:
                    occupied = self.store.fingerprint(credential_reference, operation_id)
                except Exception:
                    raise ManagedEPCredentialIssuanceError("secure reference status is unavailable") from None
                if occupied is not None:
                    raise ManagedEPCredentialIssuanceError("new secure reference is already occupied")
                _write(path, intended)
            else:
                old_status = self.registration.old.status()
                new_status = self.registration.new.status()
                if (
                    old_status.get("status") != "REVOKED"
                    or not old_status.get("revoked_at")
                    or new_status.get("status") != "ACTIVE"
                    or new_status.get("consumer_id") != new.consumer_id
                    or new_status.get("project_id") != new.project_id
                ):
                    raise ManagedEPCredentialIssuanceError("EP consumer scope changed during issue recovery")
                intended = replace(
                    existing, state="PREPARED", credential_id=None,
                    credential_fingerprint=None, created_at=None,
                )
                if (
                    intended.operation_id != operation_id
                    or intended.deployment_id != reviewed_current.deployment_id
                    or intended.forge_instance_id != peer.forge_instance_id
                    or intended.ep_instance_id != peer.ep_instance_id
                    or intended.old_consumer_id != old.consumer_id
                    or intended.new_consumer_id != new.consumer_id
                    or intended.project_id != new.project_id
                    or intended.credential_reference != credential_reference
                    or intended.reviewed_fingerprint != reviewed_fingerprint
                ):
                    raise ManagedEPCredentialIssuanceError("EP credential operation identity changed")
                if existing.state == "COMPLETE":
                    self._check_complete(existing)
                    return existing
            self._require_current(intended)
            try:
                self.store.clear_owned(credential_reference, operation_id)
            except Exception:
                raise ManagedEPCredentialIssuanceError("owned secure reference cleanup failed") from None
            self._recover_uncertain(intended)
            self._require_current(intended)
            try:
                disclosure = self.registration.new._command("credential-issue")
            except Exception:
                raise ManagedEPCredentialIssuanceError("EP credential issue response is unavailable") from None
            try:
                if (
                    not isinstance(disclosure, dict)
                    or set(disclosure) != {
                        "credential_id", "consumer_id", "project_id", "purpose",
                        "created_at", "credential",
                    }
                    or disclosure.get("consumer_id") != new.consumer_id
                    or disclosure.get("project_id") != new.project_id
                    or disclosure.get("purpose") != "PRODUCTION_CONSUMER"
                    or not isinstance(disclosure.get("credential_id"), str)
                    or _CREDENTIAL.fullmatch(disclosure["credential_id"]) is None
                    or not isinstance(disclosure.get("created_at"), str)
                    or not disclosure["created_at"]
                    or not isinstance(disclosure.get("credential"), str)
                    or not 32 <= len(disclosure["credential"]) <= 256
                    or re.fullmatch(r"[A-Za-z0-9_-]+", disclosure["credential"]) is None
                ):
                    raise ValueError("invalid disclosure")
                credential_id = disclosure["credential_id"]
                material = disclosure["credential"]
                fingerprint = sha256(_EP_FINGERPRINT_DOMAIN + material.encode("ascii")).hexdigest()
                observed = self.recovery.status()
                candidate = next((item for item in observed if item.credential_id == credential_id), None)
                if (
                    candidate is None or not candidate.active
                    or candidate.fingerprint != fingerprint
                    or candidate.created_at != disclosure["created_at"]
                    or sum(item.active for item in observed) != 1
                    or any(item.active and item.credential_id not in intended.baseline_credential_ids
                           and item.credential_id != credential_id for item in observed)
                ):
                    raise ValueError("product issue readback changed")
                if not self.store.put_verified(credential_reference, operation_id, material):
                    raise ValueError("secure store did not verify the credential")
                if not hmac.compare_digest(
                    self.store.fingerprint(credential_reference, operation_id) or "", fingerprint,
                ):
                    raise ValueError("secure store readback changed")
                completed = replace(
                    intended, state="COMPLETE", credential_id=credential_id,
                    credential_fingerprint=fingerprint, created_at=candidate.created_at,
                )
                _write(path, completed)
                return completed
            except Exception:
                raise ManagedEPCredentialIssuanceError("EP credential issue lacks terminal secure readback") from None
        finally:
            os.close(descriptor)

    def read_terminal(
        self, *, operation_id: str, reviewed_current: ManagedDeployment,
        credential_reference: str,
    ) -> EPCredentialIssueRecord:
        """Revalidate product and secure-store evidence after registry commit."""
        peer = getattr(reviewed_current, "peer_binding", None)
        old = self.registration.old.scope
        new = self.registration.new.scope
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(reviewed_current, ManagedDeployment) or peer is None
            or not isinstance(credential_reference, str)
            or _REFERENCE.fullmatch(credential_reference) is None
            or self.scope_claims.get(reviewed_current.deployment_id) != new
            or self.reference_claims.get(reviewed_current.deployment_id) != credential_reference
            or old.consumer_id == new.consumer_id or old.project_id != new.project_id
        ):
            raise ManagedEPCredentialIssuanceError("terminal EP credential selector changed")
        try:
            root = os.lstat(self.operations_root)
            if (
                not stat.S_ISDIR(root.st_mode) or root.st_uid != self.expected_owner_uid
                or stat.S_IMODE(root.st_mode) != 0o700
            ):
                raise ValueError("unsafe root")
            descriptor = os.open(
                self.operations_root / f".{operation_id}.lock", os.O_RDONLY | os.O_NOFOLLOW,
            )
        except (OSError, ValueError) as error:
            raise ManagedEPCredentialIssuanceError("terminal EP credential is unavailable") from error
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedEPCredentialIssuanceError("terminal EP credential lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            record = _read(self.operations_root / f"{operation_id}.json", self.expected_owner_uid)
            if (
                record is None or record.state != "COMPLETE"
                or record.operation_id != operation_id
                or record.deployment_id != reviewed_current.deployment_id
                or record.forge_instance_id != peer.forge_instance_id
                or record.ep_instance_id != peer.ep_instance_id
                or record.old_consumer_id != old.consumer_id
                or record.new_consumer_id != new.consumer_id
                or record.project_id != new.project_id
                or record.credential_reference != credential_reference
                or record.reviewed_fingerprint != _deployment_fingerprint(reviewed_current)
            ):
                raise ManagedEPCredentialIssuanceError("terminal EP credential identity changed")
            old_status = self.registration.old.status()
            new_status = self.registration.new.status()
            if (
                old_status.get("status") != "REVOKED" or not old_status.get("revoked_at")
                or new_status.get("status") != "ACTIVE"
                or new_status.get("consumer_id") != new.consumer_id
                or new_status.get("project_id") != new.project_id
            ):
                raise ManagedEPCredentialIssuanceError("terminal EP consumer status changed")
            self._check_complete(record)
            return record
        finally:
            os.close(descriptor)

    def _require_current(self, record: EPCredentialIssueRecord) -> None:
        deployment = self.registry.load(record.deployment_id)
        if (
            deployment is None
            or _deployment_fingerprint(deployment) != record.reviewed_fingerprint
            or deployment.peer_binding is None
            or deployment.peer_binding.forge_instance_id != record.forge_instance_id
            or deployment.peer_binding.ep_instance_id != record.ep_instance_id
        ):
            raise ManagedEPCredentialIssuanceError("reviewed deployment changed before credential mutation")
        self.currency_guard.require_current(
            deployment_id=record.deployment_id, mutation="ep-credential-issue",
            component=EP_COMPONENT, instance_id=record.ep_instance_id,
            operation_id=record.operation_id,
        )

    def _recover_uncertain(self, record: EPCredentialIssueRecord) -> None:
        observed = self.recovery.status()
        baseline = set(record.baseline_credential_ids)
        if not baseline.issubset({item.credential_id for item in observed}):
            raise ManagedEPCredentialIssuanceError("baseline EP credential history changed")
        if any(item.credential_id in baseline and item.active for item in observed):
            raise ManagedEPCredentialIssuanceError("baseline EP credential unexpectedly became active")
        for item in observed:
            if item.credential_id not in baseline and item.active:
                self._require_current(record)
                self.recovery.revoke_exact(item.credential_id)
        if any(item.active for item in self.recovery.status()):
            raise ManagedEPCredentialIssuanceError("uncertain EP credential remains active")

    def _check_complete(self, record: EPCredentialIssueRecord) -> None:
        observed = self.recovery.status()
        try:
            stored_fingerprint = self.store.fingerprint(
                record.credential_reference, record.operation_id,
            )
        except Exception:
            raise ManagedEPCredentialIssuanceError("terminal secure reference is unavailable") from None
        if (
            len([item for item in observed if item.active]) != 1
            or not any(
                item.credential_id == record.credential_id and item.active
                and item.fingerprint == record.credential_fingerprint
                and item.created_at == record.created_at
                for item in observed
            )
            or not hmac.compare_digest(
                stored_fingerprint or "",
                record.credential_fingerprint or "",
            )
        ):
            raise ManagedEPCredentialIssuanceError("terminal EP credential or secure store changed")
