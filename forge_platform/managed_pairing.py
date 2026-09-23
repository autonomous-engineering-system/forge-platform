"""Terminal Forge↔EP pairing commit for one managed deployment.

Product adapters perform the actual Forge peer configuration and EP/readiness
checks. This coordinator only validates exact instance correlation and commits
a non-secret pairing receipt reference to the Forge Platform registry.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json

from .managed_deployments import (
    ManagedDeployment,
    ManagedDeploymentError,
    ManagedDeploymentRegistry,
    ManagedPeerBinding,
)


class ManagedPairingError(RuntimeError):
    """Pairing evidence cannot be bound to the selected managed deployment."""


@dataclass(frozen=True)
class ManagedPairingEvidence:
    forge_instance_id: str
    ep_instance_id: str
    forge_configuration_reference: str
    forge_preflight_reference: str
    ep_readiness_reference: str

    def __post_init__(self) -> None:
        for label, value in (
            ("forge_instance_id", self.forge_instance_id),
            ("ep_instance_id", self.ep_instance_id),
            ("forge_configuration_reference", self.forge_configuration_reference),
            ("forge_preflight_reference", self.forge_preflight_reference),
            ("ep_readiness_reference", self.ep_readiness_reference),
        ):
            if not isinstance(value, str) or not value:
                raise ValueError(f"managed pairing {label} is required")
        for reference in (
            self.forge_configuration_reference,
            self.forge_preflight_reference,
            self.ep_readiness_reference,
        ):
            lowered = reference.casefold()
            if any(fragment in lowered for fragment in ("token", "password", "secret=", "authorization:")):
                raise ValueError("managed pairing evidence reference appears to contain secret material")

    @property
    def receipt_reference(self) -> str:
        payload = {
            "forge_instance_id": self.forge_instance_id,
            "ep_instance_id": self.ep_instance_id,
            "forge_configuration_reference": self.forge_configuration_reference,
            "forge_preflight_reference": self.forge_preflight_reference,
            "ep_readiness_reference": self.ep_readiness_reference,
        }
        digest = sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        return "receipt:pairing-" + digest


class ManagedDeploymentPairingCoordinator:
    def __init__(self, registry: ManagedDeploymentRegistry) -> None:
        self.registry = registry

    def commit(
        self,
        deployment_id: str,
        *,
        expected_revision: int,
        evidence: ManagedPairingEvidence,
    ) -> ManagedDeployment:
        current = self.registry.load(deployment_id)
        if current is None:
            raise ManagedPairingError("managed deployment does not exist")
        if current.revision != expected_revision:
            raise ManagedPairingError("managed deployment revision changed before pairing")
        by_component = current.by_component
        forge = by_component.get("forge-runtime")
        ep = by_component.get("engineering-platform-server")
        if forge is None or ep is None:
            raise ManagedPairingError("pairing requires both Forge and EP components")
        if (
            forge.instance_id != evidence.forge_instance_id
            or ep.instance_id != evidence.ep_instance_id
        ):
            raise ManagedPairingError("pairing evidence targets different product instances")

        binding = ManagedPeerBinding(
            evidence.forge_instance_id,
            evidence.ep_instance_id,
            evidence.receipt_reference,
        )
        if current.peer_binding is not None:
            if current.peer_binding == binding:
                return current
            if (
                current.peer_binding.forge_instance_id == binding.forge_instance_id
                and current.peer_binding.ep_instance_id == binding.ep_instance_id
            ):
                raise ManagedPairingError("existing peer binding has different terminal evidence")
            raise ManagedPairingError("managed deployment already binds a different peer pair")

        updated = ManagedDeployment(
            current.deployment_id,
            current.revision + 1,
            current.label,
            current.components,
            binding,
        )
        try:
            return self.registry.replace(updated, expected_revision=current.revision)
        except ManagedDeploymentError as error:
            raise ManagedPairingError("managed deployment changed during pairing commit") from error
