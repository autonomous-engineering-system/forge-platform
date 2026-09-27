"""Exact Forge-only removal over the existing durable product/deployment saga.

Paired Forge+EP removal needs a separately qualified product-owned pairing
reconciliation boundary. This route admits only an unpaired Forge deployment.
"""

from __future__ import annotations

from pathlib import Path
import re

from .component_operations import (
    ComponentOperationRequest, ProductInstallationReadback, ProductOperationAdapter,
)
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedDeploymentRegistry,
)
from .managed_install_flow import (
    FORGE_COMPONENT, InstallerMutationCurrencyGuard, _CurrencyEvidence,
    _CurrencyGuardedAdapter, _CurrencyGuardedRegistry,
)
from .managed_installer import (
    ManagedDeploymentExecutionRecord, ManagedDeploymentOperationCoordinator,
)


_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_TERMINAL_FORGE_RECEIPT = re.compile(r"^forge-uninstall:sha256:[0-9a-f]{64}$")


class ManagedForgeRemovalError(RuntimeError):
    """The selected Forge-only removal cannot safely make progress."""


class _ExactRemovalAdapter(_CurrencyGuardedAdapter):
    def __init__(
        self, delegate: ProductOperationAdapter, evidence: _CurrencyEvidence,
        registry: ManagedDeploymentRegistry, current: ManagedDeployment,
    ) -> None:
        super().__init__(delegate, evidence, current.deployment_id)
        self.registry = registry
        self.current = current

    def _require_target(self) -> None:
        inventory = self.registry.inventory()
        selected = [item for item in inventory if item.deployment_id == self.current.deployment_id]
        if selected != [self.current]:
            raise ManagedForgeRemovalError("reviewed Forge removal target changed")

    def execute(self, request: ComponentOperationRequest):
        self._require_target()
        return super().execute(request)

    def resume(self, request: ComponentOperationRequest, prior_receipt):
        self._require_target()
        return super().resume(request, prior_receipt)


class ManagedForgeOnlyRemovalCoordinator:
    """Remove one unpaired Forge deployment with exact product terminal proof."""

    def __init__(
        self, *, operations_root: Path, component_operations_root: Path,
        registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
    ) -> None:
        if not operations_root.is_absolute() or not component_operations_root.is_absolute():
            raise ValueError("Forge removal operation roots must be absolute")
        self.operations_root = operations_root.resolve(strict=False)
        self.component_operations_root = component_operations_root.resolve(strict=False)
        self.registry = registry
        self.currency_guard = currency_guard

    def remove(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        request: ComponentOperationRequest, adapter: ProductOperationAdapter,
    ) -> ManagedDeploymentExecutionRecord:
        if not isinstance(operation_id, str) or _OPERATION_ID.fullmatch(operation_id) is None:
            raise ManagedForgeRemovalError("Forge removal operation identity is invalid")
        if not isinstance(plan, ManagedDeploymentPlan) or (
            plan.deployment_action != "REMOVE_DEPLOYMENT"
            or plan.desired is not None or plan.current_revision is None
            or len(plan.component_diffs) != 1
            or plan.component_diffs[0].component != FORGE_COMPONENT
            or plan.component_diffs[0].action != "REMOVE_COMPONENT"
        ):
            raise ManagedForgeRemovalError("reviewed plan is not Forge-only removal")
        diff = plan.component_diffs[0]
        if (
            not isinstance(request, ComponentOperationRequest)
            or request.kind != "remove"
            or request.component != FORGE_COMPONENT
            or request.installation_identity != diff.instance_id
            or request.requested_role not in {"server", "runtime"}
            or request.product_request
        ):
            raise ManagedForgeRemovalError("Forge uninstall request changed the reviewed target")
        support = getattr(adapter, "removal_support", None)
        if not callable(support) or support() != "SUPPORTED":
            raise ManagedForgeRemovalError("Forge product-owned uninstall is unavailable")

        coordinator = ManagedDeploymentOperationCoordinator(
            operations_root=self.operations_root / "deployment-saga",
            component_operations_root=self.component_operations_root,
            registry=self.registry,
        )
        current = self.registry.load(plan.deployment_id)
        if current is None:
            prior = coordinator._read(coordinator._record_path(operation_id))
            if (
                prior is None or prior.state != "COMPLETE"
                or prior.deployment_id != plan.deployment_id
                or prior.plan_fingerprint != coordinator._plan_fingerprint(plan)
            ):
                raise ManagedForgeRemovalError("Forge removal lacks a terminal prior operation")
            guarded_adapter = adapter
        else:
            inventory = self.registry.inventory()
            if (
                current not in inventory
                or current.revision != plan.current_revision
                or set(current.by_component) != {FORGE_COMPONENT}
                or current.peer_binding is not None
                or ManagedDeploymentPlanner.plan(current, None) != plan
            ):
                raise ManagedForgeRemovalError("reviewed Forge-only deployment changed")
            currency = _CurrencyEvidence(self.currency_guard)
            guarded_adapter = _ExactRemovalAdapter(adapter, currency, self.registry, current)
            coordinator.registry = _CurrencyGuardedRegistry(
                self.registry, currency, operation_id
            )

        record = coordinator.execute(
            operation_id, plan,
            requests={FORGE_COMPONENT: request},
            adapters={FORGE_COMPONENT: guarded_adapter},
        )
        if record.state == "COMPLETE":
            receipt = record.components[0].receipt_reference
            component_store = coordinator.component_coordinator
            component_record = component_store._read(
                component_store._operation_directory(request.operation_id) / "record.json",
                request.operation_id,
            )
            observed = adapter.readback(request)
            if (
                component_record is None
                or component_record.request_fingerprint != request.fingerprint()
                or component_record.artifact != request.artifact
                or component_record.product_receipt.state != "COMPLETED"
                or component_record.product_receipt.evidence_reference != receipt
                or component_record.postflight.evidence_reference != receipt
                or not isinstance(observed, ProductInstallationReadback)
                or observed.component != FORGE_COMPONENT
                or observed.installation_identity != diff.instance_id
                or observed.state != "ABSENT"
                or observed.selected_instance_identity is not None
                or observed.inventory_coverage != "MACHINE_WIDE"
                or observed.conflict_state != "NONE"
                or receipt is None
                or _TERMINAL_FORGE_RECEIPT.fullmatch(receipt) is None
                or observed.evidence_reference != receipt
                or self.registry.load(plan.deployment_id) is not None
            ):
                raise ManagedForgeRemovalError(
                    "Forge removal lacks exact product terminal readback"
                )
        return record
