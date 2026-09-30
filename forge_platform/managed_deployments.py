"""Durable Forge Platform managed-deployment registry and topology planning.

A managed deployment is Forge Platform's coordination identity for an exact
selection of product-owned server instances. Product instance identity remains
owned by Forge/Engineering Platform; this registry never stores credentials,
runtime paths, product databases, service labels, provider state or product
migration instructions.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass, replace
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Iterator, Mapping

from .component_operations import ProductInstallationReadback, QualifiedArtifact
from .composition_identity import require_composition_identity
from .product_preserved_lifecycle import (
    ProductPreservedLifecycleError,
    frozen_preserved_release,
    validate_terminal_preserved_lifecycle,
)
from .universal_installer import CompositionManifest


MANAGED_DEPLOYMENT_SCHEMA_V1 = "forge-platform.managed-deployment/v1"
MANAGED_DEPLOYMENT_SCHEMA_V2 = "forge-platform.managed-deployment/v2"
MANAGED_DEPLOYMENT_SCHEMA_V3 = "forge-platform.managed-deployment/v3"
# Compatibility alias for callers that intentionally construct legacy,
# topology-only records. Terminal composition provenance always uses V2.
MANAGED_DEPLOYMENT_SCHEMA = MANAGED_DEPLOYMENT_SCHEMA_V1
SERVER_COMPONENTS = frozenset({"forge-runtime", "engineering-platform-server"})
TOPOLOGY_ACTIONS = frozenset({
    "ADD_COMPONENT", "UPDATE", "NO_CHANGE", "REPAIR", "REMOVE_COMPONENT",
})
_SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_PRODUCT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_RECEIPT = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


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


def _digest(value: object, label: str) -> str:
    if not isinstance(value, str) or _DIGEST.fullmatch(value) is None:
        raise ValueError(f"{label} must be a tagged SHA-256 digest")
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
class ManagedCompositionBinding:
    """Terminal immutable composition provenance for one managed deployment."""

    composition_id: str
    manifest_digest: str
    receipt_reference: str

    def __post_init__(self) -> None:
        require_composition_identity(self.composition_id, "managed composition_id")
        _digest(self.manifest_digest, "managed composition manifest_digest")
        _receipt(self.receipt_reference, "managed composition receipt_reference")


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
class ManagedPreservedComponentBinding:
    """Product-owned preserved identity; never an active component shortcut."""

    component: str
    instance_id: str
    previous_receipt_reference: str
    preserve_operation_id: str
    preserve_receipt_digest: str
    version: str
    source_revision: str
    artifact_digest: str
    forge_runtime_id: str | None = None
    forge_installation_id: str | None = None

    def __post_init__(self) -> None:
        if self.component not in SERVER_COMPONENTS:
            raise ValueError("preserved component is unsupported")
        _safe_id(self.instance_id, "preserved instance_id")
        _receipt(self.previous_receipt_reference, "preserved previous receipt")
        _safe_id(self.preserve_operation_id, "preserve operation_id")
        _digest(self.preserve_receipt_digest, "preserve receipt digest")
        if not frozen_preserved_release(self.component, QualifiedArtifact(
            self.version, self.source_revision, "frozen-release",
            self.artifact_digest, "terminal-product-evidence",
        )):
            raise ValueError("preserved component release is not frozen")
        if self.component == "forge-runtime":
            if self.forge_runtime_id != self.instance_id:
                raise ValueError("preserved Forge runtime identity changed")
            if (
                not isinstance(self.forge_installation_id, str)
                or _PRODUCT_ID.fullmatch(self.forge_installation_id) is None
                or self.forge_installation_id in {".", ".."}
            ):
                raise ValueError("preserved Forge installation_id is invalid")
        elif self.forge_runtime_id is not None or self.forge_installation_id is not None:
            raise ValueError("preserved EP component carries Forge identity")


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
    composition_binding: ManagedCompositionBinding | None = None

    def __post_init__(self) -> None:
        if self.schema not in {MANAGED_DEPLOYMENT_SCHEMA_V1, MANAGED_DEPLOYMENT_SCHEMA_V2}:
            raise ValueError("managed deployment schema is unsupported")
        if self.schema == MANAGED_DEPLOYMENT_SCHEMA_V1 and self.composition_binding is not None:
            raise ValueError("legacy managed deployment cannot carry composition provenance")
        if self.schema == MANAGED_DEPLOYMENT_SCHEMA_V2 and not isinstance(
            self.composition_binding, ManagedCompositionBinding
        ):
            raise ValueError("managed deployment v2 requires terminal composition provenance")
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
        if self.composition_binding is not None and not isinstance(
            self.composition_binding, ManagedCompositionBinding
        ):
            raise ValueError("managed deployment composition binding is invalid")
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

    @property
    def active_by_component(self) -> Mapping[str, ManagedComponentBinding]:
        return {item.component: item for item in self.components}

    @property
    def preserved_by_component(self) -> Mapping[str, ManagedPreservedComponentBinding]:
        return {}


@dataclass(frozen=True)
class ManagedPreservedDeployment(ManagedDeployment):
    """V3 registry record; legacy planners cannot treat it as installed."""

    schema: str = MANAGED_DEPLOYMENT_SCHEMA_V3
    preserved_components: tuple[ManagedPreservedComponentBinding, ...] = ()
    historical_peer_binding: ManagedPeerBinding | None = None

    def __post_init__(self) -> None:
        if self.schema != MANAGED_DEPLOYMENT_SCHEMA_V3:
            raise ValueError("preserved deployment schema is invalid")
        _safe_id(self.deployment_id, "preserved deployment_id")
        if isinstance(self.revision, bool) or not isinstance(self.revision, int) or self.revision <= 0:
            raise ValueError("preserved deployment revision must be positive")
        _label(self.label)
        if not isinstance(self.composition_binding, ManagedCompositionBinding):
            raise ValueError("preserved deployment requires composition provenance")
        if self.peer_binding is not None or not self.preserved_components:
            raise ValueError("preserved deployment cannot retain active pairing")
        if any(not isinstance(item, ManagedComponentBinding) for item in self.components):
            raise ValueError("preserved deployment active components are invalid")
        if any(not isinstance(item, ManagedPreservedComponentBinding) for item in self.preserved_components):
            raise ValueError("preserved deployment components are invalid")
        all_components = self.components + self.preserved_components
        identities = [item.component for item in all_components]
        instances = [item.instance_id for item in all_components]
        if len(identities) != len(set(identities)) or len(instances) != len(set(instances)):
            raise ValueError("preserved deployment contains duplicate component or instance")
        if self.historical_peer_binding is not None:
            if not isinstance(self.historical_peer_binding, ManagedPeerBinding):
                raise ValueError("historical peer binding is invalid")
            by_component = {item.component: item for item in all_components}
            if (
                set(by_component) != SERVER_COMPONENTS
                or by_component["forge-runtime"].instance_id
                    != self.historical_peer_binding.forge_instance_id
                or by_component["engineering-platform-server"].instance_id
                    != self.historical_peer_binding.ep_instance_id
            ):
                raise ValueError("historical pairing no longer targets exact instances")

    @property
    def by_component(self) -> Mapping[str, ManagedComponentBinding]:
        raise ManagedDeploymentError("preserved deployment needs lifecycle-aware inventory")

    @property
    def preserved_by_component(self) -> Mapping[str, ManagedPreservedComponentBinding]:
        return {item.component: item for item in self.preserved_components}


def prior_paired_forge_candidates(
    current: ManagedDeployment,
) -> tuple[ManagedDeployment, ManagedDeployment]:
    """Reconstruct both possible component orders of one exact paired PRESERVE.

    The owning preserve/revocation journals must independently select exactly
    one candidate by their original reviewed fingerprints.
    """
    if (
        not isinstance(current, ManagedPreservedDeployment)
        or current.revision < 2
        or current.peer_binding is not None
        or current.historical_peer_binding is None
        or set(current.active_by_component) != {"engineering-platform-server"}
        or set(current.preserved_by_component) != {"forge-runtime"}
    ):
        raise ManagedDeploymentError("historical paired Forge inventory is unavailable")
    preserved = current.preserved_by_component["forge-runtime"]
    ep = current.active_by_component["engineering-platform-server"]
    peer = current.historical_peer_binding
    if (
        preserved.instance_id != peer.forge_instance_id
        or ep.instance_id != peer.ep_instance_id
    ):
        raise ManagedDeploymentError("historical paired instances changed")
    forge = ManagedComponentBinding(
        "forge-runtime", preserved.instance_id, preserved.previous_receipt_reference,
    )
    def candidate(components: tuple[ManagedComponentBinding, ...]) -> ManagedDeployment:
        return ManagedDeployment(
            current.deployment_id, current.revision - 1, current.label,
            components, peer, MANAGED_DEPLOYMENT_SCHEMA_V2,
            current.composition_binding,
        )
    return candidate((forge, ep)), candidate((ep, forge))


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
        if any(
            item is not None and item.schema == MANAGED_DEPLOYMENT_SCHEMA_V3
            for item in (current, desired)
        ):
            raise ManagedDeploymentError("preserved deployment requires a lifecycle plan")
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
            for binding in deployment.components + getattr(deployment, "preserved_components", ()):
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
        if deployment.schema == MANAGED_DEPLOYMENT_SCHEMA_V3:
            raise ManagedDeploymentError("preserved deployment requires product terminal evidence")
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
            if (
                current.schema == MANAGED_DEPLOYMENT_SCHEMA_V3
                or deployment.schema == MANAGED_DEPLOYMENT_SCHEMA_V3
            ):
                raise ManagedDeploymentError("preserved deployment requires lifecycle commit")
            if deployment.revision != expected_revision + 1:
                raise ManagedDeploymentError("managed deployment replacement revision is invalid")
            self._assert_instances_unclaimed(deployment, excluding=deployment.deployment_id)
            self._write(deployment)
        return deployment

    def commit_preserved(
        self, *, deployment_id: str, expected_revision: int,
        component: str, instance_id: str, operation_id: str,
        artifact: QualifiedArtifact, installed_manifest: CompositionManifest,
        request_digest: str, receipt: Mapping[str, object],
        status: Mapping[str, object],
    ) -> ManagedDeployment:
        """CAS one product-proven preserve without releasing its instance claim."""
        _safe_id(deployment_id, "preserved deployment_id")
        if component not in SERVER_COMPONENTS:
            raise ManagedDeploymentError("preserved component is unsupported")
        if not isinstance(installed_manifest, CompositionManifest):
            raise ManagedDeploymentError("installed composition authority is unavailable")
        try:
            terminal = validate_terminal_preserved_lifecycle(
                component=component, operation="PRESERVE", operation_id=operation_id,
                instance_id=instance_id, artifact=artifact,
                request_digest=request_digest, receipt=receipt, status=status,
            )
        except ProductPreservedLifecycleError as error:
            raise ManagedDeploymentError("owning preserve evidence is invalid") from error
        artifacts = {
            item.identity: item.artifact for item in installed_manifest.components
        }
        selected = artifacts.get(component)
        if selected is None or selected.correlation != artifact.correlation:
            raise ManagedDeploymentError("preserved artifact is outside installed composition")
        with self._lock():
            current = self.load(deployment_id)
            if current is None or current.composition_binding is None:
                raise ManagedDeploymentError("preserved deployment lacks installed provenance")
            if (
                current.composition_binding.composition_id != installed_manifest.composition_id
                or current.composition_binding.manifest_digest != installed_manifest.manifest_digest
            ):
                raise ManagedDeploymentError("installed composition changed before preserve commit")
            prior = current.preserved_by_component.get(component)
            if prior is not None:
                if (
                    current.schema != MANAGED_DEPLOYMENT_SCHEMA_V3
                    or prior.instance_id != instance_id
                    or prior.preserve_operation_id != operation_id
                    or prior.preserve_receipt_digest != terminal.receipt_digest
                    or (prior.version, prior.source_revision, prior.artifact_digest)
                        != (artifact.version, artifact.source_revision, artifact.digest)
                    or current.revision <= expected_revision
                ):
                    raise ManagedDeploymentError("preserve replay targets different durable evidence")
                return current
            if current.revision != expected_revision or current.schema not in {
                MANAGED_DEPLOYMENT_SCHEMA_V2, MANAGED_DEPLOYMENT_SCHEMA_V3,
            }:
                raise ManagedDeploymentError("reviewed preserved deployment revision changed")
            active = current.active_by_component.get(component)
            if active is None or active.instance_id != instance_id:
                raise ManagedDeploymentError("preserve target is not the selected active instance")
            preserved = ManagedPreservedComponentBinding(
                component=component,
                instance_id=instance_id,
                previous_receipt_reference=active.receipt_reference,
                preserve_operation_id=operation_id,
                preserve_receipt_digest=terminal.receipt_digest,
                version=artifact.version,
                source_revision=artifact.source_revision,
                artifact_digest=artifact.digest,
                forge_runtime_id=(
                    receipt.get("runtime_id") if component == "forge-runtime" else None
                ),
                forge_installation_id=(
                    receipt.get("installation_id") if component == "forge-runtime" else None
                ),
            )
            candidate = ManagedPreservedDeployment(
                deployment_id=current.deployment_id,
                revision=current.revision + 1,
                label=current.label,
                components=tuple(
                    item for item in current.components if item.component != component
                ),
                peer_binding=None,
                schema=MANAGED_DEPLOYMENT_SCHEMA_V3,
                composition_binding=current.composition_binding,
                preserved_components=tuple(sorted(
                    tuple(current.preserved_by_component.values()) + (preserved,),
                    key=lambda item: item.component,
                )),
                historical_peer_binding=(
                    getattr(current, "historical_peer_binding", None) or current.peer_binding
                ),
            )
            self._assert_instances_unclaimed(candidate, excluding=deployment_id)
            self._write(candidate)
            return candidate

    def commit_ep_restored(
        self, *, deployment_id: str, expected_revision: int,
        instance_id: str, operation_id: str, preserve_operation_id: str,
        artifact: QualifiedArtifact, installed_manifest: CompositionManifest,
        receipt: Mapping[str, object], status: Mapping[str, object],
        readback: ProductInstallationReadback,
    ) -> ManagedDeployment:
        """CAS an EP-only RESTORE after owning lifecycle and fresh readiness proof.

        The caller must obtain readback from the sealed EP adapter after provider
        reverification and repair. No service or product mutation occurs here.
        """
        component = "engineering-platform-server"
        _safe_id(deployment_id, "restored deployment_id")
        if not isinstance(installed_manifest, CompositionManifest):
            raise ManagedDeploymentError("restore composition authority is unavailable")
        try:
            terminal = validate_terminal_preserved_lifecycle(
                component=component, operation="RESTORE",
                operation_id=operation_id, instance_id=instance_id,
                artifact=artifact, request_digest=receipt.get("request_digest"),
                receipt=receipt, status=status,
                preserve_operation_id=preserve_operation_id,
            )
        except (AttributeError, ProductPreservedLifecycleError) as error:
            raise ManagedDeploymentError("owning EP restore evidence is invalid") from error
        selected = [
            item.artifact for item in installed_manifest.components
            if item.identity == component
        ]
        if selected != [artifact]:
            raise ManagedDeploymentError("restored EP artifact is outside installed composition")
        if (
            not isinstance(readback, ProductInstallationReadback)
            or readback.component != component
            or readback.installation_identity != instance_id
            or readback.selected_instance_identity != instance_id
            or not isinstance(readback.selected_server_identity, str)
            or not readback.selected_server_identity
            or readback.artifact != artifact.correlation
            or readback.state != "ACTIVE"
            or readback.health_state != "HEALTHY"
            or readback.inventory_coverage != "MACHINE_WIDE"
            or readback.conflict_state != "NONE"
            or re.fullmatch(r"ep-inventory:[0-9a-f]{64}", readback.evidence_reference) is None
            or not isinstance(readback.health_evidence_reference, str)
            or re.fullmatch(r"ep-status:[0-9a-f]{64}", readback.health_evidence_reference) is None
        ):
            raise ManagedDeploymentError("restored EP provider/readiness proof is unavailable")
        reference_payload = {
            "deployment_id": deployment_id,
            "instance_id": instance_id,
            "operation_id": operation_id,
            "preserve_operation_id": preserve_operation_id,
            "restore_receipt_digest": terminal.receipt_digest,
            "composition_id": installed_manifest.composition_id,
            "manifest_digest": installed_manifest.manifest_digest,
            "inventory_reference": readback.evidence_reference,
            "readiness_reference": readback.health_evidence_reference,
        }
        reference = "receipt:restore-" + sha256(json.dumps(
            reference_payload, sort_keys=True, separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")).hexdigest()
        with self._lock():
            current = self.load(deployment_id)
            if current is None or current.composition_binding is None:
                raise ManagedDeploymentError("restored deployment is unavailable")
            if (
                current.composition_binding.composition_id != installed_manifest.composition_id
                or current.composition_binding.manifest_digest != installed_manifest.manifest_digest
            ):
                raise ManagedDeploymentError("restore composition changed")
            if current.revision == expected_revision + 1:
                active = current.active_by_component.get(component)
                if (
                    current.schema != MANAGED_DEPLOYMENT_SCHEMA_V2
                    or set(current.active_by_component) != {component}
                    or current.preserved_by_component
                    or current.peer_binding is not None
                    or active is None or active.instance_id != instance_id
                    or active.receipt_reference != reference
                ):
                    raise ManagedDeploymentError("restore replay identity changed")
                return current
            if (
                current.revision != expected_revision
                or current.schema != MANAGED_DEPLOYMENT_SCHEMA_V3
                or current.components
                or set(current.preserved_by_component) != {component}
                or current.peer_binding is not None
                or current.historical_peer_binding is not None
            ):
                raise ManagedDeploymentError("reviewed EP restore target changed")
            preserved = current.preserved_by_component[component]
            if (
                preserved.instance_id != instance_id
                or preserved.preserve_operation_id != preserve_operation_id
                or (preserved.version, preserved.source_revision,
                    preserved.artifact_digest) !=
                    (artifact.version, artifact.source_revision, artifact.digest)
            ):
                raise ManagedDeploymentError("preserved EP restore authority changed")
            candidate = ManagedDeployment(
                deployment_id=current.deployment_id,
                revision=current.revision + 1,
                label=current.label,
                components=(ManagedComponentBinding(component, instance_id, reference),),
                schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                composition_binding=current.composition_binding,
            )
            self._assert_instances_unclaimed(candidate, excluding=deployment_id)
            self._write(candidate)
            return candidate

    def commit_purged(
        self, *, deployment_id: str, expected_revision: int,
        component: str, instance_id: str, operation_id: str,
        artifact: QualifiedArtifact, installed_manifest: CompositionManifest,
        request_digest: str, receipt: Mapping[str, object],
        status: Mapping[str, object],
        pairing_revocation: object | None = None,
    ) -> ManagedDeployment | None:
        """Release only one product-proven instance claim after exact PURGE.

        A final component leaves no active deployment record. The owning
        product keeps the irreversible tombstone; the installer operation
        journal must retain the receipt for retry and terminal readback.
        """
        _safe_id(deployment_id, "purged deployment_id")
        if component not in SERVER_COMPONENTS:
            raise ManagedDeploymentError("purged component is unsupported")
        if not isinstance(installed_manifest, CompositionManifest):
            raise ManagedDeploymentError("installed composition authority is unavailable")
        try:
            validate_terminal_preserved_lifecycle(
                component=component, operation="PURGE", operation_id=operation_id,
                instance_id=instance_id, artifact=artifact,
                request_digest=request_digest, receipt=receipt, status=status,
            )
        except ProductPreservedLifecycleError as error:
            raise ManagedDeploymentError("owning purge evidence is invalid") from error
        artifacts = {
            item.identity: item.artifact for item in installed_manifest.components
        }
        selected = artifacts.get(component)
        if selected is None or selected.correlation != artifact.correlation:
            raise ManagedDeploymentError("purged artifact is outside installed composition")
        with self._lock():
            current = self.load(deployment_id)
            if current is None or current.revision != expected_revision:
                raise ManagedDeploymentError("reviewed purge revision changed")
            if (
                current.schema not in {MANAGED_DEPLOYMENT_SCHEMA_V2, MANAGED_DEPLOYMENT_SCHEMA_V3}
                or current.composition_binding is None
                or (current.composition_binding.composition_id,
                    current.composition_binding.manifest_digest)
                    != (installed_manifest.composition_id, installed_manifest.manifest_digest)
            ):
                raise ManagedDeploymentError("purge provenance or pairing changed")
            peer = current.peer_binding or getattr(current, "historical_peer_binding", None)
            if peer is None:
                if pairing_revocation is not None:
                    raise ManagedDeploymentError("unpaired purge carried pairing proof")
            else:
                from .managed_pairing_revocation import PairingRevocationRecord
                if (
                    component != "forge-runtime"
                    or pairing_revocation is None
                    or not isinstance(pairing_revocation, PairingRevocationRecord)
                    or pairing_revocation.state != "COMPLETE"
                    or pairing_revocation.deployment_id != deployment_id
                    or pairing_revocation.forge_instance_id != instance_id
                    or pairing_revocation.ep_instance_id != peer.ep_instance_id
                    or peer.forge_instance_id != instance_id
                    or not isinstance(pairing_revocation.receipt_reference, str)
                    or re.fullmatch(
                        r"ep-consumer-revoke:sha256:[0-9a-f]{64}",
                        pairing_revocation.receipt_reference,
                    ) is None
                ):
                    raise ManagedDeploymentError("paired purge lacks EP consumer revocation")
                ep = current.active_by_component.get("engineering-platform-server")
                if ep is None:
                    raise ManagedDeploymentError("paired purge lost its EP component")
                if current.peer_binding is not None:
                    originals = (current,)
                    expected_proof_operation = operation_id
                else:
                    preserved_forge = current.preserved_by_component.get("forge-runtime")
                    if preserved_forge is None or preserved_forge.instance_id != instance_id:
                        raise ManagedDeploymentError("historical Forge purge target changed")
                    originals = prior_paired_forge_candidates(current)
                    expected_proof_operation = preserved_forge.preserve_operation_id
                matching = tuple(original for original in originals if (
                    pairing_revocation.reviewed_deployment_fingerprint == "sha256:" +
                    sha256(json.dumps(
                        asdict(original), sort_keys=True, separators=(",", ":"),
                        allow_nan=False,
                    ).encode("utf-8")).hexdigest()
                    and pairing_revocation.plan_fingerprint == "sha256:" +
                    sha256(json.dumps(
                        asdict(ManagedDeploymentPlanner.plan(
                            original,
                            replace(original, components=(ep,), peer_binding=None),
                        )), sort_keys=True, separators=(",", ":"), allow_nan=False,
                    ).encode("utf-8")).hexdigest()
                ))
                if (
                    pairing_revocation.operation_id != expected_proof_operation
                    or len(matching) != 1
                ):
                    raise ManagedDeploymentError("paired purge removal plan changed")
            active = current.active_by_component.get(component)
            preserved = current.preserved_by_component.get(component)
            target = active or preserved
            if target is None or target.instance_id != instance_id:
                raise ManagedDeploymentError("purge targets another product instance")
            if preserved is not None and (
                preserved.version, preserved.source_revision,
                preserved.artifact_digest,
            ) != (artifact.version, artifact.source_revision, artifact.digest):
                raise ManagedDeploymentError("preserved purge release changed")
            remaining_active = tuple(
                item for item in current.components if item.component != component
            )
            remaining_preserved = tuple(
                item for item in getattr(current, "preserved_components", ())
                if item.component != component
            )
            if remaining_preserved:
                candidate: ManagedDeployment | None = ManagedPreservedDeployment(
                    deployment_id=current.deployment_id,
                    revision=current.revision + 1, label=current.label,
                    components=remaining_active, peer_binding=None,
                    composition_binding=current.composition_binding,
                    preserved_components=remaining_preserved,
                    historical_peer_binding=None,
                )
            elif remaining_active:
                candidate = ManagedDeployment(
                    deployment_id=current.deployment_id,
                    revision=current.revision + 1, label=current.label,
                    components=remaining_active, peer_binding=None,
                    schema=MANAGED_DEPLOYMENT_SCHEMA_V2,
                    composition_binding=current.composition_binding,
                )
            else:
                candidate = None
            if candidate is None:
                path = self._path(deployment_id)
                path.unlink()
                directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            else:
                self._assert_instances_unclaimed(candidate, excluding=deployment_id)
                self._write(candidate)
            return candidate

    def remove(self, deployment_id: str, *, expected_revision: int) -> ManagedDeployment:
        with self._lock():
            current = self.load(deployment_id)
            if current is None:
                raise ManagedDeploymentError("managed deployment does not exist")
            if current.revision != expected_revision:
                raise ManagedDeploymentError("managed deployment revision changed")
            if current.schema == MANAGED_DEPLOYMENT_SCHEMA_V3:
                raise ManagedDeploymentError("preserved deployment cannot be removed without purge")
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
            for binding in item.components + getattr(item, "preserved_components", ())
        }
        for binding in deployment.components + getattr(deployment, "preserved_components", ()):
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
        payload = asdict(deployment)
        if deployment.schema != MANAGED_DEPLOYMENT_SCHEMA_V3:
            payload.pop("preserved_components", None)
            payload.pop("historical_peer_binding", None)
        if deployment.schema == MANAGED_DEPLOYMENT_SCHEMA_V1:
            # Preserve the exact V1 wire shape so older durable records remain
            # byte-structure compatible and no implicit schema migration occurs.
            payload.pop("composition_binding", None)
        descriptor, temporary_name = tempfile.mkstemp(prefix=".managed-deployment-", dir=self.root)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
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
            if not isinstance(raw, dict):
                raise ValueError("fields")
            schema = raw.get("schema")
            legacy_fields = {
                "schema", "deployment_id", "revision", "label", "components", "peer_binding"
            }
            v2_fields = legacy_fields | {"composition_binding"}
            v3_fields = v2_fields | {"preserved_components", "historical_peer_binding"}
            if (
                schema == MANAGED_DEPLOYMENT_SCHEMA_V1 and set(raw) != legacy_fields
            ) or (
                schema == MANAGED_DEPLOYMENT_SCHEMA_V2 and set(raw) != v2_fields
            ) or (
                schema == MANAGED_DEPLOYMENT_SCHEMA_V3 and set(raw) != v3_fields
            ) or schema not in {
                MANAGED_DEPLOYMENT_SCHEMA_V1, MANAGED_DEPLOYMENT_SCHEMA_V2,
                MANAGED_DEPLOYMENT_SCHEMA_V3,
            }:
                raise ValueError("fields")
            components_raw = raw["components"]
            if not isinstance(components_raw, list):
                raise ValueError("components")
            components = tuple(
                ManagedComponentBinding(**item) if isinstance(item, dict)
                and set(item) == {"component", "instance_id", "receipt_reference"}
                else (_ for _ in ()).throw(ValueError("component"))
                for item in components_raw
            )
            preserved_raw = raw["preserved_components"] if schema == MANAGED_DEPLOYMENT_SCHEMA_V3 else []
            if not isinstance(preserved_raw, list):
                raise ValueError("preserved_components")
            preserved = tuple(
                ManagedPreservedComponentBinding(**item) if isinstance(item, dict)
                and set(item) == {
                    "component", "instance_id", "previous_receipt_reference",
                    "preserve_operation_id", "preserve_receipt_digest",
                    "version", "source_revision", "artifact_digest",
                    "forge_runtime_id", "forge_installation_id",
                } else (_ for _ in ()).throw(ValueError("preserved component"))
                for item in preserved_raw
            )
            peer_raw = raw["peer_binding"]
            peer = None if peer_raw is None else ManagedPeerBinding(**peer_raw)
            composition = None
            if schema in {MANAGED_DEPLOYMENT_SCHEMA_V2, MANAGED_DEPLOYMENT_SCHEMA_V3}:
                composition_raw = raw["composition_binding"]
                if not isinstance(composition_raw, dict):
                    raise ValueError("composition_binding")
                composition = ManagedCompositionBinding(**composition_raw)
            historical_raw = raw["historical_peer_binding"] if schema == MANAGED_DEPLOYMENT_SCHEMA_V3 else None
            historical = None if historical_raw is None else ManagedPeerBinding(**historical_raw)
            record_type = (
                ManagedPreservedDeployment if schema == MANAGED_DEPLOYMENT_SCHEMA_V3
                else ManagedDeployment
            )
            deployment = record_type(
                deployment_id=raw["deployment_id"],
                revision=raw["revision"],
                label=raw["label"],
                components=components,
                peer_binding=peer,
                schema=schema,
                composition_binding=composition,
                **({
                    "preserved_components": preserved,
                    "historical_peer_binding": historical,
                } if schema == MANAGED_DEPLOYMENT_SCHEMA_V3 else {}),
            )
        except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
            raise ManagedDeploymentError("managed deployment record is invalid") from error
        if deployment.deployment_id != path.stem:
            raise ManagedDeploymentError("managed deployment identity does not match its record path")
        return deployment
