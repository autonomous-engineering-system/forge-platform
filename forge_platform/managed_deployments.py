"""Durable Forge Platform managed-deployment registry and topology planning.

A managed deployment is Forge Platform's coordination identity for an exact
selection of product-owned server instances. Product instance identity remains
owned by Forge/Engineering Platform; this registry never stores credentials,
runtime paths, product databases, service labels, provider state or product
migration instructions.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Iterator, Mapping


MANAGED_DEPLOYMENT_SCHEMA = "forge-platform.managed-deployment/v1"
SERVER_COMPONENTS = frozenset({"forge-runtime", "engineering-platform-server"})
TOPOLOGY_ACTIONS = frozenset({
    "ADD_COMPONENT", "UPDATE", "NO_CHANGE", "REPAIR", "REMOVE_COMPONENT",
})
_SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_RECEIPT = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")


class ManagedDeploymentError(RuntimeError):
    """Managed-deployment state is unsafe, ambiguous, stale, or corrupt."""


def _safe_id(value: object, label: str) -> str:
    if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
        raise ValueError(f"{label} must be a safe opaque identifier")
    return value


def _receipt(value: object, label: str) -> str:
    if not isinstance(value, str) or _RECEIPT.fullmatch(value) is None:
        raise ValueError(f"{label} must be an opaque receipt reference")
    return value


def _label(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > 128:
        raise ValueError("managed deployment label is invalid")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError("managed deployment label contains control characters")
    return value


@dataclass(frozen=True)
class ManagedComponentBinding:
    component: str
    instance_id: str
    receipt_reference: str

    def __post_init__(self) -> None:
        if self.component not in SERVER_COMPONENTS:
            raise ValueError("managed deployment component is unsupported")
        _safe_id(self.instance_id, "managed component instance_id")
        _receipt(self.receipt_reference, "managed component receipt_reference")


@dataclass(frozen=True)
class ManagedPeerBinding:
    forge_instance_id: str
    ep_instance_id: str
    receipt_reference: str

    def __post_init__(self) -> None:
        _safe_id(self.forge_instance_id, "Forge peer instance_id")
        _safe_id(self.ep_instance_id, "EP peer instance_id")
        _receipt(self.receipt_reference, "peer receipt_reference")


@dataclass(frozen=True)
class ManagedDeployment:
    deployment_id: str
    revision: int
    label: str | None
    components: tuple[ManagedComponentBinding, ...]
    peer_binding: ManagedPeerBinding | None = None
    schema: str = MANAGED_DEPLOYMENT_SCHEMA

    def __post_init__(self) -> None:
        if self.schema != MANAGED_DEPLOYMENT_SCHEMA:
            raise ValueError("managed deployment schema is unsupported")
        _safe_id(self.deployment_id, "managed deployment_id")
        if isinstance(self.revision, bool) or not isinstance(self.revision, int) or self.revision <= 0:
            raise ValueError("managed deployment revision must be positive")
        _label(self.label)
        if not self.components or any(not isinstance(item, ManagedComponentBinding) for item in self.components):
            raise ValueError("managed deployment requires at least one server component")
        identities = [item.component for item in self.components]
        instances = [item.instance_id for item in self.components]
        if len(identities) != len(set(identities)):
            raise ValueError("managed deployment contains duplicate component roles")
        if len(instances) != len(set(instances)):
            raise ValueError("managed deployment cannot bind one product instance twice")
        if self.peer_binding is not None:
            if not isinstance(self.peer_binding, ManagedPeerBinding):
                raise ValueError("managed deployment peer binding is invalid")
            by_component = {item.component: item for item in self.components}
            forge = by_component.get("forge-runtime")
            ep = by_component.get("engineering-platform-server")
            if (
                forge is None
                or ep is None
                or forge.instance_id != self.peer_binding.forge_instance_id
                or ep.instance_id != self.peer_binding.ep_instance_id
            ):
                raise ValueError("peer binding must join the exact managed Forge and EP instances")

    @property
    def by_component(self) -> Mapping[str, ManagedComponentBinding]:
        return {item.component: item for item in self.components}


@dataclass(frozen=True)
class ManagedDeploymentDiff:
    component: str
    instance_id: str
    action: str

    def __post_init__(self) -> None:
        if self.component not in SERVER_COMPONENTS:
            raise ValueError("managed deployment diff component is unsupported")
        _safe_id(self.instance_id, "managed deployment diff instance_id")
        if self.action not in TOPOLOGY_ACTIONS:
            raise ValueError("managed deployment diff action is unsupported")


@dataclass(frozen=True)
class ManagedDeploymentPlan:
    deployment_id: str
    current_revision: int | None
    desired: ManagedDeployment | None
    component_diffs: tuple[ManagedDeploymentDiff, ...]
    deployment_action: str

    def __post_init__(self) -> None:
        _safe_id(self.deployment_id, "managed deployment plan deployment_id")
        if self.current_revision is not None and (
            isinstance(self.current_revision, bool)
            or not isinstance(self.current_revision, int)
            or self.current_revision <= 0
        ):
            raise ValueError("managed deployment plan current revision is invalid")
        if self.deployment_action not in {"CREATE_OR_UPDATE", "REMOVE_DEPLOYMENT"}:
            raise ValueError("managed deployment action is unsupported")
        if self.deployment_action == "REMOVE_DEPLOYMENT" and self.desired is not None:
            raise ValueError("remove-deployment plan cannot retain desired state")
        if self.deployment_action == "CREATE_OR_UPDATE" and self.desired is None:
            raise ValueError("create/update plan requires desired state")
        if any(not isinstance(diff, ManagedDeploymentDiff) for diff in self.component_diffs):
            raise ValueError("managed deployment component diffs are invalid")


class ManagedDeploymentPlanner:
    """Plan only the selected deployment; unrelated host instances are out of scope."""

    @staticmethod
    def plan(
        current: ManagedDeployment | None,
        desired: ManagedDeployment | None,
        *,
        product_actions: Mapping[str, str] | None = None,
    ) -> ManagedDeploymentPlan:
        if current is None and desired is None:
            raise ValueError("managed deployment plan requires current or desired state")
        deployment_id = (desired or current).deployment_id  # type: ignore[union-attr]
        if current is not None and current.deployment_id != deployment_id:
            raise ValueError("current deployment identity changed")
        if desired is not None and desired.deployment_id != deployment_id:
            raise ValueError("desired deployment identity changed")
        if desired is None:
            diffs = tuple(
                ManagedDeploymentDiff(item.component, item.instance_id, "REMOVE_COMPONENT")
                for item in sorted(current.components, key=lambda value: value.component)  # type: ignore[union-attr]
            )
            return ManagedDeploymentPlan(
                deployment_id, current.revision if current else None, None, diffs, "REMOVE_DEPLOYMENT",
            )

        actions = dict(product_actions or {})
        if set(actions) - set(SERVER_COMPONENTS):
            raise ValueError("product actions contain an unsupported component")
        current_by = {} if current is None else current.by_component
        desired_by = desired.by_component
        diffs: list[ManagedDeploymentDiff] = []
        for component in sorted(SERVER_COMPONENTS):
            before = current_by.get(component)
            after = desired_by.get(component)
            if before is None and after is None:
                continue
            if after is None:
                diffs.append(ManagedDeploymentDiff(component, before.instance_id, "REMOVE_COMPONENT"))  # type: ignore[union-attr]
                continue
            if before is None:
                if component in actions and actions[component] != "ADD_COMPONENT":
                    raise ManagedDeploymentError("new component can only be ADD_COMPONENT")
                diffs.append(ManagedDeploymentDiff(component, after.instance_id, "ADD_COMPONENT"))
                continue
            if before.instance_id != after.instance_id:
                raise ManagedDeploymentError(
                    "changing an existing component instance requires explicit remove then add"
                )
            action = actions.get(component, "NO_CHANGE")
            if action not in {"UPDATE", "NO_CHANGE", "REPAIR"}:
                raise ManagedDeploymentError("existing component action must be UPDATE, REPAIR or NO_CHANGE")
            diffs.append(ManagedDeploymentDiff(component, after.instance_id, action))
        return ManagedDeploymentPlan(
            deployment_id,
            current.revision if current else None,
            desired,
            tuple(diffs),
            "CREATE_OR_UPDATE",
        )


class ManagedDeploymentRegistry:
    """Atomic mode-0600 registry with optimistic revision control."""

    def __init__(self, root: Path) -> None:
        if not isinstance(root, Path) or not root.is_absolute():
            raise ValueError("managed deployment registry root must be absolute")
        self.root = root.resolve(strict=False)

    def inventory(self) -> tuple[ManagedDeployment, ...]:
        self._secure_root()
        result: list[ManagedDeployment] = []
        for path in sorted(self.root.glob("*.json")):
            if _SAFE_ID.fullmatch(path.stem) is None:
                raise ManagedDeploymentError("managed deployment registry contains an unsafe path")
            result.append(self._read(path))
        ids = [item.deployment_id for item in result]
        if len(ids) != len(set(ids)):
            raise ManagedDeploymentError("managed deployment registry contains duplicate identities")
        claimed: dict[tuple[str, str], str] = {}
        for deployment in result:
            for binding in deployment.components:
                key = (binding.component, binding.instance_id)
                other = claimed.get(key)
                if other is not None and other != deployment.deployment_id:
                    raise ManagedDeploymentError(
                        f"product instance is claimed by multiple managed deployments: {binding.component}/{binding.instance_id}"
                    )
                claimed[key] = deployment.deployment_id
        return tuple(result)

    def load(self, deployment_id: str) -> ManagedDeployment | None:
        path = self._path(deployment_id)
        if not path.exists():
            return None
        return self._read(path)

    def create(self, deployment: ManagedDeployment) -> ManagedDeployment:
        if not isinstance(deployment, ManagedDeployment):
            raise ValueError("managed deployment is invalid")
        if deployment.revision != 1:
            raise ValueError("new managed deployment must start at revision 1")
        with self._lock():
            if self.load(deployment.deployment_id) is not None:
                raise ManagedDeploymentError("managed deployment already exists")
            self._assert_instances_unclaimed(deployment)
            self._write(deployment)
        return deployment

    def replace(self, deployment: ManagedDeployment, *, expected_revision: int) -> ManagedDeployment:
        if not isinstance(deployment, ManagedDeployment):
            raise ValueError("managed deployment is invalid")
        with self._lock():
            current = self.load(deployment.deployment_id)
            if current is None:
                raise ManagedDeploymentError("managed deployment does not exist")
            if current.revision != expected_revision:
                raise ManagedDeploymentError("managed deployment revision changed")
            if deployment.revision != expected_revision + 1:
                raise ManagedDeploymentError("managed deployment replacement revision is invalid")
            self._assert_instances_unclaimed(deployment, excluding=deployment.deployment_id)
            self._write(deployment)
        return deployment

    def remove(self, deployment_id: str, *, expected_revision: int) -> ManagedDeployment:
        with self._lock():
            current = self.load(deployment_id)
            if current is None:
                raise ManagedDeploymentError("managed deployment does not exist")
            if current.revision != expected_revision:
                raise ManagedDeploymentError("managed deployment revision changed")
            path = self._path(deployment_id)
            path.unlink()
            directory = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            return current

    def _assert_instances_unclaimed(self, deployment: ManagedDeployment, *, excluding: str | None = None) -> None:
        claimed = {
            (binding.component, binding.instance_id): item.deployment_id
            for item in self.inventory()
            if item.deployment_id != excluding
            for binding in item.components
        }
        for binding in deployment.components:
            owner = claimed.get((binding.component, binding.instance_id))
            if owner is not None:
                raise ManagedDeploymentError(
                    f"product instance already belongs to managed deployment {owner}"
                )

    def _path(self, deployment_id: str) -> Path:
        return self.root / f"{_safe_id(deployment_id, 'managed deployment_id')}.json"

    def _secure_root(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(self.root, 0o700)
        except OSError as error:
            raise ManagedDeploymentError("managed deployment registry permissions could not be secured") from error

    @contextmanager
    def _lock(self) -> Iterator[None]:
        self._secure_root()
        descriptor = os.open(self.root / ".registry.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ManagedDeploymentError("managed deployment registry is already being mutated") from error
            yield
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _write(self, deployment: ManagedDeployment) -> None:
        self._secure_root()
        target = self._path(deployment.deployment_id)
        descriptor, temporary_name = tempfile.mkstemp(prefix=".managed-deployment-", dir=self.root)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(asdict(deployment), handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, target)
            directory = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    @staticmethod
    def _read(path: Path) -> ManagedDeployment:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict) or set(raw) != {
                "schema", "deployment_id", "revision", "label", "components", "peer_binding"
            }:
                raise ValueError("fields")
            components_raw = raw["components"]
            if not isinstance(components_raw, list):
                raise ValueError("components")
            components = tuple(
                ManagedComponentBinding(**item) if isinstance(item, dict) else (_ for _ in ()).throw(ValueError("component"))
                for item in components_raw
            )
            peer_raw = raw["peer_binding"]
            peer = None if peer_raw is None else ManagedPeerBinding(**peer_raw)
            deployment = ManagedDeployment(
                deployment_id=raw["deployment_id"],
                revision=raw["revision"],
                label=raw["label"],
                components=components,
                peer_binding=peer,
                schema=raw["schema"],
            )
        except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
            raise ManagedDeploymentError("managed deployment record is invalid") from error
        if deployment.deployment_id != path.stem:
            raise ManagedDeploymentError("managed deployment identity does not match its record path")
        return deployment
