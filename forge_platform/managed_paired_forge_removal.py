"""Remove Forge from one paired deployment while retaining a ready EP instance.

EP's product-owned consumer revocation is durably committed first. The existing
component/deployment saga owns Forge uninstall and registry CAS; this wrapper
adds exact terminal product and retained-EP checks before that CAS.
"""

from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
import re

from .component_operations import (
    ComponentOperationRequest, ProductInstallationReadback, ProductOperationAdapter,
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
from .managed_pairing_revocation import (
    EPConsumerRevoker, ManagedPairingRevocationCoordinator,
    _digest as paired_digest,
    _read as read_pairing_revocation,
)
from .qualified_forge_lifecycle import qualified_forge_lifecycle_artifact


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_FORGE_RECEIPT = re.compile(r"^forge-uninstall:sha256:[0-9a-f]{64}$")


class ManagedPairedForgeRemovalError(RuntimeError):
    """Paired Forge removal lacks exact product or registry authority."""


def _require_retained_ep(
    request: ComponentOperationRequest, adapter: ProductOperationAdapter,
) -> None:
    observed = adapter.readback(request)
    if (
        not isinstance(observed, ProductInstallationReadback)
        or observed.component != EP_COMPONENT
        or observed.installation_identity != request.installation_identity
        or observed.selected_instance_identity != request.installation_identity
        or observed.state != "ACTIVE"
        or observed.health_state != "HEALTHY"
        or observed.inventory_coverage != "MACHINE_WIDE"
        or observed.conflict_state != "NONE"
        or observed.artifact != request.artifact.correlation
        or observed.health_evidence_reference is None
    ):
        raise ManagedPairedForgeRemovalError("retained EP lacks exact healthy readback")


def _require_terminal_forge(
    request: ComponentOperationRequest, adapter: ProductOperationAdapter,
    component_store: DurableComponentOperationCoordinator,
) -> str:
    record = component_store._read(
        component_store._operation_directory(request.operation_id) / "record.json",
        request.operation_id,
    )
    observed = adapter.readback(request)
    if (
        record is None
        or record.request_fingerprint != request.fingerprint()
        or record.artifact != request.artifact
        or record.product_receipt.state != "COMPLETED"
        or record.product_receipt.component != FORGE_COMPONENT
        or record.product_receipt.installation_identity != request.installation_identity
        or not isinstance(observed, ProductInstallationReadback)
        or observed.component != FORGE_COMPONENT
        or observed.installation_identity != request.installation_identity
        or observed.state != "ABSENT"
        or observed.selected_instance_identity is not None
        or observed.inventory_coverage != "MACHINE_WIDE"
        or observed.conflict_state != "NONE"
        or record.product_receipt.evidence_reference != observed.evidence_reference
        or record.postflight.evidence_reference != observed.evidence_reference
        or _FORGE_RECEIPT.fullmatch(observed.evidence_reference) is None
    ):
        raise ManagedPairedForgeRemovalError("Forge uninstall lacks exact terminal evidence")
    return observed.evidence_reference


class _PairedRegistry:
    """Verify both products and the same pairing intent just before CAS."""

    def __init__(
        self, *, delegate: _CurrencyGuardedRegistry,
        registry: ManagedDeploymentRegistry, reviewed: ManagedDeployment,
        desired: ManagedDeployment, plan: ManagedDeploymentPlan, operation_id: str,
        revocation: ManagedPairingRevocationCoordinator,
        revoker: EPConsumerRevoker,
        forge_request: ComponentOperationRequest, forge_adapter: ProductOperationAdapter,
        ep_request: ComponentOperationRequest, ep_adapter: ProductOperationAdapter,
        component_store: DurableComponentOperationCoordinator,
    ) -> None:
        self.delegate = delegate
        self.registry = registry
        self.reviewed = reviewed
        self.desired = desired
        self.plan = plan
        self.operation_id = operation_id
        self.revocation = revocation
        self.revoker = revoker
        self.forge_request = forge_request
        self.forge_adapter = forge_adapter
        self.ep_request = ep_request
        self.ep_adapter = ep_adapter
        self.component_store = component_store

    def load(self, deployment_id: str):
        return self.registry.load(deployment_id)

    def inventory(self):
        return self.registry.inventory()

    def replace(self, deployment: ManagedDeployment, *, expected_revision: int):
        if (
            self.registry.load(self.reviewed.deployment_id) != self.reviewed
            or self.reviewed not in self.registry.inventory()
            or expected_revision != self.reviewed.revision
            or deployment.deployment_id != self.desired.deployment_id
            or deployment.revision != self.reviewed.revision + 1
            or deployment.by_component.keys() != self.desired.by_component.keys()
            or deployment.by_component[EP_COMPONENT].instance_id
            != self.desired.by_component[EP_COMPONENT].instance_id
            or deployment.by_component[EP_COMPONENT].receipt_reference
            != self.reviewed.by_component[EP_COMPONENT].receipt_reference
            or deployment.peer_binding is not None
            or deployment.schema != self.desired.schema
            or deployment.composition_binding != self.desired.composition_binding
        ):
            raise ManagedPairedForgeRemovalError("paired registry target changed before commit")
        _require_revocation(
            self.revocation, self.operation_id, self.plan, self.reviewed, self.revoker,
        )
        _require_terminal_forge(self.forge_request, self.forge_adapter, self.component_store)
        _require_retained_ep(self.ep_request, self.ep_adapter)
        return self.delegate.replace(deployment, expected_revision=expected_revision)


def _require_revocation(
    coordinator: ManagedPairingRevocationCoordinator,
    operation_id: str, plan: ManagedDeploymentPlan,
    reviewed: ManagedDeployment, revoker: EPConsumerRevoker,
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
        or revoker.scope != scope
        or revoker.provisioner.target.instance_id != peer.ep_instance_id
    ):
        raise ManagedPairedForgeRemovalError("paired consumer revocation is not terminal")
    observed = revoker.status()
    if (
        observed.get("consumer_id") != scope.consumer_id
        or observed.get("project_id") != scope.project_id
        or observed.get("status") != "REVOKED"
        or not observed.get("revoked_at")
        or revoker.revoke() != record.receipt_reference
    ):
        raise ManagedPairedForgeRemovalError("paired consumer revocation readback changed")


class ManagedPairedForgeComponentRemovalCoordinator:
    """Run one Forge REMOVE_COMPONENT after exact EP consumer revocation."""

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
        forge_request: ComponentOperationRequest,
        forge_adapter: ProductOperationAdapter,
        ep_readback_request: ComponentOperationRequest,
        ep_adapter: ProductOperationAdapter,
        revoker: EPConsumerRevoker,
    ) -> ManagedDeploymentExecutionRecord:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise ManagedPairedForgeRemovalError("paired removal operation id is invalid")
        if (
            not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or reviewed_current.peer_binding is None
            or plan.deployment_action != "CREATE_OR_UPDATE"
            or plan.current_revision != reviewed_current.revision
            or plan.desired is None
            or plan.desired.peer_binding is not None
            or set(plan.desired.by_component) != {EP_COMPONENT}
            or plan.desired.schema != reviewed_current.schema
            or plan.desired.composition_binding != reviewed_current.composition_binding
            or ManagedDeploymentPlanner.plan(reviewed_current, plan.desired) != plan
            or {diff.component: diff.action for diff in plan.component_diffs}
            != {FORGE_COMPONENT: "REMOVE_COMPONENT", EP_COMPONENT: "NO_CHANGE"}
            or forge_request.component != FORGE_COMPONENT
            or forge_request.kind != "remove"
            or forge_request.installation_identity != reviewed_current.peer_binding.forge_instance_id
            or forge_request.product_request
            or not qualified_forge_lifecycle_artifact(forge_request.artifact)
            or ep_readback_request.component != EP_COMPONENT
            or ep_readback_request.kind != "repair"
            or ep_readback_request.installation_identity != reviewed_current.peer_binding.ep_instance_id
            or ep_readback_request.product_request
            or ep_readback_request.artifact.version != "2.3.104"
            or ep_readback_request.artifact.source_revision
            != "cfce69892278ee2b6c14412c171f5f33596acb0e"
            or ep_readback_request.artifact.digest
            != "sha256:3f7822fd081598f81d5c666200787a3b2182d7004c078cc36ec20455269909cb"
        ):
            raise ManagedPairedForgeRemovalError("reviewed paired Forge removal changed")
        support = getattr(forge_adapter, "removal_support", None)
        if not callable(support) or support() != "SUPPORTED":
            raise ManagedPairedForgeRemovalError("Forge product uninstall is unavailable")
        coordinator = ManagedDeploymentOperationCoordinator(
            operations_root=self.operations_root / "deployment-saga",
            component_operations_root=self.component_operations_root,
            registry=self.registry,
        )
        current = self.registry.load(plan.deployment_id)
        if current == reviewed_current:
            self.revocation.revoke(
                operation_id, plan, reviewed_current=reviewed_current,
                revoker=revoker,
            )
            currency = _CurrencyEvidence(self.currency_guard)
            guarded_forge = _ExactRemovalAdapter(
                forge_adapter, currency, self.registry, reviewed_current,
            )
            guarded_registry = _CurrencyGuardedRegistry(self.registry, currency, operation_id)
            coordinator.registry = _PairedRegistry(
                delegate=guarded_registry,
                registry=self.registry,
                reviewed=reviewed_current,
                desired=plan.desired,
                plan=plan,
                operation_id=operation_id,
                revocation=self.revocation,
                revoker=revoker,
                forge_request=forge_request,
                forge_adapter=forge_adapter,
                ep_request=ep_readback_request,
                ep_adapter=ep_adapter,
                component_store=coordinator.component_coordinator,
            )
        else:
            prior = coordinator._read(coordinator._record_path(operation_id))
            if (
                prior is None or prior.state != "COMPLETE"
                or prior.deployment_id != plan.deployment_id
                or prior.plan_fingerprint != coordinator._plan_fingerprint(plan)
                or current is None
                or current.revision != reviewed_current.revision + 1
                or current.by_component.keys() != plan.desired.by_component.keys()
                or current.by_component[EP_COMPONENT].instance_id
                != plan.desired.by_component[EP_COMPONENT].instance_id
                or current.peer_binding is not None
                or current.schema != plan.desired.schema
                or current.composition_binding != plan.desired.composition_binding
            ):
                raise ManagedPairedForgeRemovalError("paired removal lacks exact prior completion")
            guarded_forge = forge_adapter
        result = coordinator.execute(
            operation_id, plan,
            requests={FORGE_COMPONENT: forge_request},
            adapters={FORGE_COMPONENT: guarded_forge},
        )
        if result.state == "COMPLETE":
            _require_revocation(
                self.revocation, operation_id, plan, reviewed_current, revoker,
            )
            _require_terminal_forge(
                forge_request, forge_adapter, coordinator.component_coordinator,
            )
            _require_retained_ep(ep_readback_request, ep_adapter)
            final = self.registry.load(plan.deployment_id)
            if (
                final is None or final.revision != reviewed_current.revision + 1
                or set(final.by_component) != {EP_COMPONENT}
                or final.by_component[EP_COMPONENT].instance_id
                != plan.desired.by_component[EP_COMPONENT].instance_id
                or final.peer_binding is not None
                or final.schema != plan.desired.schema
                or final.composition_binding != plan.desired.composition_binding
            ):
                raise ManagedPairedForgeRemovalError("paired removal registry commit is invalid")
        return result
