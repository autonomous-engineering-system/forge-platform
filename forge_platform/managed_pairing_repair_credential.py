"""Bind a new EP credential to the reviewed, product-owned repair sequence.

The detach, old-consumer revoke and credential issue stages each keep their
own durable journal under the same operation ID. This boundary adds no secret
transport or independent mutation authority.
"""

from __future__ import annotations

from dataclasses import asdict
from hashlib import sha256
import json

from .forge_ep_pairing_executor import ForgeEPProductPairingBinding
from .forge_server_adapter import ForgeServerProductAdapter
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
)
from .managed_ep_credential_issuance import (
    EPCredentialIssueRecord, ManagedEPCredentialIssuanceCoordinator,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .managed_pairing_detach import ManagedPairingRepairDetachCoordinator
from .managed_pairing_revocation import (
    EPConsumerRevoker, ManagedPairingRepairRevocationCoordinator,
)


class ManagedPairingRepairCredentialError(RuntimeError):
    """The reviewed same-instance repair cannot advance to a new credential."""


class ManagedPairingRepairCredentialCoordinator:
    """Advance only the exact reviewed repair through old revoke and new issue."""

    def __init__(
        self, *, revocation: ManagedPairingRepairRevocationCoordinator,
        issuance: ManagedEPCredentialIssuanceCoordinator,
    ) -> None:
        if (
            not isinstance(revocation, ManagedPairingRepairRevocationCoordinator)
            or not isinstance(issuance, ManagedEPCredentialIssuanceCoordinator)
            or revocation.registry is not issuance.registry
            or revocation.currency_guard is not issuance.currency_guard
            or revocation.operations_root == issuance.operations_root
        ):
            raise TypeError("shared exact repair authority and distinct journals are required")
        self.revocation = revocation
        self.issuance = issuance

    def issue_after_revoke(
        self, operation_id: str, plan: ManagedDeploymentPlan, *,
        reviewed_current: ManagedDeployment, revoker: EPConsumerRevoker,
        detach_coordinator: ManagedPairingRepairDetachCoordinator,
        forge_adapter: ForgeServerProductAdapter,
        old_binding: ForgeEPProductPairingBinding,
        credential_reference: str,
    ) -> EPCredentialIssueRecord:
        peer = getattr(reviewed_current, "peer_binding", None)
        desired = getattr(plan, "desired", None)
        registration = self.issuance.registration
        new_scope = registration.new.scope
        old_scope = registration.old.scope
        if (
            not isinstance(plan, ManagedDeploymentPlan)
            or not isinstance(reviewed_current, ManagedDeployment)
            or peer is None or not isinstance(desired, ManagedDeployment)
            or desired.deployment_id != reviewed_current.deployment_id
            or desired.revision != reviewed_current.revision + 1
            or desired.components != reviewed_current.components
            or desired.peer_binding is None
            or desired.peer_binding == peer
            or desired.peer_binding.forge_instance_id != peer.forge_instance_id
            or desired.peer_binding.ep_instance_id != peer.ep_instance_id
            or ManagedDeploymentPlanner.plan(
                reviewed_current, desired,
                product_actions={FORGE_COMPONENT: "REPAIR", EP_COMPONENT: "NO_CHANGE"},
            ) != plan
            or self.revocation.scope_claims.get(plan.deployment_id) != old_scope
            or self.issuance.scope_claims.get(plan.deployment_id) != new_scope
            or self.issuance.reference_claims.get(plan.deployment_id) != credential_reference
            or old_scope != getattr(revoker, "scope", None)
            or old_scope.consumer_id != old_binding.consumer_id
            or old_scope.project_id != new_scope.project_id
            or old_scope.consumer_id == new_scope.consumer_id
            or registration.new.provisioner.target.instance_id != peer.ep_instance_id
        ):
            raise ManagedPairingRepairCredentialError("reviewed repair credential target changed")
        revoked = self.revocation.repair_revoke(
            operation_id, plan, reviewed_current=reviewed_current,
            revoker=revoker, detach_coordinator=detach_coordinator,
            forge_adapter=forge_adapter, old_binding=old_binding,
        )
        if (
            revoked.state != "COMPLETE" or not revoked.receipt_reference
            or revoked.operation_id != operation_id
            or revoked.deployment_id != plan.deployment_id
            or revoked.plan_fingerprint != "sha256:" + sha256(json.dumps(
                asdict(plan), sort_keys=True, separators=(",", ":"), allow_nan=False,
            ).encode()).hexdigest()
            or revoked.forge_instance_id != peer.forge_instance_id
            or revoked.ep_instance_id != peer.ep_instance_id
            or revoked.consumer_id != old_scope.consumer_id
            or revoked.project_id != old_scope.project_id
        ):
            raise ManagedPairingRepairCredentialError("old EP consumer revocation is not terminal")
        fingerprint = "sha256:" + sha256(json.dumps(
            asdict(reviewed_current), sort_keys=True, separators=(",", ":"),
            allow_nan=False,
        ).encode()).hexdigest()
        if revoked.reviewed_fingerprint != fingerprint:
            raise ManagedPairingRepairCredentialError("reviewed repair deployment changed")
        return self.issuance.issue(
            operation_id=operation_id, reviewed_current=reviewed_current,
            reviewed_fingerprint=fingerprint,
            credential_reference=credential_reference,
        )
