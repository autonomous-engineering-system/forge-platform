"""Select one sealed helper product route for reviewed preserved lifecycle work."""

from __future__ import annotations

from dataclasses import replace
import os
from pathlib import Path
import stat
from types import MappingProxyType
from typing import Iterable

from .forge_server_adapter import ForgeServerTarget, MacOSForgeLaunchDaemonSupervisor
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .ep_consumer_revocation import EPConsumerRevocationAdapter, EPConsumerScope
from .managed_deployments import ManagedDeploymentPlanner
from .managed_install_flow import ManagedForgeEPInstallationCoordinator
from .managed_pairing_revocation import ManagedPairingRevocationCoordinator
from .managed_preserve_execution import (
    ManagedPreserveExecutionCoordinator, ManagedPreserveExecutionRecord,
    ManagedPurgeExecutionCoordinator,
)
from .managed_preserved_lifecycle_request import NativePreservedLifecycleRequest
from .managed_preserved_lifecycle_plan import (
    ManagedPreservedLifecycleReview, require_current_preserved_lifecycle_review,
)
from .managed_preserved_product_adapters import (
    EPPreservedProductAdapter, ForgePreservedProductAdapter,
)
from .product_preserved_lifecycle import EP_COMPONENT, FORGE_COMPONENT, frozen_preserved_release
from .released_product_routes import (
    ReleasedManagedProductRouteConfiguration,
    ReleasedManagedSingleProductRouteConfiguration,
)
from .universal_installer import CompositionManifest


class ManagedPreservedLifecycleDispatchError(RuntimeError):
    """No exact helper-owned product route can execute this reviewed transition."""


class ManagedPreservedLifecycleDispatcher:
    """Keep all product command and filesystem authority in the worker."""

    def __init__(
        self, *, coordinator: ManagedForgeEPInstallationCoordinator,
        configurations: Iterable[
            ReleasedManagedProductRouteConfiguration
            | ReleasedManagedSingleProductRouteConfiguration
        ], expected_owner_uid: int = 0,
    ) -> None:
        configs = tuple(configurations)
        if (
            not isinstance(coordinator, ManagedForgeEPInstallationCoordinator)
            or not configs
            or any(not isinstance(item, (
                ReleasedManagedProductRouteConfiguration,
                ReleasedManagedSingleProductRouteConfiguration,
            )) for item in configs)
            or len({item.deployment_id for item in configs}) != len(configs)
        ):
            raise TypeError("sealed lifecycle product routes are required")
        claims = []
        for config in configs:
            if isinstance(config, ReleasedManagedSingleProductRouteConfiguration):
                claims.append((config.component_identity, config.target.instance_id))
            else:
                claims.extend((
                    (FORGE_COMPONENT, config.forge_target.instance_id),
                    (EP_COMPONENT, config.engineering_platform_target.instance_id),
                ))
        if len(claims) != len(set(claims)):
            raise ValueError("lifecycle product routes share an instance")
        scopes = {
            item.deployment_id: EPConsumerScope(
                item.pairing_binding.consumer_id, item.pairing_binding.project_id,
            )
            for item in configs
            if isinstance(item, ReleasedManagedProductRouteConfiguration)
        }
        if len(scopes) != len(set(scopes.values())):
            raise ValueError("lifecycle routes share an EP consumer scope")
        self.registry = coordinator.registry
        self.currency_guard = coordinator.currency_guard
        self.operations_root = coordinator.operations_root / "preserved-lifecycle"
        self.expected_owner_uid = expected_owner_uid
        self.configurations = MappingProxyType({item.deployment_id: item for item in configs})
        self.pairing_revocation = (
            ManagedPairingRevocationCoordinator(
                operations_root=self.operations_root / "ep-consumer-revocation",
                registry=self.registry, currency_guard=self.currency_guard,
                scope_claims=scopes, expected_owner_uid=expected_owner_uid,
            ) if scopes else None
        )

    def require_terminal_paired_purge(
        self, review: ManagedPreservedLifecycleReview, *,
        installed_manifest: CompositionManifest,
    ) -> None:
        """Recheck the exact EP-owned revocation for read-only PURGE recovery."""
        if (
            not isinstance(review, ManagedPreservedLifecycleReview)
            or review.operation != "PURGE"
            or review.component != FORGE_COMPONENT
            or review.historical_peer_reference is None
            or not isinstance(installed_manifest, CompositionManifest)
            or (review.composition_id, review.composition_digest) !=
                (installed_manifest.composition_id, installed_manifest.manifest_digest)
        ):
            raise ManagedPreservedLifecycleDispatchError("paired purge recovery selector changed")
        config = self.configurations.get(review.deployment_id)
        current = self.registry.load(review.deployment_id)
        if (
            not isinstance(config, ReleasedManagedProductRouteConfiguration)
            or self.pairing_revocation is None
            or current is None
            or current.revision != review.registry_revision + 1
            or current.peer_binding is not None
            or getattr(current, "historical_peer_binding", None) is not None
            or set(current.active_by_component) != {EP_COMPONENT}
            or current.preserved_by_component
            or current.active_by_component[EP_COMPONENT].instance_id
                != config.engineering_platform_target.instance_id
            or config.forge_target.instance_id != review.instance_id
            or current.composition_binding is None
            or (current.composition_binding.composition_id,
                current.composition_binding.manifest_digest) !=
                (review.composition_id, review.composition_digest)
            or self.pairing_revocation.scope_claims.get(review.deployment_id) !=
                EPConsumerScope(
                    config.pairing_binding.consumer_id,
                    config.pairing_binding.project_id,
                )
        ):
            raise ManagedPreservedLifecycleDispatchError("paired purge recovery inventory changed")
        ep_adapter = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=config.engineering_platform_provisioner,
            product_root=config.engineering_platform_product_root,
            target=config.engineering_platform_target,
            staged_artifacts=config.staged_artifacts,
        )
        revoker = EPConsumerRevocationAdapter(
            provisioner=ep_adapter,
            scope=self.pairing_revocation.scope_claims[review.deployment_id],
            expected_artifact=config.engineering_platform_installed_artifact,
            expected_owner_uid=self.expected_owner_uid,
        )
        self.pairing_revocation.read_terminal(
            operation_id=review.operation_id,
            deployment_id=review.deployment_id,
            reviewed_deployment_fingerprint=review.registry_fingerprint,
            forge_instance_id=review.instance_id,
            ep_instance_id=config.engineering_platform_target.instance_id,
            revoker=revoker,
        )

    def dispatch(
        self, request: NativePreservedLifecycleRequest, *,
        installed_manifest: CompositionManifest,
    ) -> ManagedPreserveExecutionRecord:
        if (
            not isinstance(request, NativePreservedLifecycleRequest)
            or request.review.operation not in {"PRESERVE", "PURGE"}
            or request.review.operation == "PURGE"
                and request.confirmed_instance_id != request.review.instance_id
            or not isinstance(installed_manifest, CompositionManifest)
            or (installed_manifest.composition_id, installed_manifest.manifest_digest)
                != (request.review.composition_id, request.review.composition_digest)
            or not frozen_preserved_release(request.review.component, request.review.artifact)
        ):
            raise ManagedPreservedLifecycleDispatchError("reviewed lifecycle release changed")
        config = self.configurations.get(request.review.deployment_id)
        if config is None:
            raise ManagedPreservedLifecycleDispatchError("reviewed deployment route is unavailable")
        current = self.registry.load(request.review.deployment_id)
        if current is None and request.review.operation != "PURGE":
            raise ManagedPreservedLifecycleDispatchError("reviewed deployment is unavailable")
        peer = (
            current.peer_binding or getattr(current, "historical_peer_binding", None)
            if current is not None else None
        )
        if peer is not None and (
            request.review.operation not in {"PRESERVE", "PURGE"}
            or request.review.component != FORGE_COMPONENT
            or request.review.operation == "PURGE" and current.peer_binding is None
        ):
            raise ManagedPreservedLifecycleDispatchError(
                "paired lifecycle requires product-owned consumer revocation"
            )
        claimed_components = (
            set(current.active_by_component) | set(current.preserved_by_component)
            if current is not None else set()
        )
        if isinstance(config, ReleasedManagedSingleProductRouteConfiguration) and (
            current is not None and claimed_components != {config.component_identity}
        ):
            raise ManagedPreservedLifecycleDispatchError("single route cannot own paired inventory")
        artifacts = {
            item.identity: item.artifact for item in installed_manifest.components
        }
        if artifacts.get(request.review.component) != request.review.artifact:
            raise ManagedPreservedLifecycleDispatchError("installed lifecycle artifact changed")
        if isinstance(config, ReleasedManagedSingleProductRouteConfiguration):
            if config.component_identity != request.review.component:
                raise ManagedPreservedLifecycleDispatchError("single-product route changed")
            if config.installed_artifact != request.review.artifact:
                raise ManagedPreservedLifecycleDispatchError("single-product release changed")
            target = config.target
            executable = config.executable
            product_root = config.engineering_platform_product_root
        else:
            target = (
                config.forge_target if request.review.component == FORGE_COMPONENT
                else config.engineering_platform_target
            )
            configured_artifact = (
                config.forge_installed_artifact if request.review.component == FORGE_COMPONENT
                else config.engineering_platform_installed_artifact
            )
            if configured_artifact != request.review.artifact:
                raise ManagedPreservedLifecycleDispatchError("paired-product release changed")
            executable = (
                config.forge_executable if request.review.component == FORGE_COMPONENT
                else config.engineering_platform_provisioner
            )
            product_root = config.engineering_platform_product_root
        if target.instance_id != request.review.instance_id:
            raise ManagedPreservedLifecycleDispatchError("product route targets another instance")
        supervisor = None
        if request.review.component == FORGE_COMPONENT:
            preserved_forge = (
                current.preserved_by_component.get(FORGE_COMPONENT)
                if current is not None else None
            )
            if (
                not isinstance(target, ForgeServerTarget)
                or config.forge_lifecycle_executable is None
                or config.forge_uninstall_binding is None
                or config.forge_uninstall_binding.runtime_id != target.instance_id
                or preserved_forge is not None and
                    preserved_forge.forge_installation_id
                        != config.forge_uninstall_binding.installation_id
            ):
                raise ManagedPreservedLifecycleDispatchError("Forge lifecycle route is unavailable")
            adapter = ForgePreservedProductAdapter(
                lifecycle_executable=config.forge_lifecycle_executable,
                target=target,
                installation_id=config.forge_uninstall_binding.installation_id,
                artifact=request.review.artifact,
            )
            supervisor = MacOSForgeLaunchDaemonSupervisor(config.launch_daemons_directory)
        else:
            wheel: Path | None = config.staged_artifacts.get(request.review.artifact.digest)
            if wheel is None or product_root is None:
                raise ManagedPreservedLifecycleDispatchError("EP lifecycle route is unavailable")
            adapter = EPPreservedProductAdapter(
                provisioner_executable=executable, product_root=product_root,
                target=target, artifact=request.review.artifact,
                staged_wheel=wheel,
                launch_daemons_directory=config.launch_daemons_directory,
            )
        coordinator_type = (
            ManagedPurgeExecutionCoordinator if request.review.operation == "PURGE"
            else ManagedPreserveExecutionCoordinator
        )
        coordinator = coordinator_type(
            operations_root=self.operations_root, registry=self.registry,
            currency_guard=self.currency_guard, forge_supervisor=supervisor,
            expected_owner_uid=self.expected_owner_uid,
        )
        execute = coordinator.purge if request.review.operation == "PURGE" else coordinator.preserve
        pairing_proof = None
        if peer is not None or request.review.historical_peer_reference is not None:
            if (
                not isinstance(config, ReleasedManagedProductRouteConfiguration)
                or self.pairing_revocation is None
                or self.pairing_revocation.scope_claims.get(request.review.deployment_id)
                    != EPConsumerScope(
                        config.pairing_binding.consumer_id,
                        config.pairing_binding.project_id,
                    )
                or peer is not None and (
                    config.engineering_platform_target.instance_id != peer.ep_instance_id
                    or config.forge_target.instance_id != peer.forge_instance_id
                )
                or artifacts.get(EP_COMPONENT) != config.engineering_platform_installed_artifact
            ):
                raise ManagedPreservedLifecycleDispatchError("paired preserve scope changed")
            ep_adapter = EngineeringPlatformSystemProvisionerAdapter(
                provisioner_executable=config.engineering_platform_provisioner,
                product_root=config.engineering_platform_product_root,
                target=config.engineering_platform_target,
                staged_artifacts=config.staged_artifacts,
            )
            revoker = EPConsumerRevocationAdapter(
                provisioner=ep_adapter,
                scope=self.pairing_revocation.scope_claims[request.review.deployment_id],
                expected_artifact=config.engineering_platform_installed_artifact,
                expected_owner_uid=self.expected_owner_uid,
            )
            self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
            root_info = os.lstat(self.operations_root)
            if (
                not stat.S_ISDIR(root_info.st_mode)
                or root_info.st_uid != self.expected_owner_uid
                or stat.S_IMODE(root_info.st_mode) != 0o700
            ):
                raise ManagedPreservedLifecycleDispatchError(
                    "paired preserve journal root is unsafe"
                )
            if current.peer_binding is not None:
                require_current_preserved_lifecycle_review(
                    request.review, current=current, installed_manifest=installed_manifest,
                )
                desired = replace(
                    current,
                    components=(current.active_by_component[EP_COMPONENT],),
                    peer_binding=None,
                )
                plan = ManagedDeploymentPlanner.plan(current, desired)
                pairing_proof = self.pairing_revocation.revoke(
                    request.review.operation_id, plan,
                    reviewed_current=current, revoker=revoker,
                )
            else:
                if request.review.operation == "PRESERVE":
                    preserved = current.preserved_by_component.get(FORGE_COMPONENT)
                    if (
                        preserved is None
                        or preserved.instance_id != request.review.instance_id
                        or preserved.preserve_operation_id != request.review.operation_id
                    ):
                        raise ManagedPreservedLifecycleDispatchError(
                            "paired preserve replay lost its exact inventory"
                        )
                elif (
                    current.active_by_component.get(EP_COMPONENT) is None
                    or current.active_by_component[EP_COMPONENT].instance_id
                        != config.engineering_platform_target.instance_id
                ):
                    raise ManagedPreservedLifecycleDispatchError(
                        "paired purge replay lost its exact EP instance"
                    )
                pairing_proof = self.pairing_revocation.read_terminal(
                    operation_id=request.review.operation_id,
                    deployment_id=request.review.deployment_id,
                    reviewed_deployment_fingerprint=request.review.registry_fingerprint,
                    forge_instance_id=config.forge_target.instance_id,
                    ep_instance_id=config.engineering_platform_target.instance_id,
                    revoker=revoker,
                )
        return execute(
            request.review, installed_manifest=installed_manifest,
            adapter=adapter,
            pairing_revocation=pairing_proof,
        )
