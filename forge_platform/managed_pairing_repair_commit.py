"""Commit only product-proven Forge↔EP repair evidence to one deployment.

The reviewed desired peer receipt is a provisional intent marker. The durable
product stage yields the actual configuration, authenticated preflight and EP
readiness references. Those alone form the committed opaque pairing receipt.
"""

from __future__ import annotations

from dataclasses import replace

from .component_operations import ComponentOperationRequest
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .forge_ep_pairing_executor import ForgeEPProductPairingBinding
from .forge_server_adapter import ForgeServerProductAdapter
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentError, ManagedDeploymentPlan,
    ManagedDeploymentPlanner, ManagedDeploymentRegistry, ManagedPeerBinding,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .managed_pairing import ManagedPairingEvidence
from .managed_pairing_repair_execution import ManagedPairingRepairExecutionCoordinator
from .managed_pairing_revocation import EPConsumerRevoker


class ManagedPairingRepairCommitError(RuntimeError):
    """Exact terminal product repair cannot be committed or replayed."""


class ManagedPairingRepairCommitCoordinator:
    """CAS the selected registry entry after independent product readback."""

    def __init__(
        self, *, registry: ManagedDeploymentRegistry,
        execution: ManagedPairingRepairExecutionCoordinator,
    ) -> None:
        if (
            not isinstance(registry, ManagedDeploymentRegistry)
            or not isinstance(execution, ManagedPairingRepairExecutionCoordinator)
            or execution.registry is not registry
        ):
            raise TypeError("exact repair execution and registry authority are required")
        self.registry = registry
        self.execution = execution

    def commit(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment, old_binding: ForgeEPProductPairingBinding,
        new_binding: ForgeEPProductPairingBinding,
        revoker: EPConsumerRevoker, forge_adapter: ForgeServerProductAdapter,
        ep_adapter: EngineeringPlatformSystemProvisionerAdapter,
        forge_request: ComponentOperationRequest, ep_request: ComponentOperationRequest,
    ) -> ManagedDeployment:
        desired = getattr(plan, "desired", None)
        peer = getattr(reviewed_current, "peer_binding", None)
        if (
            not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment) or peer is None
            or not isinstance(desired, ManagedDeployment)
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
        ):
            raise ManagedPairingRepairCommitError("reviewed repair commit target changed")
        current = self.registry.load(plan.deployment_id)
        if current == reviewed_current:
            self.execution.replace_peer(
                operation_id, plan, reviewed_current=reviewed_current,
                old_binding=old_binding, new_binding=new_binding,
                revoker=revoker, forge_adapter=forge_adapter, ep_adapter=ep_adapter,
                forge_request=forge_request, ep_request=ep_request,
                credential_reference=new_binding.credential_reference,
            )
        terminal = self.execution.read_terminal(
            operation_id, plan, reviewed_current=reviewed_current,
            old_binding=old_binding, new_binding=new_binding,
            forge_adapter=forge_adapter, ep_adapter=ep_adapter,
            forge_request=forge_request, ep_request=ep_request,
        )
        evidence = ManagedPairingEvidence(
            peer.forge_instance_id, peer.ep_instance_id,
            terminal.forge_configuration_reference,
            terminal.forge_preflight_reference,
            terminal.ep_readiness_reference,
        )
        committed = replace(
            reviewed_current, revision=reviewed_current.revision + 1,
            peer_binding=ManagedPeerBinding(
                peer.forge_instance_id, peer.ep_instance_id,
                evidence.receipt_reference,
            ),
        )
        if self.registry.load(plan.deployment_id) == committed:
            return committed
        if self.registry.load(plan.deployment_id) != reviewed_current:
            raise ManagedPairingRepairCommitError("reviewed deployment changed before repair commit")
        try:
            return self.registry.replace(committed, expected_revision=reviewed_current.revision)
        except ManagedDeploymentError as error:
            raise ManagedPairingRepairCommitError("reviewed deployment changed during repair commit") from error
