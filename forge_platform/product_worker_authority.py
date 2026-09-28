"""Secure fixed-layout authority for the privileged installer product worker.

The native installer publishes one canonical, root-owned snapshot after signed
catalog and installer-currentness verification.  The worker accepts public
identities and ports from that snapshot, but it never accepts executable,
state, artifact, credential, or service-definition paths.  Every such path is
derived from the fixed helper root below.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
from typing import Callable, Mapping

from .engineering_platform_system_adapter import EPSystemInstanceTarget
from .forge_ep_pairing_executor import ForgeEPProductPairingBinding
from .forge_server_adapter import ForgeServerTarget, ForgeUninstallBinding
from .managed_deployments import ManagedDeploymentRegistry
from .managed_install_flow import ManagedForgeEPInstallationCoordinator
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .managed_product_operation_service import (
    ManagedProductOperationHelperBuilder,
    ManagedProductOperationHelperService,
)
from .released_product_routes import (
    ReleasedManagedProductRouteConfiguration,
    ReleasedManagedSingleProductRouteConfiguration,
)
from .universal_installer import CompositionManifest, UniversalInstallerError


PRODUCT_WORKER_AUTHORITY_SCHEMA = "forge-platform.product-worker-authority/v3"
PRODUCT_WORKER_SINGLE_AUTHORITY_SCHEMA = "forge-platform.product-worker-authority/v4"
PRODUCT_WORKER_ROOT = Path(
    "/Library/Application Support/AutonomousEngineeringSystem/ForgePlatformInstaller"
)
PRODUCT_WORKER_AUTHORITY_FILE = "product-worker-authority.json"
MAXIMUM_PRODUCT_WORKER_AUTHORITY_BYTES = 4 * 1_024 * 1_024
_TOP_FIELDS = frozenset({
    "schema", "installer_release", "candidate_manifests",
    "installed_manifests", "routes",
})
_TOP_FIELDS_V4 = _TOP_FIELDS | {"single_routes"}
_RELEASE_FIELDS = frozenset({
    "version", "release_page", "asset_name", "sha256", "signing_key_id",
})
_MANIFEST_FIELDS = frozenset({"digest", "payload"})
_ROUTE_FIELDS = frozenset({
    "deployment_id", "forge_instance_id", "forge_service_account",
    "forge_bind_port", "forge_artifact_sha256", "forge_installation_id", "ep_instance_id",
    "ep_artifact_sha256",
    "ep_display_label", "ep_service_account", "ep_bind_port", "pairing",
})
_SINGLE_ROUTE_FIELDS = frozenset({
    "deployment_id", "component_identity", "instance_id", "service_account",
    "bind_port", "artifact_sha256", "forge_installation_id", "ep_display_label",
})
_PAIRING_FIELDS = frozenset({
    "binding_id", "consumer_id", "host_id", "project_id", "repository_id",
    "repository_identity", "credential_reference", "operator_id",
})
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_ACCOUNT = re.compile(r"^_[a-z][a-z0-9_]{0,30}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


class ProductWorkerAuthorityError(RuntimeError):
    """The released worker authority is absent, unsafe, or contradictory."""


@dataclass(frozen=True)
class _AuthoritySnapshot:
    raw_bytes: bytes
    release: NativeInstallerReleaseBinding
    candidates: tuple[CompositionManifest, ...]
    installed: tuple[CompositionManifest, ...]
    routes: tuple[Mapping[str, object], ...]
    single_routes: tuple[Mapping[str, object], ...]


class _StableAuthorityCurrencyGuard:
    """Rebind each mutation to the native-verified immutable local snapshot."""

    def __init__(self, read: Callable[[], bytes], expected_digest: str) -> None:
        self._read = read
        self._expected_digest = expected_digest

    def require_current(
        self,
        *,
        deployment_id: str,
        mutation: str,
        component: str | None,
        instance_id: str | None,
        operation_id: str,
    ) -> str:
        raw = self._read()
        if "sha256:" + sha256(raw).hexdigest() != self._expected_digest:
            raise ProductWorkerAuthorityError(
                "product-worker authority changed before mutation"
            )
        correlation = json.dumps(
            [deployment_id, mutation, component, instance_id, operation_id],
            separators=(",", ":"),
        ).encode("utf-8")
        return "currency:" + sha256(correlation + raw).hexdigest()


class ProductWorkerAuthorityLoader:
    """Load the one immutable helper snapshot and compose concrete adapters."""

    def __init__(
        self,
        *,
        root: Path = PRODUCT_WORKER_ROOT,
        expected_owner_uid: int = 0,
        launch_daemons_directory: Path = Path("/Library/LaunchDaemons"),
    ) -> None:
        if (
            not isinstance(root, Path)
            or not root.is_absolute()
            or isinstance(expected_owner_uid, bool)
            or not isinstance(expected_owner_uid, int)
            or expected_owner_uid < 0
            or not isinstance(launch_daemons_directory, Path)
            or not launch_daemons_directory.is_absolute()
        ):
            raise ValueError("product-worker loader configuration is invalid")
        self.root = root
        self.expected_owner_uid = expected_owner_uid
        self.launch_daemons_directory = launch_daemons_directory
        self.authority_path = root / PRODUCT_WORKER_AUTHORITY_FILE

    def load(self) -> ManagedProductOperationHelperService:
        snapshot = self._snapshot()
        authority_digest = "sha256:" + sha256(snapshot.raw_bytes).hexdigest()
        configurations = tuple(
            self._route(value, snapshot.candidates, snapshot.installed)
            for value in snapshot.routes
        ) + tuple(
            self._single_route(value, snapshot.candidates, snapshot.installed)
            for value in snapshot.single_routes
        )
        claims = [
            (config.forge_target.service_account, config.forge_target.bind_port)
            for config in configurations
            if isinstance(config, ReleasedManagedProductRouteConfiguration)
        ] + [
            (
                config.engineering_platform_target.service_account,
                config.engineering_platform_target.bind_port,
            )
            for config in configurations
            if isinstance(config, ReleasedManagedProductRouteConfiguration)
        ] + [
            (config.target.service_account, config.target.bind_port)
            for config in configurations
            if isinstance(config, ReleasedManagedSingleProductRouteConfiguration)
        ]
        if len({account for account, _port_value in claims}) != len(claims):
            raise ProductWorkerAuthorityError(
                "product routes reuse a service account"
            )
        if len({port_value for _account_value, port_value in claims}) != len(claims):
            raise ProductWorkerAuthorityError("product routes reuse a bind port")
        installation_ids = [
            config.forge_uninstall_binding.installation_id
            for config in configurations
            if config.forge_uninstall_binding is not None
        ]
        if len(set(installation_ids)) != len(installation_ids):
            raise ProductWorkerAuthorityError("product routes reuse a Forge installation id")
        pairing_scopes = [
            (config.pairing_binding.consumer_id, config.pairing_binding.project_id)
            for config in configurations
            if isinstance(config, ReleasedManagedProductRouteConfiguration)
        ]
        if len(set(pairing_scopes)) != len(pairing_scopes):
            raise ProductWorkerAuthorityError("product routes reuse an EP consumer scope")
        credentials = [
            config.pairing_binding.credential_reference for config in configurations
            if isinstance(config, ReleasedManagedProductRouteConfiguration)
        ]
        if len(set(credentials)) != len(credentials):
            raise ProductWorkerAuthorityError("product routes reuse a pairing credential reference")
        registry = ManagedDeploymentRegistry(self.root / "state/deployments")
        coordinator = ManagedForgeEPInstallationCoordinator(
            operations_root=self.root / "state/product-operations",
            component_operations_root=self.root / "state/component-operations",
            registry=registry,
            currency_guard=_StableAuthorityCurrencyGuard(
                self._read_secure_authority, authority_digest
            ),
        )
        return ManagedProductOperationHelperBuilder.build_pinned(
            current_installer_release=snapshot.release,
            candidate_manifests=snapshot.candidates,
            installed_manifests=snapshot.installed,
            coordinator=coordinator,
            route_configurations=configurations,
        )

    def _snapshot(self) -> _AuthoritySnapshot:
        raw = self._read_secure_authority()
        payload = _strict_canonical_mapping(raw, "product-worker authority")
        schema = payload.get("schema")
        if schema == PRODUCT_WORKER_AUTHORITY_SCHEMA:
            _exact_fields(payload, _TOP_FIELDS, "product-worker authority")
        elif schema == PRODUCT_WORKER_SINGLE_AUTHORITY_SCHEMA:
            _exact_fields(payload, _TOP_FIELDS_V4, "product-worker authority")
        else:
            raise ProductWorkerAuthorityError("product-worker authority schema is unsupported")
        release_wire = _mapping(payload["installer_release"], "installer release")
        _exact_fields(release_wire, _RELEASE_FIELDS, "installer release")
        release = NativeInstallerReleaseBinding(
            _string(release_wire["version"], "installer version"),
            _string(release_wire["release_page"], "installer release page"),
            _string(release_wire["asset_name"], "installer asset name"),
            _digest(release_wire["sha256"], "installer sha256"),
            _string(release_wire["signing_key_id"], "installer signing key id"),
        )
        candidates = self._manifests(payload["candidate_manifests"], required=True)
        installed = self._manifests(payload["installed_manifests"], required=False)
        routes = tuple(
            _mapping(value, "product route")
            for value in _list(payload["routes"], "product routes")
        )
        single_routes = tuple(
            _mapping(value, "single-product route")
            for value in _list(
                payload["single_routes"] if schema == PRODUCT_WORKER_SINGLE_AUTHORITY_SCHEMA else [],
                "single-product routes",
            )
        )
        if not routes and not single_routes:
            raise ProductWorkerAuthorityError("product-worker routes are unavailable")
        if schema == PRODUCT_WORKER_SINGLE_AUTHORITY_SCHEMA and not single_routes:
            raise ProductWorkerAuthorityError("v4 single-product routes are unavailable")
        return _AuthoritySnapshot(raw, release, candidates, installed, routes, single_routes)

    def _manifests(
        self, value: object, *, required: bool
    ) -> tuple[CompositionManifest, ...]:
        entries = _list(value, "composition manifests")
        if required and not entries:
            raise ProductWorkerAuthorityError("candidate composition authority is unavailable")
        result: list[CompositionManifest] = []
        for value in entries:
            wire = _mapping(value, "composition authority")
            _exact_fields(wire, _MANIFEST_FIELDS, "composition authority")
            digest = _digest(wire["digest"], "composition manifest digest")
            raw = _canonical_json(_mapping(wire["payload"], "composition manifest payload"))
            try:
                result.append(
                    CompositionManifest.from_digest_bound_bytes(
                        raw, manifest_digest=digest
                    )
                )
            except (TypeError, ValueError, UniversalInstallerError) as error:
                raise ProductWorkerAuthorityError(
                    "composition manifest authority is invalid"
                ) from error
        return tuple(result)

    def _route(
        self,
        wire: Mapping[str, object],
        candidates: tuple[CompositionManifest, ...],
        installed: tuple[CompositionManifest, ...],
    ) -> ReleasedManagedProductRouteConfiguration:
        _exact_fields(wire, _ROUTE_FIELDS, "product route")
        deployment = _safe_id(wire["deployment_id"], "deployment id")
        forge_instance = _safe_id(wire["forge_instance_id"], "Forge instance id")
        forge_installation = _safe_id(
            wire["forge_installation_id"], "Forge installation id"
        )
        ep_instance = _safe_id(wire["ep_instance_id"], "EP instance id")
        forge_account = _account(wire["forge_service_account"], "Forge account")
        ep_account = _account(wire["ep_service_account"], "EP account")
        forge_port = _port(wire["forge_bind_port"], "Forge port")
        ep_port = _port(wire["ep_bind_port"], "EP port")
        if forge_port == ep_port:
            raise ProductWorkerAuthorityError("product route ports are ambiguous")
        artifact_digest = _digest(
            wire["forge_artifact_sha256"], "Forge artifact sha256"
        )
        ep_artifact_digest = _digest(
            wire["ep_artifact_sha256"], "EP artifact sha256"
        )
        artifacts = {
            component.artifact.digest: component.artifact
            for manifest in candidates + installed
            for component in manifest.components
            if component.identity in {"forge-runtime", "engineering-platform-server"}
        }
        forge_artifact = artifacts.get(artifact_digest)
        if forge_artifact is None:
            raise ProductWorkerAuthorityError("Forge artifact lacks manifest authority")
        ep_artifact = artifacts.get(ep_artifact_digest)
        if ep_artifact is None or ep_artifact_digest == artifact_digest:
            raise ProductWorkerAuthorityError("EP artifact lacks manifest authority")
        pairing = _mapping(wire["pairing"], "pairing authority")
        _exact_fields(pairing, _PAIRING_FIELDS, "pairing authority")
        instances = self.root / "instances/forge"
        venvs = self.root / "product-venvs" / deployment
        staged = {
            digest: self.root / "staged" / f"{digest.removeprefix('sha256:')}.artifact"
            for digest in artifacts
        }
        return ReleasedManagedProductRouteConfiguration(
            deployment_id=deployment,
            forge_executable=venvs / "forge/bin/forge",
            forge_target=ForgeServerTarget(
                forge_instance,
                instances / forge_instance,
                instances,
                forge_account,
                forge_port,
                self.root / "credentials/forge" / f"{forge_instance}.token",
            ),
            forge_installed_artifact=forge_artifact,
            engineering_platform_installed_artifact=ep_artifact,
            engineering_platform_provisioner=(
                venvs / "engineering-platform/bin/engineering-platform-system-provisioner"
            ),
            engineering_platform_product_root=self.root / "products/engineering-platform",
            engineering_platform_target=EPSystemInstanceTarget(
                ep_instance,
                _string(wire["ep_display_label"], "EP display label"),
                ep_account,
                ep_port,
            ),
            staged_artifacts=staged,
            pairing_binding=ForgeEPProductPairingBinding(
                _pairing_string(pairing, "binding_id"),
                f"http://127.0.0.1:{ep_port}",
                ep_instance,
                _pairing_string(pairing, "consumer_id"),
                _pairing_string(pairing, "host_id"),
                _pairing_string(pairing, "project_id"),
                _pairing_string(pairing, "repository_id"),
                _pairing_string(pairing, "repository_identity"),
                _pairing_string(pairing, "credential_reference"),
                _pairing_string(pairing, "operator_id"),
                True,
            ),
            forge_lifecycle_executable=venvs / "forge/bin/forge",
            forge_uninstall_binding=ForgeUninstallBinding(
                forge_instance, forge_installation
            ),
            launch_daemons_directory=self.launch_daemons_directory,
        )

    def _single_route(
        self,
        wire: Mapping[str, object],
        candidates: tuple[CompositionManifest, ...],
        installed: tuple[CompositionManifest, ...],
    ) -> ReleasedManagedSingleProductRouteConfiguration:
        _exact_fields(wire, _SINGLE_ROUTE_FIELDS, "single-product route")
        deployment = _safe_id(wire["deployment_id"], "deployment id")
        instance = _safe_id(wire["instance_id"], "product instance id")
        account = _account(wire["service_account"], "product account")
        port = _port(wire["bind_port"], "product port")
        digest = _digest(wire["artifact_sha256"], "product artifact sha256")
        component = wire["component_identity"]
        if component not in {"forge-runtime", "engineering-platform-server"}:
            raise ProductWorkerAuthorityError("single-product component is unsupported")
        artifacts = {
            item.artifact.digest: item.artifact
            for manifest in candidates + installed
            for item in manifest.components
            if item.identity == component
        }
        artifact = artifacts.get(digest)
        if artifact is None:
            raise ProductWorkerAuthorityError("single-product artifact lacks manifest authority")
        staged = {
            value: self.root / "staged" / f"{value.removeprefix('sha256:')}.artifact"
            for value in artifacts
        }
        venvs = self.root / "product-venvs" / deployment
        if component == "forge-runtime":
            if wire["ep_display_label"] is not None:
                raise ProductWorkerAuthorityError("single Forge route carries EP authority")
            installation = _safe_id(
                wire["forge_installation_id"], "Forge installation id"
            )
            instances = self.root / "instances/forge"
            return ReleasedManagedSingleProductRouteConfiguration(
                deployment_id=deployment,
                component_identity=component,
                executable=venvs / "forge/bin/forge",
                target=ForgeServerTarget(
                    instance, instances / instance, instances, account, port,
                    self.root / "credentials/forge" / f"{instance}.token",
                ),
                installed_artifact=artifact,
                staged_artifacts=staged,
                forge_lifecycle_executable=venvs / "forge/bin/forge",
                forge_uninstall_binding=ForgeUninstallBinding(instance, installation),
                launch_daemons_directory=self.launch_daemons_directory,
            )
        if wire["forge_installation_id"] is not None:
            raise ProductWorkerAuthorityError("single EP route carries Forge uninstall authority")
        return ReleasedManagedSingleProductRouteConfiguration(
            deployment_id=deployment,
            component_identity=component,
            executable=(
                venvs / "engineering-platform/bin/engineering-platform-system-provisioner"
            ),
            target=EPSystemInstanceTarget(
                instance, _string(wire["ep_display_label"], "EP display label"),
                account, port,
            ),
            installed_artifact=artifact,
            staged_artifacts=staged,
            engineering_platform_product_root=self.root / "products/engineering-platform",
        )

    def _read_secure_authority(self) -> bytes:
        try:
            root_status = os.lstat(self.root)
        except OSError as error:
            raise ProductWorkerAuthorityError("product-worker root is unavailable") from error
        if (
            not stat.S_ISDIR(root_status.st_mode)
            or root_status.st_uid != self.expected_owner_uid
            or stat.S_IMODE(root_status.st_mode) != 0o700
        ):
            raise ProductWorkerAuthorityError("product-worker root is unsafe")
        nofollow = getattr(os, "O_NOFOLLOW", None)
        if nofollow is None:
            raise ProductWorkerAuthorityError("product-worker authority requires no-follow open")
        try:
            root_fd = os.open(
                self.root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | nofollow,
            )
        except OSError as error:
            raise ProductWorkerAuthorityError("product-worker root is unsafe") from error
        descriptor = -1
        try:
            opened_root = os.fstat(root_fd)
            if (root_status.st_dev, root_status.st_ino) != (
                opened_root.st_dev,
                opened_root.st_ino,
            ):
                raise ProductWorkerAuthorityError("product-worker root changed while opened")
            descriptor = os.open(
                PRODUCT_WORKER_AUTHORITY_FILE,
                os.O_RDONLY | os.O_NONBLOCK | nofollow,
                dir_fd=root_fd,
            )
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != self.expected_owner_uid
                or before.st_nlink != 1
                or stat.S_IMODE(before.st_mode) != 0o600
                or not 0 < before.st_size <= MAXIMUM_PRODUCT_WORKER_AUTHORITY_BYTES
            ):
                raise ProductWorkerAuthorityError("product-worker authority file is unsafe")
            chunks: list[bytes] = []
            remaining = MAXIMUM_PRODUCT_WORKER_AUTHORITY_BYTES + 1
            while remaining:
                chunk = os.read(descriptor, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            after = os.fstat(descriptor)
            if len(raw) != before.st_size or len(raw) > MAXIMUM_PRODUCT_WORKER_AUTHORITY_BYTES or (
                before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
            ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ProductWorkerAuthorityError("product-worker authority changed while read")
            return raw
        except ProductWorkerAuthorityError:
            raise
        except OSError as error:
            raise ProductWorkerAuthorityError("product-worker authority is unreadable") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            os.close(root_fd)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_value: str):
    raise ValueError("non-finite JSON value")


def _canonical_json(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("utf-8")


def _strict_canonical_mapping(raw: bytes, label: str) -> Mapping[str, object]:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise ProductWorkerAuthorityError(f"{label} is not strict JSON") from error
    if not isinstance(value, dict) or _canonical_json(value) != raw:
        raise ProductWorkerAuthorityError(f"{label} is not canonical JSON")
    return value


def _exact_fields(value: Mapping[str, object], fields: frozenset[str], label: str) -> None:
    if frozenset(value) != fields:
        raise ProductWorkerAuthorityError(f"{label} shape is invalid")


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise ProductWorkerAuthorityError(f"{label} must be an object")
    return value


def _list(value: object, label: str) -> list[object]:
    if not isinstance(value, list):
        raise ProductWorkerAuthorityError(f"{label} must be an array")
    return value


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 2_048:
        raise ProductWorkerAuthorityError(f"{label} is invalid")
    return value


def _safe_id(value: object, label: str) -> str:
    text = _string(value, label)
    if _SAFE_ID.fullmatch(text) is None:
        raise ProductWorkerAuthorityError(f"{label} is invalid")
    return text


def _account(value: object, label: str) -> str:
    text = _string(value, label)
    if _ACCOUNT.fullmatch(text) is None:
        raise ProductWorkerAuthorityError(f"{label} is invalid")
    return text


def _digest(value: object, label: str) -> str:
    text = _string(value, label)
    if _DIGEST.fullmatch(text) is None:
        raise ProductWorkerAuthorityError(f"{label} is invalid")
    return text


def _port(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535:
        raise ProductWorkerAuthorityError(f"{label} is invalid")
    return value


def _pairing_string(value: Mapping[str, object], field: str) -> str:
    return _string(value[field], f"pairing {field}")
