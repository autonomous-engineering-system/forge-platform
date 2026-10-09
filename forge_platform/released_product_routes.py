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
    ForgeEPProductPairingExecutor, ForgeEPInstallationPairingBinding, ForgeEPInstallationPairingExecutor,
)
from .forge_server_adapter import (
    ForgeServerProductAdapter,
    ForgeServerTarget,
    ForgeUninstallBinding,
    ForgeUpdateBinding,
    ForgeUpdateBindingProvider,
    MacOSForgeLaunchDaemonSupervisor,
)
from .managed_forge_instance_bootstrap import ManagedForgeInstanceBootstrap
from .installation_credential_issuer import ManagedEPInstallationCredentialIssuer
from .qualified_ep_lifecycle import qualified_ep_installation_pairing_artifact
from .qualified_forge_lifecycle import qualified_forge_installation_pairing_artifact
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
    forge_update_binding_provider: ForgeUpdateBindingProvider | None = None
    forge_lifecycle_executable: Path | None = None
    forge_uninstall_binding: ForgeUninstallBinding | None = None
    forge_instance_bootstrap: ManagedForgeInstanceBootstrap | None = None

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
        if self.forge_update_binding_provider is not None and (
            self.forge_update_binding is not None
            or not callable(getattr(self.forge_update_binding_provider, "resolve", None))
        ):
            raise TypeError("released route Forge update provider is invalid or ambiguous")
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


@dataclass(frozen=True)
class ReleasedManagedInstallationRouteConfiguration:
    """Sealed concrete installation route, without historical project authority."""
    deployment_id: str
    forge: ForgeServerProductAdapter
    ep: EngineeringPlatformSystemProvisionerAdapter
    pairing_binding: ForgeEPInstallationPairingBinding
    credential_issuer: ManagedEPInstallationCredentialIssuer

    def __post_init__(self):
        ManagedComponentBinding(FORGE_COMPONENT,self.deployment_id,"receipt:route")
        if (not isinstance(self.forge,ForgeServerProductAdapter)
                or not isinstance(self.ep,EngineeringPlatformSystemProvisionerAdapter)
                or not isinstance(self.pairing_binding,ForgeEPInstallationPairingBinding)
                or not isinstance(self.credential_issuer,ManagedEPInstallationCredentialIssuer)
                or self.credential_issuer.forge is not self.forge
                or self.credential_issuer.ep is not self.ep
                or self.credential_issuer.binding != self.pairing_binding
                or self.credential_issuer.deployment_id != self.deployment_id
                or not qualified_forge_installation_pairing_artifact(self.forge.installed_artifact)
                or not qualified_ep_installation_pairing_artifact(self.credential_issuer.ep_artifact)
                or self.pairing_binding.expected_ep_instance_id != self.ep.target.instance_id):
            raise ValueError("exact installation route authority required")
        _require_local_ep_endpoint(self.pairing_binding.endpoint,self.ep.target.bind_port)

    @property
    def forge_target(self): return self.forge.target
    @property
    def engineering_platform_target(self): return self.ep.target
    @property
    def forge_uninstall_binding(self): return None


@dataclass(frozen=True)
class ReleasedManagedSingleProductRouteConfiguration:
    """Sealed route for exactly one product, with no pairing authority."""

    deployment_id: str
    component_identity: str
    executable: Path
    target: ForgeServerTarget | EPSystemInstanceTarget
    installed_artifact: QualifiedArtifact
    staged_artifacts: Mapping[str, Path]
    engineering_platform_product_root: Path | None = None
    launch_daemons_directory: Path = Path("/Library/LaunchDaemons")
    forge_update_binding: ForgeUpdateBinding | None = None
    forge_update_binding_provider: ForgeUpdateBindingProvider | None = None
    forge_lifecycle_executable: Path | None = None
    forge_uninstall_binding: ForgeUninstallBinding | None = None
    forge_instance_bootstrap: ManagedForgeInstanceBootstrap | None = None

    def __post_init__(self) -> None:
        ManagedComponentBinding(FORGE_COMPONENT, self.deployment_id, "receipt:route")
        if self.component_identity == FORGE_COMPONENT:
            if not isinstance(self.target, ForgeServerTarget):
                raise TypeError("single Forge route requires an exact Forge target")
            if self.engineering_platform_product_root is not None:
                raise ValueError("single Forge route cannot carry an EP product root")
            if self.forge_uninstall_binding is not None and (
                not isinstance(self.forge_uninstall_binding, ForgeUninstallBinding)
                or self.forge_uninstall_binding.runtime_id != self.target.instance_id
            ):
                raise ValueError("single Forge uninstall targets a different instance")
            if self.forge_update_binding is not None and not isinstance(
                self.forge_update_binding, ForgeUpdateBinding
            ):
                raise TypeError("single Forge update binding is invalid")
            if self.forge_update_binding_provider is not None and (
                self.forge_update_binding is not None
                or not callable(getattr(self.forge_update_binding_provider, "resolve", None))
            ):
                raise TypeError("single Forge update provider is invalid or ambiguous")
        elif self.component_identity == EP_COMPONENT:
            if not isinstance(self.target, EPSystemInstanceTarget):
                raise TypeError("single EP route requires an exact EP target")
            if (
                not isinstance(self.engineering_platform_product_root, Path)
                or not self.engineering_platform_product_root.is_absolute()
            ):
                raise ValueError("single EP route requires an absolute product root")
            if any((
                self.forge_update_binding,
                self.forge_update_binding_provider,
                self.forge_lifecycle_executable,
                self.forge_uninstall_binding,
            )):
                raise ValueError("single EP route cannot carry Forge lifecycle authority")
        else:
            raise ValueError("single product route component is unsupported")
        if not isinstance(self.installed_artifact, QualifiedArtifact):
            raise TypeError("single product route requires an exact installed artifact")
        for path in (
            self.executable, self.launch_daemons_directory,
            self.forge_lifecycle_executable,
        ):
            if path is not None and (not isinstance(path, Path) or not path.is_absolute()):
                raise ValueError("single product route executable and service paths must be absolute")
        staged = dict(self.staged_artifacts)
        if not staged or any(
            _DIGEST.fullmatch(digest) is None
            or not isinstance(path, Path) or not path.is_absolute()
            for digest, path in staged.items()
        ) or len(set(staged.values())) != len(staged):
            raise ValueError("single product route staged artifacts are invalid or ambiguous")
        object.__setattr__(self, "staged_artifacts", MappingProxyType(staged))


class ReleasedManagedProductRouteBuilder:
    """Construct concrete routes only for exact catalog-authorized artifacts."""

    @staticmethod
    def build(
        *,
        configurations: Iterable[ReleasedManagedProductRouteConfiguration | ReleasedManagedSingleProductRouteConfiguration],
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
    ) -> Mapping[str, ResolvedManagedProductRoute]:
        configs = tuple(configurations)
        candidates = tuple(candidate_selections)
        installed = tuple(installed_selections)
        if not configs or any(
            not isinstance(value, (ReleasedManagedProductRouteConfiguration, ReleasedManagedSingleProductRouteConfiguration, ReleasedManagedInstallationRouteConfiguration))
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
        configurations: Iterable[ReleasedManagedProductRouteConfiguration | ReleasedManagedSingleProductRouteConfiguration],
        candidate_manifests: Iterable[CompositionManifest],
        installed_manifests: Iterable[CompositionManifest] = (),
    ) -> Mapping[str, ResolvedManagedProductRoute]:
        """Build routes from an already pinned helper-owned manifest snapshot."""

        configs = tuple(configurations)
        candidates = tuple(candidate_manifests)
        installed = tuple(installed_manifests)
        if not configs or any(
            not isinstance(value, (ReleasedManagedProductRouteConfiguration, ReleasedManagedSingleProductRouteConfiguration, ReleasedManagedInstallationRouteConfiguration))
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
        _require_isolated_targets(configs)

        authorized = _authorized_artifacts(candidates + installed)
        required = {
            component.artifact.digest
            for manifest in candidates
            for component in manifest.components
            if component.identity in {FORGE_COMPONENT, EP_COMPONENT}
        }
        routes: dict[str, ResolvedManagedProductRoute] = {}
        claimed_scopes: set[EPConsumerScope] = set()
        installation_claims = [set() for _ in range(4)]
        for config in configs:
            if isinstance(config,ReleasedManagedInstallationRouteConfiguration):
                binding=config.pairing_binding
                claims=(binding.operation_id,binding.binding_id,binding.consumer_id,binding.credential_reference)
                if any(value in installation_claims[i] for i,value in enumerate(claims)):
                    raise ValueError("installation authority shared across deployments")
                for i,value in enumerate(claims): installation_claims[i].add(value)
                for component,artifact in ((FORGE_COMPONENT,config.forge.installed_artifact),
                                           (EP_COMPONENT,config.credential_issuer.ep_artifact)):
                    if authorized.get(artifact.digest)!=(component,artifact):
                        raise ValueError("installation artifact lacks exact manifest authority")
                for adapter in (config.forge,config.ep):
                    if (not required.issubset(adapter.staged_artifacts)
                            or not set(adapter.staged_artifacts).issubset(authorized)):
                        raise ValueError("installation staging lacks exact catalog authority")
                routes[config.deployment_id]=ResolvedManagedProductRoute(
                    config.forge.target.instance_id,config.ep.target.instance_id,
                    {FORGE_COMPONENT:config.forge,EP_COMPONENT:config.ep},
                    ForgeEPInstallationPairingExecutor(binding),
                    installation_credential_issuer=config.credential_issuer)
                continue
            if isinstance(config, ReleasedManagedSingleProductRouteConfiguration):
                routes[config.deployment_id] = _build_single_route(
                    config, candidates, authorized
                )
                continue
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
                update_binding_provider=config.forge_update_binding_provider,
                lifecycle_executable=config.forge_lifecycle_executable,
                uninstall_binding=config.forge_uninstall_binding,
                instance_bootstrap=config.forge_instance_bootstrap,
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


def _require_isolated_targets(
    configurations: tuple[
        ReleasedManagedProductRouteConfiguration | ReleasedManagedSingleProductRouteConfiguration,
        ...,
    ],
) -> None:
    """Reject cross-deployment product identity and OS-state aliases before route construction."""

    forge_ids: set[str] = set()
    ep_ids: set[str] = set()
    forge_data_roots: list[Path] = []
    forge_credential_files: set[Path] = set()
    service_accounts: set[str] = set()
    bind_ports: set[int] = set()
    for configuration in configurations:
        if isinstance(configuration, (ReleasedManagedProductRouteConfiguration, ReleasedManagedInstallationRouteConfiguration)):
            targets = (configuration.forge_target, configuration.engineering_platform_target)
        else:
            targets = (configuration.target,)
        for target in targets:
            ids = forge_ids if isinstance(target, ForgeServerTarget) else ep_ids
            if target.instance_id in ids:
                raise ValueError("released product instance is claimed by multiple deployments")
            ids.add(target.instance_id)
            if target.service_account in service_accounts or target.bind_port in bind_ports:
                raise ValueError("released product OS authority is shared across instances")
            service_accounts.add(target.service_account)
            bind_ports.add(target.bind_port)
            if isinstance(target, ForgeServerTarget):
                try:
                    data_root = target.data_root.resolve(strict=False)
                    credential_file = target.api_credential_file.resolve(strict=False)
                except (OSError, RuntimeError) as error:
                    raise ValueError("released Forge target paths cannot be resolved") from error
                if any(
                    data_root == existing
                    or data_root.is_relative_to(existing)
                    or existing.is_relative_to(data_root)
                    for existing in forge_data_roots
                ):
                    raise ValueError("released Forge data roots overlap across deployments")
                if credential_file in forge_credential_files:
                    raise ValueError("released Forge API credential path is shared")
                forge_data_roots.append(data_root)
                forge_credential_files.add(credential_file)


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
    if not authorized:
        raise ValueError("catalog authority lacks supported product artifacts")
    return authorized


def _build_single_route(
    config: ReleasedManagedSingleProductRouteConfiguration,
    candidates: tuple[CompositionManifest, ...],
    authorized: Mapping[str, tuple[str, QualifiedArtifact]],
) -> ResolvedManagedProductRoute:
    component = config.component_identity
    required = {
        item.artifact.digest
        for manifest in candidates for item in manifest.components
        if item.identity == component
    }
    staged = set(config.staged_artifacts)
    if (
        not required or not required.issubset(staged)
        or any(authorized.get(digest, (None,))[0] != component for digest in staged)
        or authorized.get(config.installed_artifact.digest)
            != (component, config.installed_artifact)
    ):
        raise ValueError("single product route artifact lacks exact catalog authority")
    if component == FORGE_COMPONENT:
        assert isinstance(config.target, ForgeServerTarget)
        adapter = ForgeServerProductAdapter(
            forge_executable=config.executable,
            target=config.target,
            installed_artifact=config.installed_artifact,
            staged_artifacts=config.staged_artifacts,
            supervisor=MacOSForgeLaunchDaemonSupervisor(
                config.launch_daemons_directory
            ),
            update_binding=config.forge_update_binding,
            update_binding_provider=config.forge_update_binding_provider,
            lifecycle_executable=config.forge_lifecycle_executable,
            uninstall_binding=config.forge_uninstall_binding,
                instance_bootstrap=config.forge_instance_bootstrap,
        )
        return ResolvedManagedProductRoute(
            config.target.instance_id, None, {component: adapter}, None
        )
    assert isinstance(config.target, EPSystemInstanceTarget)
    assert config.engineering_platform_product_root is not None
    adapter = EngineeringPlatformSystemProvisionerAdapter(
        provisioner_executable=config.executable,
        product_root=config.engineering_platform_product_root,
        target=config.target,
        staged_artifacts=config.staged_artifacts,
    )
    return ResolvedManagedProductRoute(
        None, config.target.instance_id, {component: adapter}, None
    )


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
