"""Select one sealed helper product route for a reviewed PRESERVE operation."""

from __future__ import annotations

from pathlib import Path
from types import MappingProxyType
from typing import Iterable

from .forge_server_adapter import ForgeServerTarget, MacOSForgeLaunchDaemonSupervisor
from .managed_install_flow import ManagedForgeEPInstallationCoordinator
from .managed_preserve_execution import (
    ManagedPreserveExecutionCoordinator, ManagedPreserveExecutionRecord,
)
from .managed_preserved_lifecycle_request import NativePreservedLifecycleRequest
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
        self.registry = coordinator.registry
        self.currency_guard = coordinator.currency_guard
        self.operations_root = coordinator.operations_root / "preserved-lifecycle"
        self.expected_owner_uid = expected_owner_uid
        self.configurations = MappingProxyType({item.deployment_id: item for item in configs})

    def dispatch(
        self, request: NativePreservedLifecycleRequest, *,
        installed_manifest: CompositionManifest,
    ) -> ManagedPreserveExecutionRecord:
        if (
            not isinstance(request, NativePreservedLifecycleRequest)
            or request.review.operation != "PRESERVE"
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
        if current is None:
            raise ManagedPreservedLifecycleDispatchError("reviewed deployment is unavailable")
        claimed_components = set(current.active_by_component) | set(current.preserved_by_component)
        if isinstance(config, ReleasedManagedSingleProductRouteConfiguration) and (
            claimed_components != {config.component_identity}
            or current.peer_binding is not None
            or getattr(current, "historical_peer_binding", None) is not None
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
            if (
                not isinstance(target, ForgeServerTarget)
                or config.forge_lifecycle_executable is None
                or config.forge_uninstall_binding is None
                or config.forge_uninstall_binding.runtime_id != target.instance_id
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
        coordinator = ManagedPreserveExecutionCoordinator(
            operations_root=self.operations_root, registry=self.registry,
            currency_guard=self.currency_guard, forge_supervisor=supervisor,
            expected_owner_uid=self.expected_owner_uid,
        )
        return coordinator.preserve(
            request.review, installed_manifest=installed_manifest,
            adapter=adapter,
        )
