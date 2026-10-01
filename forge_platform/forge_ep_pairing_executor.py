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
        )

    def _pair(
        self, *, operation_id: str, deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest,
        ep_request: ComponentOperationRequest,
        forge_adapter: ProductOperationAdapter,
        ep_adapter: ProductOperationAdapter,
        detached_revision: int | None, detached_digest: str | None,
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
        )


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
