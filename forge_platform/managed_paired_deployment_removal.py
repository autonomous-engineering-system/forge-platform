"""Exact full Forge+EP deployment removal over product-owned lifecycle routes.

The EP consumer scope is revoked first. EP and Forge then own their respective
instance removals. EP's terminal product receipt remains verifiable after its
instance data root is gone, so a crash between EP and Forge can resume without
reopening a missing EP consumer database or broadening target authority.
"""

from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
import re

from .component_operations import (
    ComponentOperationRequest, ProductInstallationReadback,
    ProductOperationAdapter, ProductOperationReceipt,
)
from .durable_component_operations import DurableComponentOperationCoordinator
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from .managed_forge_removal import _ExactRemovalAdapter
from .managed_install_flow import (
    EP_COMPONENT, FORGE_COMPONENT, InstallerMutationCurrencyGuard,
    _CurrencyEvidence, _CurrencyGuardedRegistry,
)
from .managed_installer import (
    ManagedDeploymentExecutionRecord, ManagedDeploymentOperationCoordinator,
)
from .managed_paired_forge_removal import _require_terminal_forge
from .managed_pairing_revocation import (
    EPConsumerRevoker, ManagedPairingRevocationCoordinator,
    _digest as paired_digest, _read as read_pairing_revocation,
)


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_EP_RECEIPT = re.compile(r"^ep-receipt:sha256:[0-9a-f]{64}$")


class ManagedPairedDeploymentRemovalError(RuntimeError):
    """The selected full removal lacks exact terminal product evidence."""


def _require_terminal_ep(
    request: ComponentOperationRequest, adapter: ProductOperationAdapter,
    component_store: DurableComponentOperationCoordinator,
) -> str:
    record = component_store._read(
        component_store._operation_directory(request.operation_id) / "record.json",
        request.operation_id,
    )
    if (
        record is None
        or record.request_fingerprint != request.fingerprint()
        or record.artifact != request.artifact
        or record.product_receipt.state != "COMPLETED"
        or record.product_receipt.component != EP_COMPONENT
        or record.product_receipt.installation_identity != request.installation_identity
        or _EP_RECEIPT.fullmatch(record.product_receipt.evidence_reference) is None
    ):
        raise ManagedPairedDeploymentRemovalError("EP remove lacks exact component journal")
    observed = adapter.readback(request)
    if (
        not isinstance(observed, ProductInstallationReadback)
        or observed.component != EP_COMPONENT
        or observed.installation_identity != request.installation_identity
        or observed.state != "ABSENT"
        or observed.selected_instance_identity is not None
        or observed.inventory_coverage != "MACHINE_WIDE"
        or observed.conflict_state != "NONE"
    ):
        raise ManagedPairedDeploymentRemovalError("EP remove lacks exact ABSENT readback")
    repeated = adapter.resume(request, record.product_receipt)
    if (
        not isinstance(repeated, ProductOperationReceipt)
        or repeated.product_operation_id != request.operation_id
        or repeated.component != EP_COMPONENT
        or repeated.installation_identity != request.installation_identity
        or repeated.artifact != request.artifact.correlation
        or repeated.state != "COMPLETED"
        or repeated.evidence_reference != record.product_receipt.evidence_reference
    ):
        raise ManagedPairedDeploymentRemovalError("EP product terminal receipt changed")
    return repeated.evidence_reference


def _require_revocation_record(
    coordinator: ManagedPairingRevocationCoordinator,
    operation_id: str, plan: ManagedDeploymentPlan,
    reviewed: ManagedDeployment,
) -> None:
    record = read_pairing_revocation(
        coordinator.operations_root / f"{operation_id}.json",
        owner_uid=coordinator.expected_owner_uid,
    )
    peer = reviewed.peer_binding
    scope = coordinator.scope_claims.get(reviewed.deployment_id)
    if (
        record is None or peer is None or scope is None
        or record.state != "COMPLETE"
        or record.operation_id != operation_id
        or record.deployment_id != reviewed.deployment_id
        or record.plan_fingerprint != paired_digest(asdict(plan))
        or record.reviewed_deployment_fingerprint != paired_digest(asdict(reviewed))
        or record.forge_instance_id != peer.forge_instance_id
        or record.ep_instance_id != peer.ep_instance_id
        or (record.consumer_id, record.project_id)
        != (scope.consumer_id, scope.project_id)
    ):
        raise ManagedPairedDeploymentRemovalError("paired consumer revocation intent is not terminal")


class _FullRemovalRegistry:
    """Check both product removals before the exact deployment CAS."""

    def __init__(
        self, *, delegate: _CurrencyGuardedRegistry,
        registry: ManagedDeploymentRegistry, reviewed: ManagedDeployment,
        operation_id: str, plan: ManagedDeploymentPlan,
        revocation: ManagedPairingRevocationCoordinator,
        forge_request: ComponentOperationRequest, forge_adapter: ProductOperationAdapter,
        ep_request: ComponentOperationRequest, ep_adapter: ProductOperationAdapter,
        component_store: DurableComponentOperationCoordinator,
    ) -> None:
        self.delegate = delegate
        self.registry = registry
        self.reviewed = reviewed
        self.operation_id = operation_id
        self.plan = plan
        self.revocation = revocation
        self.forge_request = forge_request
        self.forge_adapter = forge_adapter
        self.ep_request = ep_request
        self.ep_adapter = ep_adapter
        self.component_store = component_store

    def load(self, deployment_id: str):
        return self.registry.load(deployment_id)

    def inventory(self):
        return self.registry.inventory()

    def remove(self, deployment_id: str, *, expected_revision: int):
        if (
            deployment_id != self.reviewed.deployment_id
            or expected_revision != self.reviewed.revision
            or self.registry.load(deployment_id) != self.reviewed
            or self.reviewed not in self.registry.inventory()
        ):
            raise ManagedPairedDeploymentRemovalError("paired removal registry target changed")
        _require_terminal_ep(self.ep_request, self.ep_adapter, self.component_store)
        _require_revocation_record(self.revocation, self.operation_id, self.plan, self.reviewed)
        _require_terminal_forge(self.forge_request, self.forge_adapter, self.component_store)
        return self.delegate.remove(deployment_id, expected_revision=expected_revision)


class ManagedPairedDeploymentRemovalCoordinator:
    """Remove only the reviewed paired deployment with crash-safe EP-first order."""

    def __init__(
        self, *, operations_root: Path, component_operations_root: Path,
        registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
        revocation: ManagedPairingRevocationCoordinator,
    ) -> None:
        if not operations_root.is_absolute() or not component_operations_root.is_absolute():
            raise ValueError("paired removal operation roots must be absolute")
        self.operations_root = operations_root
        self.component_operations_root = component_operations_root
        self.registry = registry
        self.currency_guard = currency_guard
        self.revocation = revocation

    def remove(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment,
        forge_request: ComponentOperationRequest, forge_adapter: ProductOperationAdapter,
        ep_request: ComponentOperationRequest, ep_adapter: ProductOperationAdapter,
        revoker: EPConsumerRevoker,
    ) -> ManagedDeploymentExecutionRecord:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise ManagedPairedDeploymentRemovalError("paired removal operation id is invalid")
        if (
            not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or reviewed_current.peer_binding is None
            or plan.deployment_action != "REMOVE_DEPLOYMENT"
            or plan.desired is not None
            or plan.current_revision != reviewed_current.revision
            or ManagedDeploymentPlanner.plan(reviewed_current, None) != plan
            or {diff.component: diff.action for diff in plan.component_diffs}
            != {FORGE_COMPONENT: "REMOVE_COMPONENT", EP_COMPONENT: "REMOVE_COMPONENT"}
            or forge_request.component != FORGE_COMPONENT
            or forge_request.kind != "remove"
            or forge_request.installation_identity != reviewed_current.peer_binding.forge_instance_id
            or forge_request.product_request
            or forge_request.artifact.version != "2.7.35"
            or forge_request.artifact.source_revision
            != "ff4c0d45f51161376104250cd6efcfb6f045b8ac"
            or ep_request.component != EP_COMPONENT
            or ep_request.kind != "remove"
            or ep_request.installation_identity != reviewed_current.peer_binding.ep_instance_id
            or ep_request.product_request
            or ep_request.artifact.version != "2.3.102"
            or ep_request.artifact.source_revision
            != "cab85a84a6a8b5b574c796713e4363781fc05519"
        ):
            raise ManagedPairedDeploymentRemovalError("reviewed paired deployment removal changed")
        support = getattr(forge_adapter, "removal_support", None)
        if not callable(support) or support() != "SUPPORTED":
            raise ManagedPairedDeploymentRemovalError("Forge product uninstall is unavailable")
        coordinator = ManagedDeploymentOperationCoordinator(
            operations_root=self.operations_root / "deployment-saga",
            component_operations_root=self.component_operations_root,
            registry=self.registry,
        )
        current = self.registry.load(plan.deployment_id)
        if current == reviewed_current:
            ep_record = coordinator.component_coordinator._read(
                coordinator.component_coordinator._operation_directory(ep_request.operation_id) / "record.json",
                ep_request.operation_id,
            )
            if ep_record is not None and ep_record.product_receipt.state == "COMPLETED":
                _require_terminal_ep(ep_request, ep_adapter, coordinator.component_coordinator)
                _require_revocation_record(self.revocation, operation_id, plan, reviewed_current)
            else:
                observed_ep = ep_adapter.readback(ep_request)
                if (
                    not isinstance(observed_ep, ProductInstallationReadback)
                    or observed_ep.component != EP_COMPONENT
                    or observed_ep.installation_identity != ep_request.installation_identity
                    or observed_ep.selected_instance_identity != ep_request.installation_identity
                    or observed_ep.state != "ACTIVE"
                    or observed_ep.health_state != "HEALTHY"
                    or observed_ep.artifact != ep_request.artifact.correlation
                    or observed_ep.inventory_coverage != "MACHINE_WIDE"
                    or observed_ep.conflict_state != "NONE"
                ):
                    raise ManagedPairedDeploymentRemovalError(
                        "EP removal has no safe resumable product journal"
                    )
                self.revocation.revoke(
                    operation_id, plan, reviewed_current=reviewed_current,
                    revoker=revoker,
                )
            currency = _CurrencyEvidence(self.currency_guard)
            guarded_adapters = {
                EP_COMPONENT: _ExactRemovalAdapter(
                    ep_adapter, currency, self.registry, reviewed_current,
                ),
                FORGE_COMPONENT: _ExactRemovalAdapter(
                    forge_adapter, currency, self.registry, reviewed_current,
                ),
            }
            guarded_registry = _CurrencyGuardedRegistry(self.registry, currency, operation_id)
            coordinator.registry = _FullRemovalRegistry(
                delegate=guarded_registry, registry=self.registry,
                reviewed=reviewed_current, operation_id=operation_id,
                plan=plan, revocation=self.revocation,
                forge_request=forge_request, forge_adapter=forge_adapter,
                ep_request=ep_request, ep_adapter=ep_adapter,
                component_store=coordinator.component_coordinator,
            )
        else:
            prior = coordinator._read(coordinator._record_path(operation_id))
            if (
                current is not None
                or prior is None or prior.state != "COMPLETE"
                or prior.deployment_id != plan.deployment_id
                or prior.plan_fingerprint != coordinator._plan_fingerprint(plan)
            ):
                raise ManagedPairedDeploymentRemovalError("paired removal lacks exact prior completion")
            guarded_adapters = {EP_COMPONENT: ep_adapter, FORGE_COMPONENT: forge_adapter}
        result = coordinator.execute(
            operation_id, plan,
            requests={EP_COMPONENT: ep_request, FORGE_COMPONENT: forge_request},
            adapters=guarded_adapters,
        )
        if result.state == "COMPLETE":
            _require_terminal_ep(ep_request, ep_adapter, coordinator.component_coordinator)
            _require_revocation_record(self.revocation, operation_id, plan, reviewed_current)
            _require_terminal_forge(forge_request, forge_adapter, coordinator.component_coordinator)
            if self.registry.load(plan.deployment_id) is not None:
                raise ManagedPairedDeploymentRemovalError("selected deployment remains registered")
        return result
