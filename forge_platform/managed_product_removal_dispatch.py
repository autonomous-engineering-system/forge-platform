"""Helper-only dispatch of admitted exact Forge product removals.

No native request field becomes a product path, command or credential. Fresh
admission and route checks precede the existing durable product-owned removal
coordinators; those coordinators own the final currency and terminal readback.
"""

from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
from types import MappingProxyType
from typing import Mapping

from .component_operations import ComponentOperationRequest
from .managed_deployments import ManagedDeploymentPlanner
from .managed_forge_removal import ManagedForgeOnlyRemovalCoordinator
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT, ManagedForgeEPInstallationCoordinator
from .managed_pairing_revocation import ManagedPairingRevocationCoordinator
from .managed_installer import ManagedDeploymentOperationCoordinator
from .managed_paired_deployment_removal import ManagedPairedDeploymentRemovalCoordinator
from .managed_paired_forge_removal import ManagedPairedForgeComponentRemovalCoordinator
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .managed_product_operation_dispatch import ResolvedManagedProductRoute
from .managed_product_removal_admission import (
    AdmittedNativeProductRemoval, ManagedProductRemovalAdmissionError,
    NativeProductRemovalRequest, admit_native_product_removal,
)
from .managed_product_removal_review import ManagedProductRemovalReviewJournal
from .qualified_forge_lifecycle import qualified_forge_lifecycle_artifact
from .universal_installer import CompositionManifest


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
        self.review_journal = ManagedProductRemovalReviewJournal(
            root=coordinator.operations_root / "removal" / "reviews",
            registry=coordinator.registry,
            expected_owner_uid=expected_owner_uid,
        )

    def admit_or_restore(
        self, request: NativeProductRemovalRequest,
        *, installed_manifest: CompositionManifest,
    ) -> AdmittedNativeProductRemoval:
        """Admit fresh state or recover only the exact terminal reviewed state."""

        try:
            return admit_native_product_removal(
                request, installed_manifest=installed_manifest,
                registry=self.coordinator.registry,
                current_installer_release=self.current_installer_release,
            )
        except ManagedProductRemovalAdmissionError as error:
            snapshot = self.review_journal.load(
                request, installed_manifest=installed_manifest,
                current_installer_release=self.current_installer_release,
            )
            if snapshot is None:
                raise ManagedProductRemovalDispatchError(
                    "terminal removal has no durable reviewed snapshot"
                ) from error
        reviewed = snapshot.reviewed_current
        by_component = reviewed.by_component
        artifacts = {component.identity: component.artifact for component in installed_manifest.components}
        forge = artifacts.get(FORGE_COMPONENT)
        ep = artifacts.get(EP_COMPONENT)
        if (
            reviewed.revision != request.reviewed_revision
            or by_component.get(FORGE_COMPONENT) is None
            or by_component[FORGE_COMPONENT].instance_id != request.forge_instance_id
            or (by_component.get(EP_COMPONENT).instance_id if EP_COMPONENT in by_component else None)
            != request.engineering_platform_instance_id
            or not qualified_forge_lifecycle_artifact(forge)
            or EP_COMPONENT in by_component and (
                ep is None or ep.version != "2.3.104"
                or ep.source_revision != "cfce69892278ee2b6c14412c171f5f33596acb0e"
                or ep.digest != "sha256:3f7822fd081598f81d5c666200787a3b2182d7004c078cc36ec20455269909cb"
            )
        ):
            raise ManagedProductRemovalDispatchError("reviewed product authority changed")
        desired = None
        if request.action == "REMOVE_COMPONENT":
            if EP_COMPONENT not in by_component or reviewed.peer_binding is None:
                raise ManagedProductRemovalDispatchError("reviewed paired topology is unavailable")
            desired = replace(
                reviewed, components=(by_component[EP_COMPONENT],), peer_binding=None,
            )
        plan = ManagedDeploymentPlanner.plan(reviewed, desired)
        if (
            ManagedDeploymentOperationCoordinator._plan_fingerprint(plan)
            != "sha256:" + request.reviewed_plan_sha256
        ):
            raise ManagedProductRemovalDispatchError("reviewed removal plan changed")
        current = self.coordinator.registry.load(request.deployment_id)
        if request.action == "REMOVE_DEPLOYMENT":
            if current is not None:
                raise ManagedProductRemovalDispatchError("removed deployment changed after review")
        elif (
            current is None or desired is None
            or current != replace(desired, revision=reviewed.revision + 1)
        ):
            raise ManagedProductRemovalDispatchError("retained EP deployment changed after review")
        removed_claims = {
            (diff.component, diff.instance_id)
            for diff in plan.component_diffs if diff.action == "REMOVE_COMPONENT"
        }
        if any(
            removed_claims.intersection(
                (component, item.instance_id)
                for component, item in deployment.by_component.items()
            )
            for deployment in self.coordinator.registry.inventory()
        ):
            raise ManagedProductRemovalDispatchError("removed instance was reassigned")
        return AdmittedNativeProductRemoval(request, reviewed, plan, installed_manifest)

    def dispatch(self, admitted: AdmittedNativeProductRemoval):
        if not isinstance(admitted, AdmittedNativeProductRemoval):
            raise TypeError("admitted native product removal is required")
        fresh = self.admit_or_restore(
            admitted.request, installed_manifest=admitted.installed_manifest,
        )
        if fresh != admitted:
            raise ManagedProductRemovalDispatchError("reviewed removal changed before dispatch")
        if self.coordinator.registry.load(admitted.request.deployment_id) == admitted.reviewed_current:
            self.review_journal.prepare(
                admitted, current_installer_release=self.current_installer_release,
            )
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
