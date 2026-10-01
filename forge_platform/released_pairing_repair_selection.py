"""Derive a reviewed same-instance repair target from sealed released authority.

This is read-only. It selects a distinct new EP consumer and opaque Keychain
reference from the helper-owned route and durable operation ID. Callers cannot
provide a path, credential, endpoint, consumer or product command.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, replace
from hashlib import sha256
import json
import re

from .ep_consumer_revocation import EPConsumerScope
from .forge_ep_pairing_executor import ForgeEPProductPairingBinding
from .managed_deployments import (
    ManagedDeployment, ManagedDeploymentPlan, ManagedDeploymentPlanner,
    ManagedPeerBinding,
)
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .qualified_ep_lifecycle import qualified_ep_lifecycle_artifact
from .qualified_forge_lifecycle import qualified_forge_lifecycle_artifact
from .released_product_routes import ReleasedManagedProductRouteConfiguration


_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class ReleasedPairingRepairSelectionError(RuntimeError):
    """The sealed route cannot authorize the reviewed same-instance repair."""


@dataclass(frozen=True)
class ReleasedPairingRepairSelection:
    operation_id: str
    deployment_id: str
    reviewed_plan_fingerprint: str
    reviewed_current: ManagedDeployment
    plan: ManagedDeploymentPlan
    old_binding: ForgeEPProductPairingBinding
    new_binding: ForgeEPProductPairingBinding
    old_scope: EPConsumerScope
    new_scope: EPConsumerScope

    @classmethod
    def derive(
        cls, *, operation_id: str, reviewed_current: ManagedDeployment,
        route: ReleasedManagedProductRouteConfiguration,
    ) -> ReleasedPairingRepairSelection:
        peer = getattr(reviewed_current, "peer_binding", None)
        if (
            not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
            or not isinstance(reviewed_current, ManagedDeployment) or peer is None
            or not isinstance(route, ReleasedManagedProductRouteConfiguration)
            or reviewed_current.deployment_id != route.deployment_id
            or set(reviewed_current.by_component) != {FORGE_COMPONENT, EP_COMPONENT}
            or reviewed_current.by_component[FORGE_COMPONENT].instance_id
                != route.forge_target.instance_id
            or reviewed_current.by_component[EP_COMPONENT].instance_id
                != route.engineering_platform_target.instance_id
            or peer.forge_instance_id != route.forge_target.instance_id
            or peer.ep_instance_id != route.engineering_platform_target.instance_id
            or route.pairing_binding.expected_ep_instance_id != peer.ep_instance_id
            or not qualified_forge_lifecycle_artifact(route.forge_installed_artifact)
            or route.forge_installed_artifact.version != "2.7.39"
            or not qualified_ep_lifecycle_artifact(
                route.engineering_platform_installed_artifact
            )
        ):
            raise ReleasedPairingRepairSelectionError("released repair target changed")
        old = route.pairing_binding
        material = json.dumps({
            "contract": "forge-platform.repair-binding-selection/v1",
            "operation_id": operation_id,
            "deployment_id": reviewed_current.deployment_id,
            "reviewed_deployment": asdict(reviewed_current),
            "old_binding": asdict(old),
        }, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
        suffix = sha256(material).hexdigest()[:40]
        new_consumer = "repair-" + suffix
        new = replace(
            old, binding_id="repair-" + suffix,
            consumer_id=new_consumer,
            credential_reference="keychain://forge.ep/repair-" + suffix,
        )
        if (
            new.binding_id == old.binding_id
            or new.consumer_id == old.consumer_id
            or new.credential_reference == old.credential_reference
        ):
            raise ReleasedPairingRepairSelectionError("new repair identity is not distinct")
        desired = replace(
            reviewed_current, revision=reviewed_current.revision + 1,
            peer_binding=ManagedPeerBinding(
                peer.forge_instance_id, peer.ep_instance_id,
                "receipt:review-pair-" + suffix,
            ),
        )
        plan = ManagedDeploymentPlanner.plan(
            reviewed_current, desired,
            product_actions={FORGE_COMPONENT: "REPAIR", EP_COMPONENT: "NO_CHANGE"},
        )
        fingerprint = "sha256:" + sha256(json.dumps({
            "plan": asdict(plan),
            "old_binding": asdict(old),
            "new_binding": asdict(new),
        }, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()
        return cls(
            operation_id, reviewed_current.deployment_id, fingerprint,
            reviewed_current, plan, old, new,
            EPConsumerScope(old.consumer_id, old.project_id),
            EPConsumerScope(new.consumer_id, new.project_id),
        )
