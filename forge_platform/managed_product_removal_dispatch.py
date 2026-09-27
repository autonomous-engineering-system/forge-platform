"""Helper-only dispatch of admitted exact Forge product removals.

No native request field becomes a product path, command or credential. Fresh
admission and route checks precede the existing durable product-owned removal
coordinators; those coordinators own the final currency and terminal readback.
"""

from __future__ import annotations

from hashlib import sha256
from types import MappingProxyType
from typing import Mapping

from .component_operations import ComponentOperationRequest
from .managed_forge_removal import ManagedForgeOnlyRemovalCoordinator
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, ManagedForgeEPInstallationCoordinator
from .managed_pairing_revocation import ManagedPairingRevocationCoordinator
from .managed_paired_deployment_removal import ManagedPairedDeploymentRemovalCoordinator
from .managed_paired_forge_removal import ManagedPairedForgeComponentRemovalCoordinator
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .managed_product_operation_dispatch import ResolvedManagedProductRoute
from .managed_product_removal_admission import (
    AdmittedNativeProductRemoval, admit_native_product_removal,
)


class ManagedProductRemovalDispatchError(RuntimeError):
    """Admitted removal no longer has exact helper-owned product authority."""


def _child_id(operation_id: str, component: str, kind: str) -> str:
    material = f"{operation_id}\x1f{component}\x1f{kind}".encode("utf-8")
    return "remove-" + sha256(material).hexdigest()[:40]


class ManagedProductRemovalDispatcher:
    """Bind one admitted removal to sealed routes and the durable product saga."""

    def __init__(
        self, *, coordinator: ManagedForgeEPInstallationCoordinator,
        routes: Mapping[str, ResolvedManagedProductRoute],
        current_installer_release: NativeInstallerReleaseBinding,
        expected_owner_uid: int = 0,
    ) -> None:
        if not isinstance(coordinator, ManagedForgeEPInstallationCoordinator):
            raise TypeError("managed product coordinator is required")
        if not isinstance(current_installer_release, NativeInstallerReleaseBinding):
            raise TypeError("current installer release authority is required")
        if isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0:
            raise ValueError("removal journal owner is invalid")
        snapshot = dict(routes)
        if not snapshot or any(
            not isinstance(key, str) or not isinstance(value, ResolvedManagedProductRoute)
            for key, value in snapshot.items()
        ):
            raise TypeError("sealed product removal routes are required")
        claims: set[tuple[str, str]] = set()
        scopes = {}
        for deployment_id, route in snapshot.items():
            route_claims = {
                (FORGE_COMPONENT, route.forge_instance_id),
                (EP_COMPONENT, route.engineering_platform_instance_id),
            }
            if claims.intersection(route_claims):
                raise ValueError("product removal routes share an instance")
            claims.update(route_claims)
            if route.ep_consumer_revoker is not None:
                scopes[deployment_id] = route.ep_consumer_revoker.scope
        if len(set(scopes.values())) != len(scopes):
            raise ValueError("product removal routes share an EP consumer scope")
        self.coordinator = coordinator
        self.routes = MappingProxyType(snapshot)
        self.current_installer_release = current_installer_release
        self.expected_owner_uid = expected_owner_uid
        self.revocation = ManagedPairingRevocationCoordinator(
            operations_root=coordinator.operations_root / "removal" / "ep-consumer-revocation",
            registry=coordinator.registry,
            currency_guard=coordinator.currency_guard,
            scope_claims=scopes,
            expected_owner_uid=expected_owner_uid,
        ) if scopes else None

    def dispatch(self, admitted: AdmittedNativeProductRemoval):
        if not isinstance(admitted, AdmittedNativeProductRemoval):
            raise TypeError("admitted native product removal is required")
        fresh = admit_native_product_removal(
            admitted.request,
            installed_manifest=admitted.installed_manifest,
            registry=self.coordinator.registry,
            current_installer_release=self.current_installer_release,
        )
        if fresh != admitted:
            raise ManagedProductRemovalDispatchError("reviewed removal changed before dispatch")
        request = fresh.request
        current = fresh.reviewed_current
        route = self.routes.get(request.deployment_id)
        if route is None:
            raise ManagedProductRemovalDispatchError("selected product route is unavailable")
        forge = route.adapters[FORGE_COMPONENT]
        ep = route.adapters[EP_COMPONENT]
        artifacts = {
            component.identity: component.artifact
            for component in fresh.installed_manifest.components
        }
        if (
            route.forge_instance_id != request.forge_instance_id
            or getattr(getattr(forge, "target", None), "instance_id", None) != request.forge_instance_id
            or getattr(forge, "installed_artifact", None) != artifacts[FORGE_COMPONENT]
            or not callable(getattr(forge, "removal_support", None))
            or forge.removal_support() != "SUPPORTED"
        ):
            raise ManagedProductRemovalDispatchError("Forge uninstall route changed")
        if request.engineering_platform_instance_id is not None:
            revoker = route.ep_consumer_revoker
            peer = current.peer_binding
            if (
                route.engineering_platform_instance_id != request.engineering_platform_instance_id
                or getattr(getattr(ep, "target", None), "instance_id", None)
                != request.engineering_platform_instance_id
                or revoker is None or self.revocation is None or peer is None
                or revoker.provisioner is not ep
                or revoker.expected_artifact != artifacts[EP_COMPONENT]
                or self.revocation.scope_claims.get(request.deployment_id) != revoker.scope
                or peer.forge_instance_id != request.forge_instance_id
                or peer.ep_instance_id != request.engineering_platform_instance_id
            ):
                raise ManagedProductRemovalDispatchError("paired EP removal route changed")
        else:
            revoker = None
        forge_request = ComponentOperationRequest(
            _child_id(request.operation_id, FORGE_COMPONENT, "remove"),
            FORGE_COMPONENT, "remove", artifacts[FORGE_COMPONENT],
            request.forge_instance_id, "server", {},
        )
        removal_root = self.coordinator.operations_root / "removal"
        common = {
            "operations_root": removal_root,
            "component_operations_root": self.coordinator.component_operations_root,
            "registry": self.coordinator.registry,
            "currency_guard": self.coordinator.currency_guard,
        }
        if revoker is None:
            return ManagedForgeOnlyRemovalCoordinator(**common).remove(
                request.operation_id, fresh.plan, request=forge_request, adapter=forge,
            )
        ep_kind = "repair" if request.action == "REMOVE_COMPONENT" else "remove"
        ep_request = ComponentOperationRequest(
            _child_id(request.operation_id, EP_COMPONENT, ep_kind),
            EP_COMPONENT, ep_kind, artifacts[EP_COMPONENT],
            request.engineering_platform_instance_id, "server", {},
        )
        if request.action == "REMOVE_COMPONENT":
            return ManagedPairedForgeComponentRemovalCoordinator(
                **common, revocation=self.revocation,
            ).remove(
                request.operation_id, fresh.plan, reviewed_current=current,
                forge_request=forge_request, forge_adapter=forge,
                ep_readback_request=ep_request, ep_adapter=ep,
                revoker=revoker,
            )
        return ManagedPairedDeploymentRemovalCoordinator(
            **common, revocation=self.revocation,
        ).remove(
            request.operation_id, fresh.plan, reviewed_current=current,
            forge_request=forge_request, forge_adapter=forge,
            ep_request=ep_request, ep_adapter=ep, revoker=revoker,
        )
