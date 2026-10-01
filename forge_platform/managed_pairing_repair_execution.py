"""Durable helper-owned Forge peer replacement after exact EP credential issue.

The product owns configure, preflight and readiness. A PREPARED journal is
written before configure; a lost response is recovered by product readback,
never by repeating an ambiguous configure. Registry commit is a later stage.
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

from .component_operations import ComponentOperationRequest
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding, ForgeEPProductPairingExecutor,
)
from .forge_server_adapter import ForgeServerProductAdapter
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, InstallerMutationCurrencyGuard
from .managed_pairing_detach import ManagedPairingRepairDetachCoordinator
from .managed_pairing_repair_credential import ManagedPairingRepairCredentialCoordinator
from .managed_pairing_revocation import EPConsumerRevoker


_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_MAX_RECORD = 16 * 1024


class ManagedPairingRepairExecutionError(RuntimeError):
    """The exact reviewed product replacement cannot safely advance."""


@dataclass(frozen=True)
class PairingRepairExecutionRecord:
    operation_id: str
    deployment_id: str
    plan_fingerprint: str
    reviewed_fingerprint: str
    old_binding_fingerprint: str
    new_binding_fingerprint: str
    credential_id: str
    credential_fingerprint: str
    detach_product_operation_id: str
    detach_revision: int
    detach_configuration_digest: str
    detach_receipt_digest: str
    state: str
    forge_configuration_reference: str | None
    forge_preflight_reference: str | None
    ep_readiness_reference: str | None


def _digest(value: object) -> str:
    return "sha256:" + sha256(json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode()).hexdigest()


def _read(path: Path, owner_uid: int) -> PairingRepairExecutionRecord | None:
    if not os.path.lexists(path):
        return None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode) or before.st_uid != owner_uid
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600
                or not 0 < before.st_size <= _MAX_RECORD
            ):
                raise ValueError("unsafe record")
            raw = os.read(descriptor, _MAX_RECORD + 1)
            after = os.fstat(descriptor)
            if len(raw) != before.st_size or (
                before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
            ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError("record changed")
        finally:
            os.close(descriptor)
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != set(PairingRepairExecutionRecord.__dataclass_fields__):
            raise ValueError("record fields")
        record = PairingRepairExecutionRecord(**value)
        if (
            any(not isinstance(item, str) or _ID.fullmatch(item) is None for item in (
                record.operation_id, record.deployment_id,
                record.credential_id, record.detach_product_operation_id,
            ))
            or any(not isinstance(item, str) or _DIGEST.fullmatch(item) is None
                   for item in (
                       record.plan_fingerprint, record.reviewed_fingerprint,
                       record.old_binding_fingerprint, record.new_binding_fingerprint,
                       record.detach_configuration_digest,
                       record.detach_receipt_digest,
                   ))
            or not isinstance(record.credential_fingerprint, str)
            or re.fullmatch(r"[0-9a-f]{64}", record.credential_fingerprint) is None
            or isinstance(record.detach_revision, bool)
            or not isinstance(record.detach_revision, int) or record.detach_revision < 1
            or record.state not in {"PREPARED", "COMPLETE"}
            or record.state == "PREPARED" and any(item is not None for item in (
                record.forge_configuration_reference, record.forge_preflight_reference,
                record.ep_readiness_reference,
            ))
            or record.state == "COMPLETE" and any(
                not isinstance(item, str) or not item
                for item in (
                    record.forge_configuration_reference, record.forge_preflight_reference,
                    record.ep_readiness_reference,
                )
            )
        ):
            raise ValueError("record identity")
        return record
    except (OSError, ValueError, TypeError) as error:
        raise ManagedPairingRepairExecutionError("Forge repair journal is invalid") from error


def _write(path: Path, record: PairingRepairExecutionRecord) -> None:
    encoded = (json.dumps(asdict(record), sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(encoded) > _MAX_RECORD:
        raise ManagedPairingRepairExecutionError("Forge repair journal exceeds its bound")
    descriptor, temporary = tempfile.mkstemp(prefix=".pair-repair-", dir=path.parent)
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


class ManagedPairingRepairExecutionCoordinator:
    """One exact Forge replace, or product-read-only recovery of its lost reply."""

    def __init__(
        self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        credential: ManagedPairingRepairCredentialCoordinator,
        detach: ManagedPairingRepairDetachCoordinator,
        expected_owner_uid: int = 0,
    ) -> None:
        if (
            not isinstance(operations_root, Path) or not operations_root.is_absolute()
            or not isinstance(registry, ManagedDeploymentRegistry)
            or not callable(getattr(currency_guard, "require_current", None))
            or not isinstance(credential, ManagedPairingRepairCredentialCoordinator)
            or not isinstance(detach, ManagedPairingRepairDetachCoordinator)
            or credential.issuance.registry is not registry
            or credential.issuance.currency_guard is not currency_guard
            or detach.registry is not registry or detach.currency_guard is not currency_guard
            or operations_root in {
                credential.issuance.operations_root,
                credential.revocation.operations_root, detach.operations_root,
            }
            or isinstance(expected_owner_uid, bool)
            or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0
        ):
            raise TypeError("exact repair authorities and distinct durable journals are required")
        self.operations_root = operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.credential = credential
        self.detach = detach
        self.expected_owner_uid = expected_owner_uid

    def replace_peer(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment, old_binding: ForgeEPProductPairingBinding,
        new_binding: ForgeEPProductPairingBinding,
        revoker: EPConsumerRevoker, forge_adapter: ForgeServerProductAdapter,
        ep_adapter: EngineeringPlatformSystemProvisionerAdapter,
        forge_request: ComponentOperationRequest, ep_request: ComponentOperationRequest,
        credential_reference: str,
    ) -> PairingRepairExecutionRecord:
        desired = getattr(plan, "desired", None)
        peer = getattr(reviewed_current, "peer_binding", None)
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment) or peer is None
            or not isinstance(desired, ManagedDeployment)
            or not isinstance(old_binding, ForgeEPProductPairingBinding)
            or not isinstance(new_binding, ForgeEPProductPairingBinding)
            or not isinstance(forge_adapter, ForgeServerProductAdapter)
            or not isinstance(ep_adapter, EngineeringPlatformSystemProvisionerAdapter)
            or not isinstance(forge_request, ComponentOperationRequest)
            or not isinstance(ep_request, ComponentOperationRequest)
            or desired.deployment_id != reviewed_current.deployment_id
            or desired.revision != reviewed_current.revision + 1
            or desired.components != reviewed_current.components
            or desired.label != reviewed_current.label
            or desired.schema != reviewed_current.schema
            or desired.composition_binding != reviewed_current.composition_binding
            or desired.peer_binding is None or desired.peer_binding == peer
            or desired.peer_binding.forge_instance_id != peer.forge_instance_id
            or desired.peer_binding.ep_instance_id != peer.ep_instance_id
            or ManagedDeploymentPlanner.plan(
                reviewed_current, desired,
                product_actions={FORGE_COMPONENT: "REPAIR", EP_COMPONENT: "NO_CHANGE"},
            ) != plan
            or peer.forge_instance_id != forge_adapter.target.instance_id
            or peer.ep_instance_id != ep_adapter.target.instance_id
            or forge_request.installation_identity != peer.forge_instance_id
            or ep_request.installation_identity != peer.ep_instance_id
            or forge_request.component != FORGE_COMPONENT
            or ep_request.component != EP_COMPONENT
            or old_binding.expected_ep_instance_id != peer.ep_instance_id
            or new_binding.expected_ep_instance_id != peer.ep_instance_id
            or old_binding.binding_id == new_binding.binding_id
            or old_binding.consumer_id == new_binding.consumer_id
            or new_binding.credential_reference != credential_reference
        ):
            raise ManagedPairingRepairExecutionError("reviewed Forge repair target changed")
        issued = self.credential.issue_after_revoke(
            operation_id, plan, reviewed_current=reviewed_current,
            revoker=revoker, detach_coordinator=self.detach,
            forge_adapter=forge_adapter, old_binding=old_binding,
            credential_reference=credential_reference,
        )
        if (
            issued.state != "COMPLETE" or not issued.credential_id
            or not issued.credential_fingerprint
            or issued.operation_id != operation_id
            or issued.deployment_id != plan.deployment_id
            or issued.forge_instance_id != peer.forge_instance_id
            or issued.ep_instance_id != peer.ep_instance_id
            or issued.old_consumer_id != old_binding.consumer_id
            or issued.new_consumer_id != new_binding.consumer_id
            or issued.project_id != new_binding.project_id
            or issued.credential_reference != credential_reference
            or issued.reviewed_fingerprint != _digest(asdict(reviewed_current))
        ):
            raise ManagedPairingRepairExecutionError("new EP credential is not terminal")
        detached = self.detach.repair_detach(
            operation_id, plan, reviewed_current=reviewed_current,
            adapter=forge_adapter, old_binding=old_binding,
        )
        if detached.state != "COMPLETE" or not detached.receipt_digest:
            raise ManagedPairingRepairExecutionError("Forge detach is not terminal")
        intended = PairingRepairExecutionRecord(
            operation_id, plan.deployment_id, _digest(asdict(plan)),
            _digest(asdict(reviewed_current)), _digest(asdict(old_binding)),
            _digest(asdict(new_binding)), issued.credential_id,
            issued.credential_fingerprint, detached.product_operation_id,
            detached.configuration_revision, detached.configuration_digest,
            detached.receipt_digest, "PREPARED", None, None, None,
        )
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root = os.lstat(self.operations_root)
        if (
            not stat.S_ISDIR(root.st_mode) or root.st_uid != self.expected_owner_uid
            or stat.S_IMODE(root.st_mode) != 0o700
        ):
            raise ManagedPairingRepairExecutionError("Forge repair journal root is unsafe")
        descriptor = os.open(
            self.operations_root / f".{operation_id}.lock",
            os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600,
        )
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedPairingRepairExecutionError("Forge repair journal lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = self.operations_root / f"{operation_id}.json"
            existing = _read(path, self.expected_owner_uid)
            if existing is not None and replace(
                existing, state="PREPARED", forge_configuration_reference=None,
                forge_preflight_reference=None, ep_readiness_reference=None,
            ) != intended:
                raise ManagedPairingRepairExecutionError("Forge repair operation identity changed")
            if self.registry.load(plan.deployment_id) != reviewed_current:
                raise ManagedPairingRepairExecutionError("reviewed deployment changed")
            if existing is None:
                _write(path, intended)
            status = self._read_detach_status(
                forge_adapter, detached, old_binding,
            )
            if status["receipt"]["receipt_digest"] != detached.receipt_digest:
                raise ManagedPairingRepairExecutionError("Forge detach receipt changed")
            executor = ForgeEPProductPairingExecutor(new_binding)
            arguments = dict(
                operation_id=operation_id, deployment=reviewed_current,
                forge_request=forge_request, ep_request=ep_request,
                forge_adapter=forge_adapter, ep_adapter=ep_adapter,
                old_binding_id=old_binding.binding_id,
                old_consumer_id=old_binding.consumer_id,
                detach_operation_id=detached.product_operation_id,
                detach_revision=detached.configuration_revision,
                detach_configuration_digest=detached.configuration_digest,
                detach_operator_id=detached.operator_id,
            )
            if status["current_peer_status"] == "DETACHED":
                if existing is not None and existing.state == "COMPLETE":
                    raise ManagedPairingRepairExecutionError("completed Forge peer is no longer configured")
                self.currency_guard.require_current(
                    deployment_id=plan.deployment_id, mutation="forge-peer-replace",
                    component=FORGE_COMPONENT, instance_id=peer.forge_instance_id,
                    operation_id=operation_id,
                )
                if self.registry.load(plan.deployment_id) != reviewed_current:
                    raise ManagedPairingRepairExecutionError("reviewed deployment changed before Forge replace")
                evidence = executor.pair_after_product_detach(**arguments)
            elif status["current_peer_status"] == "CONFIGURED":
                evidence = executor.recover_after_product_replace(**arguments)
            else:
                raise ManagedPairingRepairExecutionError("Forge peer status is ambiguous")
            completed = replace(
                intended, state="COMPLETE",
                forge_configuration_reference=evidence.forge_configuration_reference,
                forge_preflight_reference=evidence.forge_preflight_reference,
                ep_readiness_reference=evidence.ep_readiness_reference,
            )
            if existing is not None and existing.state == "COMPLETE" and completed != existing:
                raise ManagedPairingRepairExecutionError("terminal Forge peer evidence changed")
            if existing is None or existing.state == "PREPARED":
                _write(path, completed)
            return completed
        finally:
            os.close(descriptor)

    def read_terminal(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment, old_binding: ForgeEPProductPairingBinding,
        new_binding: ForgeEPProductPairingBinding,
        forge_adapter: ForgeServerProductAdapter,
        ep_adapter: EngineeringPlatformSystemProvisionerAdapter,
        forge_request: ComponentOperationRequest, ep_request: ComponentOperationRequest,
    ) -> PairingRepairExecutionRecord:
        """Read terminal replacement after the registry has advanced, without mutation."""
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or not isinstance(old_binding, ForgeEPProductPairingBinding)
            or not isinstance(new_binding, ForgeEPProductPairingBinding)
            or not isinstance(forge_adapter, ForgeServerProductAdapter)
            or not isinstance(ep_adapter, EngineeringPlatformSystemProvisionerAdapter)
            or not isinstance(forge_request, ComponentOperationRequest)
            or not isinstance(ep_request, ComponentOperationRequest)
            or reviewed_current.peer_binding is None
        ):
            raise ManagedPairingRepairExecutionError("terminal Forge repair selector changed")
        issued = self.credential.issuance.read_terminal(
            operation_id=operation_id, reviewed_current=reviewed_current,
            credential_reference=new_binding.credential_reference,
        )
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
            raise ManagedPairingRepairExecutionError("terminal Forge repair is unavailable") from error
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedPairingRepairExecutionError("terminal Forge repair lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            record = _read(self.operations_root / f"{operation_id}.json", self.expected_owner_uid)
            if (
                record is None or record.state != "COMPLETE"
                or record.operation_id != operation_id
                or record.deployment_id != plan.deployment_id
                or record.plan_fingerprint != _digest(asdict(plan))
                or record.reviewed_fingerprint != _digest(asdict(reviewed_current))
                or record.old_binding_fingerprint != _digest(asdict(old_binding))
                or record.new_binding_fingerprint != _digest(asdict(new_binding))
                or record.credential_id != issued.credential_id
                or record.credential_fingerprint != issued.credential_fingerprint
                or record.detach_product_operation_id != "peer-repair-detach-" + sha256(
                    operation_id.encode(),
                ).hexdigest()[:40]
                or issued.new_consumer_id != new_binding.consumer_id
                or issued.old_consumer_id != old_binding.consumer_id
                or issued.ep_instance_id != new_binding.expected_ep_instance_id
                or issued.forge_instance_id != reviewed_current.peer_binding.forge_instance_id
            ):
                raise ManagedPairingRepairExecutionError("terminal Forge repair identity changed")
            detached_status = forge_adapter.read_historical_detach_ep_peer(
                operation_id=record.detach_product_operation_id,
                binding_id=old_binding.binding_id, revision=record.detach_revision,
                configuration_digest=record.detach_configuration_digest,
                operator_id=old_binding.operator_id,
            )
            if detached_status["receipt"]["receipt_digest"] != record.detach_receipt_digest:
                raise ManagedPairingRepairExecutionError("terminal Forge detach receipt changed")
            executor = ForgeEPProductPairingExecutor(new_binding)
            evidence = executor.recover_after_product_replace(
                operation_id=operation_id, deployment=reviewed_current,
                forge_request=forge_request, ep_request=ep_request,
                forge_adapter=forge_adapter, ep_adapter=ep_adapter,
                old_binding_id=old_binding.binding_id,
                old_consumer_id=old_binding.consumer_id,
                detach_operation_id=record.detach_product_operation_id,
                detach_revision=record.detach_revision,
                detach_configuration_digest=record.detach_configuration_digest,
                detach_operator_id=old_binding.operator_id,
            )
            if (
                evidence.forge_configuration_reference != record.forge_configuration_reference
                or evidence.forge_preflight_reference != record.forge_preflight_reference
                or evidence.ep_readiness_reference != record.ep_readiness_reference
            ):
                raise ManagedPairingRepairExecutionError("terminal Forge repair evidence changed")
            return record
        finally:
            os.close(descriptor)

    @staticmethod
    def _read_detach_status(
        adapter: ForgeServerProductAdapter, detached: object,
        old_binding: ForgeEPProductPairingBinding,
    ) -> dict[str, object]:
        kwargs = dict(
            operation_id=detached.product_operation_id,
            binding_id=old_binding.binding_id,
            revision=detached.configuration_revision,
            configuration_digest=detached.configuration_digest,
            operator_id=detached.operator_id,
        )
        try:
            return dict(adapter.read_detach_ep_peer(**kwargs))
        except Exception:
            return dict(adapter.read_historical_detach_ep_peer(**kwargs))
