"""Durable managed-deployment execution above product-owned component operations.

This module is deliberately a saga coordinator, not another product updater.
Every product mutation goes through DurableComponentOperationCoordinator and
the selected product adapter. The deployment journal records only non-secret
coordination identities and product receipt references, then commits the
Forge-Platform-owned managed deployment registry after every selected component
is terminal.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Mapping

from .component_operations import (
    ComponentOperationRecord,
    ComponentOperationRequest,
    ProductOperationAdapter,
)
from .durable_component_operations import DurableComponentOperationCoordinator
from .managed_deployments import (
    ManagedComponentBinding,
    ManagedDeployment,
    ManagedDeploymentDiff,
    ManagedDeploymentPlan,
    ManagedDeploymentRegistry,
    ManagedPeerBinding,
)


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_MUTATING_ACTION_TO_KIND = {
    "ADD_COMPONENT": "install",
    "UPDATE": "update",
    "REPAIR": "repair",
    "REMOVE_COMPONENT": "remove",
}


class ManagedInstallerError(RuntimeError):
    """The selected deployment plan cannot be dispatched or reconciled safely."""


@dataclass(frozen=True)
class ManagedComponentExecution:
    component: str
    instance_id: str
    action: str
    operation_id: str | None
    state: str
    receipt_reference: str | None

    def __post_init__(self) -> None:
        if self.action == "NO_CHANGE":
            if self.operation_id is not None or self.state != "UNCHANGED" or self.receipt_reference is not None:
                raise ValueError("NO_CHANGE execution evidence is invalid")
        else:
            if self.action not in _MUTATING_ACTION_TO_KIND:
                raise ValueError("managed component execution action is unsupported")
            if not isinstance(self.operation_id, str) or _OPERATION_ID.fullmatch(self.operation_id) is None:
                raise ValueError("managed component execution operation_id is invalid")
            if self.state not in {"PENDING", "COMPLETE", "RECOVERY_PENDING", "FAILED"}:
                raise ValueError("managed component execution state is unsupported")
            if self.state == "COMPLETE" and not self.receipt_reference:
                raise ValueError("completed managed component execution requires receipt evidence")


@dataclass(frozen=True)
class ManagedDeploymentExecutionRecord:
    operation_id: str
    deployment_id: str
    plan_fingerprint: str
    expected_registry_revision: int | None
    components: tuple[ManagedComponentExecution, ...]
    state: str
    registry_revision: int | None

    def __post_init__(self) -> None:
        if _OPERATION_ID.fullmatch(self.operation_id) is None:
            raise ValueError("managed deployment operation_id is invalid")
        if self.state not in {"PLANNED", "PRODUCTS_COMPLETE", "COMPLETE", "RECOVERY_PENDING", "FAILED"}:
            raise ValueError("managed deployment execution state is unsupported")
        if self.state == "COMPLETE" and self.registry_revision is None and self.components:
            # REMOVE_DEPLOYMENT has no surviving revision and is represented
            # by registry_revision=0 below.
            raise ValueError("completed managed deployment execution requires registry disposition")


class ManagedDeploymentOperationCoordinator:
    """One exact deployment saga with idempotent product delegates and CAS registry commit."""

    def __init__(
        self,
        *,
        operations_root: Path,
        component_operations_root: Path,
        registry: ManagedDeploymentRegistry,
    ) -> None:
        if not operations_root.is_absolute() or not component_operations_root.is_absolute():
            raise ValueError("managed installer operation roots must be absolute")
        self.operations_root = operations_root.resolve(strict=False)
        self.component_coordinator = DurableComponentOperationCoordinator(
            component_operations_root.resolve(strict=False)
        )
        self.registry = registry

    def execute(
        self,
        operation_id: str,
        plan: ManagedDeploymentPlan,
        *,
        requests: Mapping[str, ComponentOperationRequest],
        adapters: Mapping[str, ProductOperationAdapter],
    ) -> ManagedDeploymentExecutionRecord:
        if _OPERATION_ID.fullmatch(operation_id) is None:
            raise ValueError("managed deployment operation_id is invalid")
        plan_fingerprint = self._plan_fingerprint(plan)
        path = self._record_path(operation_id)
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self._lock(self.operations_root / f".deployment-{self._target_digest(plan.deployment_id)}.lock"):
            existing = self._read(path)
            if existing is not None:
                if existing.deployment_id != plan.deployment_id or existing.plan_fingerprint != plan_fingerprint:
                    raise ManagedInstallerError("managed deployment operation identity changed")
                if existing.state == "COMPLETE":
                    return existing

            self._validate_requests(plan, requests, adapters)
            executions: list[ManagedComponentExecution] = []
            recovery_pending = False
            for diff in sorted(plan.component_diffs, key=lambda item: item.component):
                if diff.action == "NO_CHANGE":
                    executions.append(ManagedComponentExecution(
                        diff.component, diff.instance_id, diff.action, None, "UNCHANGED", None,
                    ))
                    continue

                request = requests[diff.component]
                adapter = adapters[diff.component]
                record = self.component_coordinator.delegate(request, adapter)
                state = self._component_state(record)
                executions.append(ManagedComponentExecution(
                    diff.component,
                    diff.instance_id,
                    diff.action,
                    request.operation_id,
                    state,
                    record.product_receipt.evidence_reference if state == "COMPLETE" else None,
                ))
                if state == "FAILED":
                    result = ManagedDeploymentExecutionRecord(
                        operation_id, plan.deployment_id, plan_fingerprint,
                        plan.current_revision, tuple(executions), "FAILED", None,
                    )
                    self._write(path, result)
                    return result
                if state == "RECOVERY_PENDING":
                    recovery_pending = True

            if recovery_pending:
                result = ManagedDeploymentExecutionRecord(
                    operation_id, plan.deployment_id, plan_fingerprint,
                    plan.current_revision, tuple(executions), "RECOVERY_PENDING", None,
                )
                self._write(path, result)
                return result

            products_complete = ManagedDeploymentExecutionRecord(
                operation_id, plan.deployment_id, plan_fingerprint,
                plan.current_revision, tuple(executions), "PRODUCTS_COMPLETE", None,
            )
            self._write(path, products_complete)
            registry_revision = self._commit_registry(plan, tuple(executions))
            completed = ManagedDeploymentExecutionRecord(
                operation_id, plan.deployment_id, plan_fingerprint,
                plan.current_revision, tuple(executions), "COMPLETE", registry_revision,
            )
            self._write(path, completed)
            return completed

    @staticmethod
    def _component_state(record: ComponentOperationRecord) -> str:
        if record.product_receipt.state == "COMPLETED":
            return "COMPLETE"
        if record.product_receipt.state in {"CLEANUP_PENDING", "RECOVERY_PENDING"}:
            return "RECOVERY_PENDING"
        return "FAILED"

    def _validate_requests(
        self,
        plan: ManagedDeploymentPlan,
        requests: Mapping[str, ComponentOperationRequest],
        adapters: Mapping[str, ProductOperationAdapter],
    ) -> None:
        expected = {
            diff.component: diff
            for diff in plan.component_diffs
            if diff.action != "NO_CHANGE"
        }
        if set(requests) != set(expected) or set(adapters) != set(expected):
            raise ManagedInstallerError("managed deployment product operations do not match the reviewed diff")
        for component, diff in expected.items():
            request = requests[component]
            if request.component != component or request.installation_identity != diff.instance_id:
                raise ManagedInstallerError("managed deployment product request target changed after review")
            expected_kind = _MUTATING_ACTION_TO_KIND[diff.action]
            if request.kind != expected_kind:
                raise ManagedInstallerError("managed deployment product operation kind changed after review")

    def _commit_registry(
        self,
        plan: ManagedDeploymentPlan,
        executions: tuple[ManagedComponentExecution, ...],
    ) -> int:
        if plan.deployment_action == "REMOVE_DEPLOYMENT":
            if plan.current_revision is None:
                raise ManagedInstallerError("remove deployment lacks current registry revision")
            self.registry.remove(plan.deployment_id, expected_revision=plan.current_revision)
            return 0

        desired = plan.desired
        if desired is None:
            raise ManagedInstallerError("managed deployment desired state is missing")
        current = self.registry.load(plan.deployment_id)
        execution_by_component = {item.component: item for item in executions}
        current_by_component = {} if current is None else current.by_component
        final_components: list[ManagedComponentBinding] = []
        for binding in desired.components:
            evidence = execution_by_component.get(binding.component)
            if evidence is None:
                raise ManagedInstallerError("managed deployment execution evidence is incomplete")
            if evidence.action == "NO_CHANGE":
                previous = current_by_component.get(binding.component)
                if previous is None or previous.instance_id != binding.instance_id:
                    raise ManagedInstallerError("NO_CHANGE component has no matching current registry binding")
                final_components.append(previous)
            elif evidence.action != "REMOVE_COMPONENT":
                if evidence.state != "COMPLETE" or evidence.receipt_reference is None:
                    raise ManagedInstallerError("managed deployment mutation lacks terminal product receipt")
                final_components.append(ManagedComponentBinding(
                    binding.component, binding.instance_id, self._opaque_receipt(evidence.receipt_reference)
                ))

        peer = desired.peer_binding
        if peer is not None:
            # Cross-component pairing is its own qualified operation. Preserve
            # a current matching peer receipt; a newly added pair must be bound
            # by the later pairing coordinator before this registry commit.
            if current is None or current.peer_binding is None:
                raise ManagedInstallerError("new Forge-to-EP peer binding requires terminal pairing evidence")
            if (
                current.peer_binding.forge_instance_id != peer.forge_instance_id
                or current.peer_binding.ep_instance_id != peer.ep_instance_id
            ):
                raise ManagedInstallerError("Forge-to-EP peer binding changed without pairing evidence")
            peer = current.peer_binding

        if current is None:
            final = ManagedDeployment(
                desired.deployment_id, 1, desired.label, tuple(final_components), peer,
            )
            self.registry.create(final)
            return 1
        if plan.current_revision != current.revision:
            raise ManagedInstallerError("managed deployment registry changed after reviewed plan")
        final = ManagedDeployment(
            desired.deployment_id,
            current.revision + 1,
            desired.label,
            tuple(final_components),
            peer,
        )
        self.registry.replace(final, expected_revision=current.revision)
        return final.revision

    @staticmethod
    def _opaque_receipt(evidence_reference: str) -> str:
        return "receipt:" + sha256(evidence_reference.encode("utf-8")).hexdigest()

    @staticmethod
    def _plan_fingerprint(plan: ManagedDeploymentPlan) -> str:
        payload = {
            "deployment_id": plan.deployment_id,
            "current_revision": plan.current_revision,
            "deployment_action": plan.deployment_action,
            "component_diffs": [asdict(item) for item in plan.component_diffs],
            "desired": None if plan.desired is None else asdict(plan.desired),
        }
        return "sha256:" + sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        ).hexdigest()

    @staticmethod
    def _target_digest(deployment_id: str) -> str:
        return sha256(deployment_id.encode("utf-8")).hexdigest()

    def _record_path(self, operation_id: str) -> Path:
        return self.operations_root / f"{operation_id}.json"

    @staticmethod
    def _write(path: Path, record: ManagedDeploymentExecutionRecord) -> None:
        payload = asdict(record)
        descriptor, temporary_name = tempfile.mkstemp(prefix=".managed-operation-", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    @staticmethod
    def _read(path: Path) -> ManagedDeploymentExecutionRecord | None:
        if not path.exists():
            return None
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            components = tuple(ManagedComponentExecution(**item) for item in raw["components"])
            return ManagedDeploymentExecutionRecord(
                raw["operation_id"],
                raw["deployment_id"],
                raw["plan_fingerprint"],
                raw["expected_registry_revision"],
                components,
                raw["state"],
                raw["registry_revision"],
            )
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            raise ManagedInstallerError("managed deployment operation journal is invalid") from error

    @staticmethod
    def _lock(path: Path):
        class _Lock:
            def __enter__(self_inner):
                self_inner.fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
                try:
                    fcntl.flock(self_inner.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    os.close(self_inner.fd)
                    raise ManagedInstallerError("selected managed deployment is already being mutated") from error
                return self_inner

            def __exit__(self_inner, *_):
                fcntl.flock(self_inner.fd, fcntl.LOCK_UN)
                os.close(self_inner.fd)

        return _Lock()
