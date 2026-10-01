"""Durable exact Forge-owned peer detach for a reviewed paired removal.

This stage has no registry or filesystem cleanup authority. Forge owns the
detach mutation and terminal status; the helper keeps only a secret-free
review/target journal so a lost response resumes the same product operation.
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

from .forge_ep_pairing_executor import ForgeEPProductPairingBinding
from .forge_server_adapter import ForgeServerProductAdapter
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, InstallerMutationCurrencyGuard
from .qualified_forge_lifecycle import qualified_forge_lifecycle_artifact


_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_MAX_RECORD = 16 * 1024


class ManagedPairingDetachError(RuntimeError):
    """The reviewed product detach cannot be safely started or resumed."""


@dataclass(frozen=True)
class PairingDetachRecord:
    operation_id: str
    product_operation_id: str
    deployment_id: str
    plan_fingerprint: str
    reviewed_fingerprint: str
    forge_instance_id: str
    ep_instance_id: str
    binding_id: str
    consumer_id: str
    operator_id: str
    configuration_revision: int
    configuration_digest: str
    state: str
    receipt_digest: str | None


def _digest(value: object) -> str:
    return "sha256:" + sha256(json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode()).hexdigest()


def _read(path: Path, *, owner_uid: int) -> PairingDetachRecord | None:
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
                raise ValueError("unsafe journal")
            raw = os.read(descriptor, _MAX_RECORD + 1)
            after = os.fstat(descriptor)
            if len(raw) != before.st_size or (
                before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
            ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError("journal changed")
        finally:
            os.close(descriptor)
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != set(PairingDetachRecord.__dataclass_fields__):
            raise ValueError("journal fields changed")
        record = PairingDetachRecord(**value)
        if (
            any(not isinstance(item, str) or _ID.fullmatch(item) is None for item in (
                record.operation_id, record.product_operation_id, record.deployment_id,
                record.forge_instance_id, record.ep_instance_id, record.binding_id,
                record.consumer_id, record.operator_id,
            ))
            or any(not isinstance(item, str) or _DIGEST.fullmatch(item) is None for item in (
                record.plan_fingerprint, record.reviewed_fingerprint,
                record.configuration_digest,
            ))
            or isinstance(record.configuration_revision, bool)
            or not isinstance(record.configuration_revision, int)
            or record.configuration_revision < 1
            or record.state not in {"PREPARED", "COMPLETE"}
            or record.state == "PREPARED" and record.receipt_digest is not None
            or record.state == "COMPLETE" and (
                not isinstance(record.receipt_digest, str)
                or _DIGEST.fullmatch(record.receipt_digest) is None
            )
        ):
            raise ValueError("journal identity changed")
        return record
    except (OSError, ValueError, TypeError) as error:
        raise ManagedPairingDetachError("Forge peer detach journal is invalid") from error


def _write(path: Path, record: PairingDetachRecord) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".forge-peer-detach-", dir=path.parent)
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


class ManagedPairingDetachCoordinator:
    """Resume one product-owned detach for one exact reviewed deployment."""

    def __init__(
        self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard, expected_owner_uid: int = 0,
    ) -> None:
        if not isinstance(operations_root, Path) or not operations_root.is_absolute():
            raise ValueError("Forge peer detach journal root must be absolute")
        if isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0:
            raise ValueError("Forge peer detach journal owner is invalid")
        self.operations_root = operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.expected_owner_uid = expected_owner_uid

    def read_terminal(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment,
        binding: ForgeEPProductPairingBinding,
    ) -> PairingDetachRecord:
        """Read the same validated detach after Forge's data root is uninstalled."""
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or not isinstance(binding, ForgeEPProductPairingBinding)
            or reviewed_current.peer_binding is None
        ):
            raise ManagedPairingDetachError("terminal Forge peer detach selector is invalid")
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
            raise ManagedPairingDetachError("terminal Forge peer detach is unavailable") from error
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedPairingDetachError("terminal Forge peer detach lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
            record = _read(
                self.operations_root / f"{operation_id}.json",
                owner_uid=self.expected_owner_uid,
            )
            peer = reviewed_current.peer_binding
            if (
                record is None or record.state != "COMPLETE"
                or record.operation_id != operation_id
                or record.product_operation_id != "peer-detach-" + sha256(operation_id.encode()).hexdigest()[:40]
                or record.deployment_id != plan.deployment_id
                or record.plan_fingerprint != _digest(asdict(plan))
                or record.reviewed_fingerprint != _digest(asdict(reviewed_current))
                or record.forge_instance_id != peer.forge_instance_id
                or record.ep_instance_id != peer.ep_instance_id
                or record.binding_id != binding.binding_id
                or record.consumer_id != binding.consumer_id
                or record.operator_id != binding.operator_id
            ):
                raise ManagedPairingDetachError("terminal Forge peer detach identity changed")
            return record
        finally:
            os.close(descriptor)


    def detach(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment,
        adapter: ForgeServerProductAdapter,
        binding: ForgeEPProductPairingBinding,
    ) -> PairingDetachRecord:
        peer = getattr(reviewed_current, "peer_binding", None)
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or peer is None or not isinstance(adapter, ForgeServerProductAdapter)
            or not isinstance(binding, ForgeEPProductPairingBinding)
            or plan.deployment_id != reviewed_current.deployment_id
            or plan.current_revision != reviewed_current.revision
            or plan.deployment_action not in {"CREATE_OR_UPDATE", "REMOVE_DEPLOYMENT"}
            or ManagedDeploymentPlanner.plan(reviewed_current, plan.desired) != plan
            or plan.desired is not None and (
                plan.desired.peer_binding is not None
                or FORGE_COMPONENT in plan.desired.by_component
            )
            or {diff.component: diff.action for diff in plan.component_diffs} != {
                FORGE_COMPONENT: "REMOVE_COMPONENT",
                EP_COMPONENT: "REMOVE_COMPONENT" if plan.desired is None else "NO_CHANGE",
            }
            or not any(
                diff.component == FORGE_COMPONENT and diff.action == "REMOVE_COMPONENT"
                and diff.instance_id == peer.forge_instance_id
                for diff in plan.component_diffs
            )
            or peer.forge_instance_id != adapter.target.instance_id
            or peer.ep_instance_id != binding.expected_ep_instance_id
            or not qualified_forge_lifecycle_artifact(adapter.installed_artifact)
            or adapter.installed_artifact.version != "2.7.39"
        ):
            raise ManagedPairingDetachError("reviewed Forge peer detach target changed")
        product_operation_id = "peer-detach-" + sha256(operation_id.encode()).hexdigest()[:40]
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root = os.lstat(self.operations_root)
        if (
            not stat.S_ISDIR(root.st_mode) or root.st_uid != self.expected_owner_uid
            or stat.S_IMODE(root.st_mode) != 0o700
        ):
            raise ManagedPairingDetachError("Forge peer detach journal root is unsafe")
        lock = self.operations_root / f".{operation_id}.lock"
        descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(info.st_mode) or info.st_uid != self.expected_owner_uid
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise ManagedPairingDetachError("Forge peer detach lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = self.operations_root / f"{operation_id}.json"
            existing = _read(path, owner_uid=self.expected_owner_uid)
            if existing is None:
                if self.registry.load(plan.deployment_id) != reviewed_current or (
                    reviewed_current not in self.registry.inventory()
                ):
                    raise ManagedPairingDetachError("reviewed deployment changed before detach")
                revision, digest = ForgeServerProductAdapter.read_peer_configuration_generation(
                    forge_executable=adapter.forge_executable, target=adapter.target,
                    installed_version=adapter.installed_artifact.version,
                    expected_binding_id=binding.binding_id,
                    expected_ep_consumer_id=binding.consumer_id,
                    runner=adapter.runner,
                )
                intended = PairingDetachRecord(
                    operation_id, product_operation_id, plan.deployment_id,
                    _digest(asdict(plan)), _digest(asdict(reviewed_current)),
                    peer.forge_instance_id, peer.ep_instance_id,
                    binding.binding_id, binding.consumer_id, binding.operator_id,
                    revision, digest, "PREPARED", None,
                )
                _write(path, intended)
            else:
                intended = replace(existing, state="PREPARED", receipt_digest=None)
                if (
                    intended.operation_id != operation_id
                    or intended.product_operation_id != product_operation_id
                    or intended.deployment_id != plan.deployment_id
                    or intended.plan_fingerprint != _digest(asdict(plan))
                    or intended.reviewed_fingerprint != _digest(asdict(reviewed_current))
                    or intended.forge_instance_id != peer.forge_instance_id
                    or intended.ep_instance_id != peer.ep_instance_id
                    or intended.binding_id != binding.binding_id
                    or intended.consumer_id != binding.consumer_id
                    or intended.operator_id != binding.operator_id
                ):
                    raise ManagedPairingDetachError("Forge peer detach operation identity changed")
            if self.registry.load(plan.deployment_id) != reviewed_current:
                raise ManagedPairingDetachError("reviewed deployment changed before detach")
            self.currency_guard.require_current(
                deployment_id=plan.deployment_id,
                mutation="forge-peer-detach",
                component=FORGE_COMPONENT,
                instance_id=peer.forge_instance_id,
                operation_id=operation_id,
            )
            if self.registry.load(plan.deployment_id) != reviewed_current:
                raise ManagedPairingDetachError("reviewed deployment changed before product detach")
            status = adapter.detach_ep_peer(
                operation_id=product_operation_id,
                binding_id=intended.binding_id,
                revision=intended.configuration_revision,
                configuration_digest=intended.configuration_digest,
                operator_id=intended.operator_id,
            )
            receipt_digest = status["receipt"]["receipt_digest"]
            if existing is not None and existing.state == "COMPLETE" and (
                receipt_digest != existing.receipt_digest
            ):
                raise ManagedPairingDetachError("terminal Forge peer detach changed")
            completed = replace(intended, state="COMPLETE", receipt_digest=receipt_digest)
            if existing is None or existing.state != "COMPLETE":
                _write(path, completed)
            return completed
        finally:
            os.close(descriptor)

class ManagedPairingRepairDetachCoordinator(ManagedPairingDetachCoordinator):
    """Durably detach the old peer for an exact reviewed same-instance REPAIR."""

    def repair_detach(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment,
        adapter: ForgeServerProductAdapter,
        old_binding: ForgeEPProductPairingBinding,
    ) -> PairingDetachRecord:
        peer = getattr(reviewed_current, "peer_binding", None)
        desired = getattr(plan, "desired", None)
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or peer is None or not isinstance(adapter, ForgeServerProductAdapter)
            or not isinstance(old_binding, ForgeEPProductPairingBinding)
            or desired is None or not isinstance(desired, ManagedDeployment)
            or desired.deployment_id != reviewed_current.deployment_id
            or desired.revision != reviewed_current.revision + 1
            or desired.schema != reviewed_current.schema
            or desired.components != reviewed_current.components
            or desired.label != reviewed_current.label
            or desired.composition_binding != reviewed_current.composition_binding
            or desired.peer_binding is None
            or desired.peer_binding == peer
            or desired.peer_binding.forge_instance_id != peer.forge_instance_id
            or desired.peer_binding.ep_instance_id != peer.ep_instance_id
            or plan.deployment_id != reviewed_current.deployment_id
            or plan.current_revision != reviewed_current.revision
            or plan.deployment_action != "CREATE_OR_UPDATE"
            or ManagedDeploymentPlanner.plan(
                reviewed_current, desired,
                product_actions={FORGE_COMPONENT: "REPAIR", EP_COMPONENT: "NO_CHANGE"},
            ) != plan
            or peer.forge_instance_id != adapter.target.instance_id
            or peer.ep_instance_id != old_binding.expected_ep_instance_id
            or not qualified_forge_lifecycle_artifact(adapter.installed_artifact)
            or adapter.installed_artifact.version != "2.7.39"
        ):
            raise ManagedPairingDetachError("reviewed Forge repair detach target changed")
        product_operation_id = "peer-repair-detach-" + sha256(operation_id.encode()).hexdigest()[:40]
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        root = os.lstat(self.operations_root)
        if (
            not stat.S_ISDIR(root.st_mode) or root.st_uid != self.expected_owner_uid
            or stat.S_IMODE(root.st_mode) != 0o700
        ):
            raise ManagedPairingDetachError("Forge repair detach journal root is unsafe")
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
                raise ManagedPairingDetachError("Forge repair detach lock is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = self.operations_root / f"{operation_id}.json"
            existing = _read(path, owner_uid=self.expected_owner_uid)
            if self.registry.load(plan.deployment_id) != reviewed_current or (
                reviewed_current not in self.registry.inventory()
            ):
                raise ManagedPairingDetachError("reviewed deployment changed before repair detach")
            if existing is None:
                revision, digest = ForgeServerProductAdapter.read_peer_configuration_generation(
                    forge_executable=adapter.forge_executable, target=adapter.target,
                    installed_version=adapter.installed_artifact.version,
                    expected_binding_id=old_binding.binding_id,
                    expected_ep_consumer_id=old_binding.consumer_id,
                    runner=adapter.runner,
                )
                intended = PairingDetachRecord(
                    operation_id, product_operation_id, plan.deployment_id,
                    _digest(asdict(plan)), _digest(asdict(reviewed_current)),
                    peer.forge_instance_id, peer.ep_instance_id,
                    old_binding.binding_id, old_binding.consumer_id,
                    old_binding.operator_id, revision, digest, "PREPARED", None,
                )
                _write(path, intended)
            else:
                intended = replace(existing, state="PREPARED", receipt_digest=None)
                if (
                    intended.operation_id != operation_id
                    or intended.product_operation_id != product_operation_id
                    or intended.deployment_id != plan.deployment_id
                    or intended.plan_fingerprint != _digest(asdict(plan))
                    or intended.reviewed_fingerprint != _digest(asdict(reviewed_current))
                    or intended.forge_instance_id != peer.forge_instance_id
                    or intended.ep_instance_id != peer.ep_instance_id
                    or intended.binding_id != old_binding.binding_id
                    or intended.consumer_id != old_binding.consumer_id
                    or intended.operator_id != old_binding.operator_id
                ):
                    raise ManagedPairingDetachError("Forge repair detach identity changed")
                if existing.state == "COMPLETE":
                    try:
                        status = adapter.read_detach_ep_peer(
                            operation_id=product_operation_id,
                            binding_id=intended.binding_id,
                            revision=intended.configuration_revision,
                            configuration_digest=intended.configuration_digest,
                            operator_id=intended.operator_id,
                        )
                    except Exception:
                        status = adapter.read_historical_detach_ep_peer(
                            operation_id=product_operation_id,
                            binding_id=intended.binding_id,
                            revision=intended.configuration_revision,
                            configuration_digest=intended.configuration_digest,
                            operator_id=intended.operator_id,
                        )
                    if status["receipt"]["receipt_digest"] != existing.receipt_digest:
                        raise ManagedPairingDetachError("terminal Forge repair detach changed")
                    return existing
            self.currency_guard.require_current(
                deployment_id=plan.deployment_id, mutation="forge-peer-detach",
                component=FORGE_COMPONENT, instance_id=peer.forge_instance_id,
                operation_id=operation_id,
            )
            if self.registry.load(plan.deployment_id) != reviewed_current:
                raise ManagedPairingDetachError("reviewed deployment changed before repair mutation")
            status = adapter.detach_ep_peer(
                operation_id=product_operation_id, binding_id=intended.binding_id,
                revision=intended.configuration_revision,
                configuration_digest=intended.configuration_digest,
                operator_id=intended.operator_id,
            )
            completed = replace(
                intended, state="COMPLETE", receipt_digest=status["receipt"]["receipt_digest"],
            )
            _write(path, completed)
            return completed
        finally:
            os.close(descriptor)
