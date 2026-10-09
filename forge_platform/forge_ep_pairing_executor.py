"""Concrete product-owned Forge-to-Engineering-Platform pairing.

The helper supplies one immutable, secret-free binding. Pairing delegates the
durable peer configuration and authenticated compatibility preflight to Forge,
then independently requires the exact EP instance to read back healthy. No
product database or credential value crosses this boundary.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import ipaddress
import json
import re
from typing import Mapping
from urllib.parse import urlparse

from .component_operations import ComponentOperationRequest, ProductOperationAdapter
from .engineering_platform_system_adapter import (
    EngineeringPlatformSystemProvisionerAdapter,
)
from .forge_server_adapter import ForgeServerProductAdapter
from .managed_deployments import ManagedDeployment
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT
from .managed_pairing import ManagedPairingEvidence


_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")


class ForgeEPProductPairingError(RuntimeError):
    """The product-owned pairing route did not return exact terminal evidence."""


def _identifier(value: object, label: str) -> str:
    if not isinstance(value, str) or _IDENTIFIER.fullmatch(value) is None:
        raise ValueError(f"pairing {label} is invalid")
    return value


def _canonical_endpoint(value: object, *, allow_loopback_http: bool) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("pairing endpoint is required")
    try:
        parsed = urlparse(value)
        port = parsed.port
    except ValueError:
        raise ValueError("pairing endpoint is invalid") from None
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path not in {"", "/"}
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("pairing endpoint must be a credential-free HTTP(S) origin")
    if parsed.scheme == "http":
        loopback = parsed.hostname.casefold() == "localhost"
        try:
            loopback = loopback or ipaddress.ip_address(parsed.hostname).is_loopback
        except ValueError:
            pass
        if not allow_loopback_http or not loopback:
            raise ValueError("pairing HTTP endpoint requires explicit loopback")
    default_port = 443 if parsed.scheme == "https" else 80
    host = f"[{parsed.hostname}]" if ":" in parsed.hostname else parsed.hostname.casefold()
    authority = host if port in {None, default_port} else f"{host}:{port}"
    return f"{parsed.scheme}://{authority}"


@dataclass(frozen=True)
class ForgeEPProductPairingBinding:
    """Helper-owned public identities for one exact Forge-to-EP binding."""

    binding_id: str
    endpoint: str
    expected_ep_instance_id: str
    consumer_id: str
    host_id: str
    project_id: str
    repository_id: str
    repository_identity: str
    credential_reference: str
    operator_id: str
    allow_loopback_http: bool = False

    def __post_init__(self) -> None:
        for label in (
            "binding_id",
            "expected_ep_instance_id",
            "consumer_id",
            "host_id",
            "project_id",
            "repository_id",
            "repository_identity",
            "operator_id",
        ):
            _identifier(getattr(self, label), label)
        if not isinstance(self.allow_loopback_http, bool):
            raise ValueError("pairing loopback setting is invalid")
        endpoint = _canonical_endpoint(
            self.endpoint, allow_loopback_http=self.allow_loopback_http
        )
        if (
            not isinstance(self.credential_reference, str)
            or not self.credential_reference.startswith("keychain://")
            or len(self.credential_reference) > 512
            or any(character.isspace() for character in self.credential_reference)
        ):
            raise ValueError("pairing credential reference is invalid")
        object.__setattr__(self, "endpoint", endpoint)


@dataclass(frozen=True)
class ForgeEPInstallationPairingBinding:
    """Installation readback authority only; deliberately has no project fields."""

    operation_id: str
    binding_id: str
    endpoint: str
    expected_ep_instance_id: str
    consumer_id: str
    credential_reference: str
    allow_loopback_http: bool = False

    def __post_init__(self) -> None:
        for label in ("operation_id", "binding_id", "expected_ep_instance_id", "consumer_id"):
            value = getattr(self, label)
            pattern = r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}" if label == "operation_id" else r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}"
            if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
                raise ValueError("installation pairing identity is invalid")
        if not isinstance(self.allow_loopback_http, bool):
            raise ValueError("installation pairing transport is invalid")
        object.__setattr__(self, "endpoint", _canonical_endpoint(
            self.endpoint, allow_loopback_http=self.allow_loopback_http))
        if (not isinstance(self.credential_reference, str)
                or not self.credential_reference.startswith("keychain://")
                or len(self.credential_reference) > 512
                or any(c.isspace() for c in self.credential_reference)):
            raise ValueError("installation pairing credential reference is invalid")

    @property
    def command(self) -> tuple[str, ...]:
        args = ("installation-peer", "configure", "--operation-id", self.operation_id,
                "--binding-id", self.binding_id, "--endpoint", self.endpoint,
                "--expected-instance-id", self.expected_ep_instance_id,
                "--consumer-id", self.consumer_id,
                "--credential-reference", self.credential_reference)
        return args + (("--allow-loopback-http",) if self.allow_loopback_http else ())

    @classmethod
    def validate_command(cls, args: tuple[str, ...]) -> bool:
        if len(args) not in {14, 15} or args[:2] != ("installation-peer", "configure"):
            return False
        if args[2:14:2] != ("--operation-id", "--binding-id", "--endpoint",
                               "--expected-instance-id", "--consumer-id", "--credential-reference"):
            return False
        if len(args) == 15 and args[-1] != "--allow-loopback-http":
            return False
        try:
            binding = cls(*args[3:14:2], allow_loopback_http=len(args) == 15)
        except (TypeError, ValueError):
            return False
        return binding.command == args


class ForgeEPProductPairingExecutor:
    """Configure Forge's exact EP peer, preflight it, and bind EP readiness."""

    def __init__(self, binding: ForgeEPProductPairingBinding) -> None:
        if not isinstance(binding, ForgeEPProductPairingBinding):
            raise TypeError("Forge-to-EP pairing binding is required")
        self.binding = binding

    def pair(
        self,
        *,
        operation_id: str,
        deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest,
        ep_request: ComponentOperationRequest,
        forge_adapter: ProductOperationAdapter,
        ep_adapter: ProductOperationAdapter,
    ) -> ManagedPairingEvidence:
        return self._pair(
            operation_id=operation_id, deployment=deployment,
            forge_request=forge_request, ep_request=ep_request,
            forge_adapter=forge_adapter, ep_adapter=ep_adapter,
            detached_revision=None, detached_digest=None,
            configured_readback=None,
        )

    def _pair(
        self, *, operation_id: str, deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest,
        ep_request: ComponentOperationRequest,
        forge_adapter: ProductOperationAdapter,
        ep_adapter: ProductOperationAdapter,
        detached_revision: int | None, detached_digest: str | None,
        configured_readback: Mapping[str, object] | None,
    ) -> ManagedPairingEvidence:
        _identifier(operation_id, "operation_id")
        if not isinstance(deployment, ManagedDeployment):
            raise TypeError("managed deployment is required")
        if not isinstance(forge_request, ComponentOperationRequest) or not isinstance(
            ep_request, ComponentOperationRequest
        ):
            raise TypeError("exact Forge and EP requests are required")
        if not isinstance(forge_adapter, ForgeServerProductAdapter):
            raise TypeError("concrete Forge Server adapter is required")
        if not isinstance(ep_adapter, EngineeringPlatformSystemProvisionerAdapter):
            raise TypeError("concrete Engineering Platform adapter is required")

        forge = deployment.by_component.get(FORGE_COMPONENT)
        ep = deployment.by_component.get(EP_COMPONENT)
        if (
            forge is None
            or ep is None
            or forge.instance_id != forge_request.installation_identity
            or ep.instance_id != ep_request.installation_identity
            or ep.instance_id != self.binding.expected_ep_instance_id
            or forge_request.component != FORGE_COMPONENT
            or ep_request.component != EP_COMPONENT
        ):
            raise ForgeEPProductPairingError("pairing route does not match exact product instances")

        configured = configured_readback
        if configured is None:
            configured = forge_adapter.configure_ep_peer(
                binding_id=self.binding.binding_id,
                endpoint=self.binding.endpoint,
                expected_instance_id=self.binding.expected_ep_instance_id,
                consumer_id=self.binding.consumer_id,
                host_id=self.binding.host_id,
                project_id=self.binding.project_id,
                repository_id=self.binding.repository_id,
                repository_identity=self.binding.repository_identity,
                credential_reference=self.binding.credential_reference,
                operator_id=self.binding.operator_id,
                allow_loopback_http=self.binding.allow_loopback_http,
                expected_revision=detached_revision,
                expected_digest=detached_digest,
            )
        configuration = _mapping(configured.get("configuration"), "Forge peer configuration")
        expected_configuration = {
            "binding_id": self.binding.binding_id,
            "endpoint": self.binding.endpoint,
            "expected_ep_instance_id": self.binding.expected_ep_instance_id,
            "ep_consumer_id": self.binding.consumer_id,
            "execution_host_id": self.binding.host_id,
            "ep_project_id": self.binding.project_id,
            "ep_repository_id": self.binding.repository_id,
            "repository_identity": self.binding.repository_identity,
            "credential_reference": self.binding.credential_reference,
            "allow_loopback_http": self.binding.allow_loopback_http,
        }
        if configured.get("status") != "CONFIGURED" or any(
            configuration.get(key) != value
            for key, value in expected_configuration.items()
        ):
            raise ForgeEPProductPairingError("Forge peer configuration readback changed")

        preflight = forge_adapter.preflight_ep_peer()
        declaration = _mapping(preflight.get("declaration"), "Forge EP preflight declaration")
        instance = _mapping(declaration.get("instance"), "Forge EP preflight instance")
        authentication = _mapping(
            declaration.get("authentication"), "Forge EP preflight authentication"
        )
        if (
            preflight.get("status") != "PASS"
            or preflight.get("configuration_status") != "CONFIGURED"
            or preflight.get("peer_instance_consistency") != "PASS"
            or preflight.get("compatibility") != "PASS"
            or preflight.get("authenticated_consumer_identity") != self.binding.consumer_id
            or preflight.get("project_repository_scope") != "PASS"
            or preflight.get("mutation_authority") != "SUBMISSION_AUTHORIZED"
            or instance.get("id") != self.binding.expected_ep_instance_id
            or authentication.get("consumer_id") != self.binding.consumer_id
            or authentication.get("project_id") != self.binding.project_id
            or authentication.get("repository_id") != self.binding.repository_id
        ):
            raise ForgeEPProductPairingError("Forge EP authenticated preflight did not pass")

        ep_readback = ep_adapter.readback(ep_request)
        if (
            ep_readback.state != "ACTIVE"
            or ep_readback.health_state != "HEALTHY"
            or ep_readback.selected_instance_identity != self.binding.expected_ep_instance_id
            or ep_readback.artifact != ep_request.artifact.correlation
        ):
            raise ForgeEPProductPairingError("EP exact instance readiness did not pass")

        return ManagedPairingEvidence(
            forge_request.installation_identity,
            ep_request.installation_identity,
            _reference("forge-peer-configuration", configured),
            _reference("forge-peer-preflight", preflight),
            ep_readback.health_evidence_reference or ep_readback.evidence_reference,
        )

    def pair_after_product_detach(
        self, *, operation_id: str, deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest,
        ep_request: ComponentOperationRequest,
        forge_adapter: ForgeServerProductAdapter,
        ep_adapter: EngineeringPlatformSystemProvisionerAdapter,
        old_binding_id: str, old_consumer_id: str,
        detach_operation_id: str, detach_revision: int,
        detach_configuration_digest: str, detach_operator_id: str,
    ) -> ManagedPairingEvidence:
        """Guarded Forge-owned replacement after an exact terminal detach readback.

        The caller must separately prove EP OLD revoke, NEW issue/secure-store
        terminal readback, reviewed plan currency and durable operation resume.
        """
        self._require_replacement_target(
            deployment=deployment, forge_adapter=forge_adapter, ep_adapter=ep_adapter,
            old_binding_id=old_binding_id, old_consumer_id=old_consumer_id,
            detach_operation_id=detach_operation_id, detach_revision=detach_revision,
            detach_configuration_digest=detach_configuration_digest,
            detach_operator_id=detach_operator_id,
        )
        status = forge_adapter.read_detach_ep_peer(
            operation_id=detach_operation_id, binding_id=old_binding_id,
            revision=detach_revision,
            configuration_digest=detach_configuration_digest,
            operator_id=detach_operator_id,
        )
        if not isinstance(status, Mapping):
            raise ForgeEPProductPairingError("exact Forge detach status is unavailable")
        receipt = status.get("receipt")
        if (
            status.get("current_peer_status") != "DETACHED"
            or not isinstance(receipt, Mapping)
            or receipt.get("next_configuration_revision") != detach_revision + 1
            or not isinstance(receipt.get("receipt_digest"), str)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", receipt["receipt_digest"])
        ):
            raise ForgeEPProductPairingError("exact Forge detach status is unavailable")
        return self._pair(
            operation_id=operation_id, deployment=deployment,
            forge_request=forge_request, ep_request=ep_request,
            forge_adapter=forge_adapter, ep_adapter=ep_adapter,
            detached_revision=receipt["next_configuration_revision"],
            detached_digest=receipt["receipt_digest"],
            configured_readback=None,
        )

    def recover_after_product_replace(
        self, *, operation_id: str, deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest,
        ep_request: ComponentOperationRequest,
        forge_adapter: ForgeServerProductAdapter,
        ep_adapter: EngineeringPlatformSystemProvisionerAdapter,
        old_binding_id: str, old_consumer_id: str,
        detach_operation_id: str, detach_revision: int,
        detach_configuration_digest: str, detach_operator_id: str,
    ) -> ManagedPairingEvidence:
        """Recover a lost configure response by product-owned reads only."""
        self._require_replacement_target(
            deployment=deployment, forge_adapter=forge_adapter, ep_adapter=ep_adapter,
            old_binding_id=old_binding_id, old_consumer_id=old_consumer_id,
            detach_operation_id=detach_operation_id, detach_revision=detach_revision,
            detach_configuration_digest=detach_configuration_digest,
            detach_operator_id=detach_operator_id,
        )
        status = forge_adapter.read_historical_detach_ep_peer(
            operation_id=detach_operation_id, binding_id=old_binding_id,
            revision=detach_revision,
            configuration_digest=detach_configuration_digest,
            operator_id=detach_operator_id,
        )
        if not isinstance(status, Mapping):
            raise ForgeEPProductPairingError("replacement product generation changed")
        receipt = status.get("receipt")
        configured = forge_adapter.read_configured_ep_peer()
        if not isinstance(configured, Mapping):
            raise ForgeEPProductPairingError("replacement product generation changed")
        configuration = configured.get("configuration")
        if (
            status.get("current_peer_status") != "CONFIGURED"
            or not isinstance(receipt, Mapping)
            or receipt.get("next_configuration_revision") != detach_revision + 1
            or not isinstance(configuration, Mapping)
            or configuration.get("configuration_revision") != detach_revision + 2
            or not isinstance(configuration.get("configuration_digest"), str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", configuration["configuration_digest"]) is None
        ):
            raise ForgeEPProductPairingError("replacement product generation changed")
        return self._pair(
            operation_id=operation_id, deployment=deployment,
            forge_request=forge_request, ep_request=ep_request,
            forge_adapter=forge_adapter, ep_adapter=ep_adapter,
            detached_revision=None, detached_digest=None,
            configured_readback=configured,
        )

    def _require_replacement_target(
        self, *, deployment: ManagedDeployment,
        forge_adapter: ForgeServerProductAdapter,
        ep_adapter: EngineeringPlatformSystemProvisionerAdapter,
        old_binding_id: str, old_consumer_id: str,
        detach_operation_id: str, detach_revision: int,
        detach_configuration_digest: str, detach_operator_id: str,
    ) -> None:
        if (
            not isinstance(forge_adapter, ForgeServerProductAdapter)
            or not isinstance(ep_adapter, EngineeringPlatformSystemProvisionerAdapter)
            or not isinstance(deployment, ManagedDeployment)
            or deployment.peer_binding is None
            or deployment.peer_binding.forge_instance_id != forge_adapter.target.instance_id
            or deployment.peer_binding.ep_instance_id != self.binding.expected_ep_instance_id
            or not isinstance(old_binding_id, str)
            or _IDENTIFIER.fullmatch(old_binding_id) is None
            or not isinstance(old_consumer_id, str)
            or _IDENTIFIER.fullmatch(old_consumer_id) is None
            or not isinstance(detach_operation_id, str)
            or _IDENTIFIER.fullmatch(detach_operation_id) is None
            or isinstance(detach_revision, bool)
            or not isinstance(detach_revision, int)
            or detach_revision < 1
            or not isinstance(detach_configuration_digest, str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", detach_configuration_digest) is None
            or not isinstance(detach_operator_id, str)
            or _IDENTIFIER.fullmatch(detach_operator_id) is None
            or old_binding_id == self.binding.binding_id
            or old_consumer_id == self.binding.consumer_id
        ):
            raise ForgeEPProductPairingError("replacement product target or binding changed")


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise ForgeEPProductPairingError(f"{label} is invalid")
    return value


def _reference(label: str, value: Mapping[str, object]) -> str:
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ForgeEPProductPairingError("pairing evidence is not canonical JSON") from error
    return f"{label}:sha256:{sha256(encoded).hexdigest()}"


class ForgeEPInstallationPairingExecutor:
    """Require durable installation binding and readback without project authority."""

    def __init__(self, binding: ForgeEPInstallationPairingBinding) -> None:
        if not isinstance(binding, ForgeEPInstallationPairingBinding):
            raise TypeError("installation pairing binding is required")
        self.binding = binding

    def pair(
        self, *, operation_id: str, deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest, ep_request: ComponentOperationRequest,
        forge_adapter: ProductOperationAdapter, ep_adapter: ProductOperationAdapter,
    ) -> ManagedPairingEvidence:
        from .qualified_forge_lifecycle import qualified_forge_installation_pairing_artifact
        if (not isinstance(deployment, ManagedDeployment)
                or not isinstance(forge_request, ComponentOperationRequest)
                or not isinstance(ep_request, ComponentOperationRequest)
                or not isinstance(forge_adapter, ForgeServerProductAdapter)
                or not isinstance(ep_adapter, EngineeringPlatformSystemProvisionerAdapter)):
            raise TypeError("exact deployment, product requests and adapters are required")
        forge = deployment.by_component.get(FORGE_COMPONENT)
        ep = deployment.by_component.get(EP_COMPONENT)
        if (operation_id != self.binding.operation_id or forge is None or ep is None
                or forge_request.component != FORGE_COMPONENT or ep_request.component != EP_COMPONENT
                or forge_request.requested_role != "server" or ep_request.requested_role != "server"
                or forge.instance_id != forge_request.installation_identity
                or forge.instance_id != forge_adapter.target.instance_id
                or ep.instance_id != ep_request.installation_identity
                or ep.instance_id != ep_adapter.target.instance_id
                or ep.instance_id != self.binding.expected_ep_instance_id
                or forge_request.artifact != forge_adapter.installed_artifact
                or not qualified_forge_installation_pairing_artifact(forge_request.artifact)):
            raise ForgeEPProductPairingError("installation pairing route changed")
        runtime_id = forge_adapter.target.product_runtime_id
        _identifier(runtime_id, "Forge runtime")
        self._require_ep(ep_adapter.readback(ep_request), ep_request)
        configured = forge_adapter.configure_installation_peer(self.binding)
        configuration = _mapping(configured.get("configuration"), "installation configuration")
        expected = dict(binding_id=self.binding.binding_id, endpoint=self.binding.endpoint,
                        ep_instance_id=self.binding.expected_ep_instance_id, forge_instance_id=runtime_id,
                        consumer_id=self.binding.consumer_id, credential_reference=self.binding.credential_reference,
                        allow_loopback_http=self.binding.allow_loopback_http, operation_id=operation_id)
        if (configured.get("status") != "CONFIGURED" or configured.get("execution_ready") is not False
                or type(configuration.get("allow_loopback_http")) is not bool
                or set(configuration) != set(expected) | {"timeout_seconds", "installation_id", "operator_binding_version"}
                or any(configuration.get(k) != v for k, v in expected.items())
                or not isinstance(configuration.get("installation_id"), str)
                or not configuration["installation_id"]
                or type(configuration.get("operator_binding_version")) is not int
                or configuration["operator_binding_version"] < 1
                or type(configuration.get("timeout_seconds")) not in (int, float)
                or not 0 < configuration["timeout_seconds"] <= 60):
            raise ForgeEPProductPairingError("installation configuration authority changed")
        digest = "sha256:" + sha256(json.dumps(dict(configuration), sort_keys=True,
                          separators=(",", ":"), allow_nan=False).encode()).hexdigest()
        if configured.get("configuration_digest") != digest:
            raise ForgeEPProductPairingError("installation configuration digest changed")
        readback = forge_adapter.read_installation_peer()
        if readback != configured:
            raise ForgeEPProductPairingError("durable installation configuration changed")
        preflight = forge_adapter.preflight_installation_peer()
        expected_preflight = dict(status="CONNECTED", binding_id=self.binding.binding_id,
                                 ep_instance_id=self.binding.expected_ep_instance_id, forge_instance_id=runtime_id,
                                 consumer_id=self.binding.consumer_id, contract_version="1.0",
                                 purpose="INSTALLATION_READBACK", project_authorized=False,
                                 execution_ready=False, configuration_digest=digest)
        if (preflight != expected_preflight or preflight.get("project_authorized") is not False
                or preflight.get("execution_ready") is not False):
            raise ForgeEPProductPairingError("authenticated installation connectivity did not pass")
        ep_readback = ep_adapter.readback(ep_request)
        self._require_ep(ep_readback, ep_request)
        return ManagedPairingEvidence(
            forge.instance_id, ep.instance_id,
            _reference("forge-installation-configuration", readback),
            _reference("forge-installation-preflight", preflight),
            ep_readback.health_evidence_reference or ep_readback.evidence_reference,
        )

    def _require_ep(self, readback, request: ComponentOperationRequest) -> None:
        if (readback.state != "ACTIVE" or readback.health_state != "HEALTHY"
                or readback.selected_instance_identity != self.binding.expected_ep_instance_id
                or readback.artifact != request.artifact.correlation):
            raise ForgeEPProductPairingError("exact EP installation readiness did not pass")
