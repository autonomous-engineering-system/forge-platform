"""Terminal composition binding for one managed deployment.

This is the only Python-side boundary that promotes product/readiness evidence
into a durable installed-composition identity. It stores no raw product output,
provider credentials, URLs or filesystem paths.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json

from .managed_deployments import (
    ManagedCompositionBinding,
    ManagedDeployment,
    ManagedDeploymentError,
    ManagedDeploymentRegistry,
)


class ManagedCompositionCommitError(RuntimeError):
    """Terminal evidence cannot safely advance the selected deployment."""


def _opaque_reference(value: str, label: str) -> str:
    if not isinstance(value, str) or not value.startswith("receipt:") or len(value) > 256:
        raise ValueError(f"{label} must be an opaque receipt reference")
    lowered = value.casefold()
    if any(fragment in lowered for fragment in ("token", "password", "authorization", "secret=")):
        raise ValueError(f"{label} appears to contain secret material")
    return value


@dataclass(frozen=True)
class ManagedCompositionTerminalEvidence:
    composition_id: str
    manifest_digest: str
    composition_catalog_sequence: int
    composition_catalog_digest: str
    component_catalog_sequence: int
    component_catalog_digest: str
    product_receipt_references: tuple[str, ...]
    readiness_receipt_references: tuple[str, ...]
    pairing_receipt_reference: str | None = None

    def __post_init__(self) -> None:
        # Reuse the durable binding validator for signed identity grammar.
        ManagedCompositionBinding(
            self.composition_id,
            self.manifest_digest,
            self.composition_catalog_sequence,
            self.composition_catalog_digest,
            self.component_catalog_sequence,
            self.component_catalog_digest,
            "receipt:validation-placeholder",
        )
        if not self.product_receipt_references:
            raise ValueError("terminal composition requires product receipt evidence")
        if not self.readiness_receipt_references:
            raise ValueError("terminal composition requires readiness evidence")
        for value in self.product_receipt_references:
            _opaque_reference(value, "product receipt")
        for value in self.readiness_receipt_references:
            _opaque_reference(value, "readiness receipt")
        if self.pairing_receipt_reference is not None:
            _opaque_reference(self.pairing_receipt_reference, "pairing receipt")

    @property
    def receipt_reference(self) -> str:
        payload = {
            "composition_id": self.composition_id,
            "manifest_digest": self.manifest_digest,
            "composition_catalog_sequence": self.composition_catalog_sequence,
            "composition_catalog_digest": self.composition_catalog_digest,
            "component_catalog_sequence": self.component_catalog_sequence,
            "component_catalog_digest": self.component_catalog_digest,
            "product_receipt_references": sorted(self.product_receipt_references),
            "readiness_receipt_references": sorted(self.readiness_receipt_references),
            "pairing_receipt_reference": self.pairing_receipt_reference,
        }
        digest = sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        return "receipt:composition-" + digest


class ManagedCompositionCommitCoordinator:
    def __init__(self, registry: ManagedDeploymentRegistry) -> None:
        self.registry = registry

    def commit(
        self,
        deployment_id: str,
        *,
        expected_revision: int,
        evidence: ManagedCompositionTerminalEvidence,
    ) -> ManagedDeployment:
        current = self.registry.load(deployment_id)
        if current is None:
            raise ManagedCompositionCommitError("managed deployment does not exist")
        if current.revision != expected_revision:
            raise ManagedCompositionCommitError("managed deployment revision changed before composition commit")

        by_component = current.by_component
        if len(evidence.product_receipt_references) < len(by_component):
            raise ManagedCompositionCommitError("terminal composition lacks product receipt coverage")
        if {"forge-runtime", "engineering-platform-server"} <= set(by_component):
            if current.peer_binding is None:
                raise ManagedCompositionCommitError("Forge and EP must be paired before composition commit")
            if evidence.pairing_receipt_reference != current.peer_binding.receipt_reference:
                raise ManagedCompositionCommitError("pairing evidence does not match the managed deployment")

        binding = ManagedCompositionBinding(
            evidence.composition_id,
            evidence.manifest_digest,
            evidence.composition_catalog_sequence,
            evidence.composition_catalog_digest,
            evidence.component_catalog_sequence,
            evidence.component_catalog_digest,
            evidence.receipt_reference,
        )
        if current.composition_binding == binding:
            return current

        updated = ManagedDeployment(
            current.deployment_id,
            current.revision + 1,
            current.label,
            current.components,
            current.peer_binding,
            binding,
        )
        try:
            return self.registry.replace(updated, expected_revision=current.revision)
        except ManagedDeploymentError as error:
            raise ManagedCompositionCommitError(
                "managed deployment changed during composition commit"
            ) from error
