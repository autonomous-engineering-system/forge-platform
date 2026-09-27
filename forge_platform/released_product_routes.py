"""Build concrete helper-owned product routes from released typed configuration.

The native request cannot select executable paths, service accounts, ports,
state roots, staged artifacts, credentials, supervisors, or pairing details.
This module freezes those values inside the privileged helper and constructs
the concrete Forge, Engineering Platform, and pairing adapters used by the
already admitted product-operation dispatcher.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import ipaddress
import re
from types import MappingProxyType
from typing import Iterable, Mapping
from urllib.parse import urlparse

from .component_operations import QualifiedArtifact
from .ep_consumer_revocation import EPConsumerRevocationAdapter, EPConsumerScope
from .engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    EngineeringPlatformSystemProvisionerAdapter,
)
from .forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding,
    ForgeEPProductPairingExecutor,
)
from .forge_server_adapter import (
    ForgeServerProductAdapter,
    ForgeServerTarget,
    ForgeUninstallBinding,
    ForgeUpdateBinding,
    MacOSForgeLaunchDaemonSupervisor,
)
from .managed_deployments import ManagedComponentBinding
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .managed_product_operation_dispatch import ResolvedManagedProductRoute
from .universal_installer import CompositionManifest, VerifiedCompositionSelection


_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


@dataclass(frozen=True)
class ReleasedManagedProductRouteConfiguration:
    """Immutable privileged configuration for one managed deployment route."""

    deployment_id: str
    forge_executable: Path
    forge_target: ForgeServerTarget
    forge_installed_artifact: QualifiedArtifact
    engineering_platform_installed_artifact: QualifiedArtifact
    engineering_platform_provisioner: Path
    engineering_platform_product_root: Path
    engineering_platform_target: EPSystemInstanceTarget
    staged_artifacts: Mapping[str, Path]
    pairing_binding: ForgeEPProductPairingBinding
    launch_daemons_directory: Path = Path("/Library/LaunchDaemons")
    forge_update_binding: ForgeUpdateBinding | None = None
    forge_lifecycle_executable: Path | None = None
    forge_uninstall_binding: ForgeUninstallBinding | None = None

    def __post_init__(self) -> None:
        ManagedComponentBinding(FORGE_COMPONENT, self.deployment_id, "receipt:route")
        if not isinstance(self.forge_target, ForgeServerTarget):
            raise TypeError("released route requires a Forge target")
        if not isinstance(self.forge_installed_artifact, QualifiedArtifact):
            raise TypeError("released route requires the exact installed Forge artifact")
        if not isinstance(self.engineering_platform_installed_artifact, QualifiedArtifact):
            raise TypeError("released route requires the exact installed EP artifact")
        if not isinstance(self.engineering_platform_target, EPSystemInstanceTarget):
            raise TypeError("released route requires an EP target")
        if not isinstance(self.pairing_binding, ForgeEPProductPairingBinding):
            raise TypeError("released route requires a Forge-to-EP pairing binding")
        if self.forge_update_binding is not None and not isinstance(
            self.forge_update_binding, ForgeUpdateBinding
        ):
            raise TypeError("released route Forge update binding is invalid")
        if self.forge_lifecycle_executable is not None and (
            not isinstance(self.forge_lifecycle_executable, Path)
            or not self.forge_lifecycle_executable.is_absolute()
        ):
            raise ValueError("released route Forge lifecycle executable must be absolute")
        if self.forge_uninstall_binding is not None and not isinstance(
            self.forge_uninstall_binding, ForgeUninstallBinding
        ):
            raise TypeError("released route Forge uninstall binding is invalid")
        if (
            self.forge_uninstall_binding is not None
            and self.forge_uninstall_binding.runtime_id != self.forge_target.instance_id
        ):
            raise ValueError("released route Forge uninstall targets a different instance")
        for label, path in (
            ("Forge executable", self.forge_executable),
            ("EP provisioner", self.engineering_platform_provisioner),
            ("EP product root", self.engineering_platform_product_root),
            ("LaunchDaemon directory", self.launch_daemons_directory),
        ):
            if not isinstance(path, Path) or not path.is_absolute():
                raise ValueError(f"released route {label} must be absolute")
        artifacts = dict(self.staged_artifacts)
        if not artifacts:
            raise ValueError("released route requires staged product artifacts")
        if any(
            _DIGEST.fullmatch(digest) is None
            or not isinstance(path, Path)
            or not path.is_absolute()
            for digest, path in artifacts.items()
        ):
            raise ValueError("released route staged artifact binding is invalid")
        if len(set(artifacts.values())) != len(artifacts):
            raise ValueError("released route staged artifact paths are ambiguous")
        if self.pairing_binding.expected_ep_instance_id != self.engineering_platform_target.instance_id:
            raise ValueError("released pairing does not target the configured EP instance")
        _require_local_ep_endpoint(
            self.pairing_binding.endpoint,
            self.engineering_platform_target.bind_port,
        )
        object.__setattr__(self, "staged_artifacts", MappingProxyType(artifacts))


class ReleasedManagedProductRouteBuilder:
    """Construct concrete routes only for exact catalog-authorized artifacts."""

    @staticmethod
    def build(
        *,
        configurations: Iterable[ReleasedManagedProductRouteConfiguration],
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
    ) -> Mapping[str, ResolvedManagedProductRoute]:
        configs = tuple(configurations)
        candidates = tuple(candidate_selections)
        installed = tuple(installed_selections)
        if not configs or any(
            not isinstance(value, ReleasedManagedProductRouteConfiguration)
            for value in configs
        ):
            raise TypeError("released product route configurations are required")
        if not candidates or any(
            not isinstance(value, VerifiedCompositionSelection) for value in candidates
        ):
            raise TypeError("verified candidate selections are required for product routes")
        if any(not isinstance(value, VerifiedCompositionSelection) for value in installed):
            raise TypeError("verified installed selections are invalid for product routes")
        deployment_ids = [value.deployment_id for value in configs]
        if len(deployment_ids) != len(set(deployment_ids)):
            raise ValueError("released product route deployment identities are ambiguous")

        return ReleasedManagedProductRouteBuilder.build_from_manifests(
            configurations=configs,
            candidate_manifests=tuple(value.manifest for value in candidates),
            installed_manifests=tuple(value.manifest for value in installed),
        )

    @staticmethod
    def build_from_manifests(
        *,
        configurations: Iterable[ReleasedManagedProductRouteConfiguration],
        candidate_manifests: Iterable[CompositionManifest],
        installed_manifests: Iterable[CompositionManifest] = (),
    ) -> Mapping[str, ResolvedManagedProductRoute]:
        """Build routes from an already pinned helper-owned manifest snapshot."""

        configs = tuple(configurations)
        candidates = tuple(candidate_manifests)
        installed = tuple(installed_manifests)
        if not configs or any(
            not isinstance(value, ReleasedManagedProductRouteConfiguration)
            for value in configs
        ):
            raise TypeError("released product route configurations are required")
        if not candidates or any(
            not isinstance(value, CompositionManifest) for value in candidates
        ):
            raise TypeError("pinned candidate composition manifests are required")
        if any(not isinstance(value, CompositionManifest) for value in installed):
            raise TypeError("pinned installed composition manifests are invalid")
        deployment_ids = [value.deployment_id for value in configs]
        if len(deployment_ids) != len(set(deployment_ids)):
            raise ValueError("released product route deployment identities are ambiguous")

        authorized = _authorized_artifacts(candidates + installed)
        required = {
            component.artifact.digest
            for manifest in candidates
            for component in manifest.components
            if component.identity in {FORGE_COMPONENT, EP_COMPONENT}
        }
        routes: dict[str, ResolvedManagedProductRoute] = {}
        claimed_scopes: set[EPConsumerScope] = set()
        for config in configs:
            scope = EPConsumerScope(
                config.pairing_binding.consumer_id, config.pairing_binding.project_id
            )
            if scope in claimed_scopes:
                raise ValueError("released EP consumer scope is shared across deployments")
            claimed_scopes.add(scope)
            staged = set(config.staged_artifacts)
            if not required.issubset(staged) or not staged.issubset(authorized):
                raise ValueError("released route staged artifacts do not match catalog authority")
            forge_authority = authorized.get(config.forge_installed_artifact.digest)
            if (
                forge_authority is None
                or forge_authority[0] != FORGE_COMPONENT
                or forge_authority[1] != config.forge_installed_artifact
            ):
                raise ValueError("released route installed Forge artifact lacks catalog authority")
            ep_authority = authorized.get(config.engineering_platform_installed_artifact.digest)
            if (
                ep_authority is None
                or ep_authority[0] != EP_COMPONENT
                or ep_authority[1] != config.engineering_platform_installed_artifact
            ):
                raise ValueError("released route installed EP artifact lacks catalog authority")
            forge = ForgeServerProductAdapter(
                forge_executable=config.forge_executable,
                target=config.forge_target,
                installed_artifact=config.forge_installed_artifact,
                staged_artifacts=config.staged_artifacts,
                supervisor=MacOSForgeLaunchDaemonSupervisor(
                    config.launch_daemons_directory
                ),
                update_binding=config.forge_update_binding,
                lifecycle_executable=config.forge_lifecycle_executable,
                uninstall_binding=config.forge_uninstall_binding,
            )
            ep = EngineeringPlatformSystemProvisionerAdapter(
                provisioner_executable=config.engineering_platform_provisioner,
                product_root=config.engineering_platform_product_root,
                target=config.engineering_platform_target,
                staged_artifacts=config.staged_artifacts,
            )
            routes[config.deployment_id] = ResolvedManagedProductRoute(
                config.forge_target.instance_id,
                config.engineering_platform_target.instance_id,
                {FORGE_COMPONENT: forge, EP_COMPONENT: ep},
                ForgeEPProductPairingExecutor(config.pairing_binding),
                EPConsumerRevocationAdapter(
                    provisioner=ep,
                    scope=scope,
                    expected_artifact=config.engineering_platform_installed_artifact,
                ),
            )
        return MappingProxyType(routes)


def _authorized_artifacts(
    manifests: tuple[CompositionManifest, ...],
) -> dict[str, tuple[str, QualifiedArtifact]]:
    authorized: dict[str, tuple[str, QualifiedArtifact]] = {}
    for manifest in manifests:
        for component in manifest.components:
            if component.identity not in {FORGE_COMPONENT, EP_COMPONENT}:
                continue
            existing = authorized.get(component.artifact.digest)
            candidate = (component.identity, component.artifact)
            if existing is not None and existing != candidate:
                raise ValueError("catalog artifact digest authority is ambiguous")
            authorized[component.artifact.digest] = candidate
    if {identity for identity, _artifact in authorized.values()} != {
        FORGE_COMPONENT,
        EP_COMPONENT,
    }:
        raise ValueError("catalog authority lacks exact Forge and EP artifacts")
    return authorized


def _require_local_ep_endpoint(endpoint: str, bind_port: int) -> None:
    parsed = urlparse(endpoint)
    hostname = parsed.hostname or ""
    loopback = hostname.casefold() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        pass
    default_port = 443 if parsed.scheme == "https" else 80
    if not loopback or (parsed.port or default_port) != bind_port:
        raise ValueError("released pairing endpoint does not match the local EP target")
