"""Evidence-bound delegation for product-owned component operations.

Forge Platform selects a qualified component artifact and coordinates a public
product operation.  It is deliberately not a second product installer: the
delegated provisioner owns runtime resolution, service changes, data,
migrations, backup, rollback, cleanup, and the product installation lock.
This module only validates correlation and retains non-secret product-owned
readback for a composition receipt.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from math import isfinite
from typing import Mapping, Protocol


COMPONENT_IDENTITIES = frozenset({
    "forge-runtime", "workspace-server", "workspace-client",
    "engineering-platform-server", "engineering-platform-project-agent",
})
OPERATION_KINDS = frozenset({"install", "update", "repair", "rollback", "remove"})
PRODUCT_OPERATION_STATES = frozenset({
    "COMPLETED", "CLEANUP_PENDING", "RECOVERY_PENDING", "FAILED",
})
RESUMABLE_PRODUCT_STATES = frozenset({"CLEANUP_PENDING", "RECOVERY_PENDING"})
INSTALLATION_READBACK_STATES = frozenset({"ABSENT", "ACTIVE", "UNHEALTHY", "UNKNOWN"})
HEALTH_STATES = frozenset({"HEALTHY", "UNHEALTHY", "UNKNOWN"})
UPDATE_AVAILABILITY = frozenset({"UPDATE_AVAILABLE", "UP_TO_DATE", "INCOMPATIBLE", "UNKNOWN"})
INVENTORY_COVERAGE_STATES = frozenset({"MACHINE_WIDE", "PARTIAL", "UNKNOWN"})
CONFLICT_STATES = frozenset({"NONE", "CONFLICTING", "UNKNOWN"})

# Product runtime concerns cannot be selected through the coordinator's public
# extension mapping.  The mapping deliberately remains product-extensible for
# harmless public choices such as a channel or feature profile; every runtime
# or installation target belongs in the product-owned resolver behind the
# opaque top-level installation identity.
FORBIDDEN_DELEGATION_KEY_FRAGMENTS = frozenset({
    "agent", "artifact", "backup", "binary", "central", "command",
    "credential", "database", "directory", "endpoint", "environment",
    "executable", "filesystem", "host", "installation", "interpreter",
    "launch", "location", "machine", "migration", "password", "path",
    "pid", "port", "process", "python", "runtime", "secret", "service",
    "source_revision", "token", "venv", "version",
})


def _require(value: str, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is required")
    return value


def _normalized_key(key: str) -> str:
    return key.casefold().replace("-", "_")


def _validate_delegation(value: object) -> None:
    if isinstance(value, Mapping):
        for key, nested in value.items():
            if not isinstance(key, str):
                raise ValueError("delegation keys must be strings")
            normalized_key = _normalized_key(key)
            if any(fragment in normalized_key for fragment in FORBIDDEN_DELEGATION_KEY_FRAGMENTS):
                raise ValueError(f"delegation cannot contain product-runtime key: {normalized_key}")
            _validate_delegation(nested)
    elif isinstance(value, (list, tuple)):
        for nested in value:
            _validate_delegation(nested)
    elif isinstance(value, float):
        if not isfinite(value):
            raise ValueError("delegation values must be finite JSON values")
    elif value is not None and not isinstance(value, (str, int, bool)):
        raise ValueError("delegation values must be JSON-compatible")


def _canonical_delegation(value: Mapping[str, object]) -> str:
    """Make every public product selection part of the retry identity."""
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    except (TypeError, ValueError) as error:  # defensive for exotic Mapping implementations
        raise ValueError("product_request must be JSON-compatible") from error


@dataclass(frozen=True)
class ArtifactCorrelation:
    """Exact product-issued correlation to an artifact's bytes and source revision.

    A product resolver can prove which released bytes it selected without
    becoming the authority for the Forge Platform-owned download locator or
    qualification evidence.  Those two values deliberately do not appear in
    this product-facing type.
    """

    version: str
    source_revision: str
    digest: str

    def __post_init__(self) -> None:
        for label in ("version", "source_revision"):
            _require(getattr(self, label), label)
        if not isinstance(self.digest, str) or not self.digest.startswith("sha256:"):
            raise ValueError("artifact digest must be a sha256 identity")
        digest_hex = self.digest.removeprefix("sha256:")
        if len(digest_hex) != 64 or any(character not in "0123456789abcdef" for character in digest_hex):
            raise ValueError("artifact sha256 digest must contain 64 lowercase hexadecimal bytes")


@dataclass(frozen=True)
class QualifiedArtifact:
    """Forge Platform's complete, independently qualified artifact evidence."""

    version: str
    source_revision: str
    source: str
    digest: str
    qualification: str

    def __post_init__(self) -> None:
        ArtifactCorrelation(self.version, self.source_revision, self.digest)
        for label in ("source", "qualification"):
            _require(getattr(self, label), label)

    @property
    def correlation(self) -> ArtifactCorrelation:
        """The exact product-visible subset of this Forge Platform evidence."""
        return ArtifactCorrelation(self.version, self.source_revision, self.digest)


@dataclass(frozen=True)
class ComponentOperationRequest:
    """A coordinator request that can safely be passed to a product provisioner.

    ``installation_identity`` is an opaque product-owned selector.  It lets a
    product resolver locate its intended installation without permitting a
    runtime path, interpreter, service label, database, or migration input.
    """

    operation_id: str
    component: str
    kind: str
    artifact: QualifiedArtifact
    installation_identity: str
    requested_role: str
    product_request: Mapping[str, object]

    def __post_init__(self) -> None:
        _require(self.operation_id, "operation_id")
        if self.component not in COMPONENT_IDENTITIES:
            raise ValueError(f"unknown component identity: {self.component}")
        if self.kind not in OPERATION_KINDS:
            raise ValueError(f"unsupported operation kind: {self.kind}")
        if not isinstance(self.artifact, QualifiedArtifact):
            raise ValueError("artifact must be a qualified artifact")
        _require(self.installation_identity, "installation_identity")
        _require(self.requested_role, "requested_role")
        if not isinstance(self.product_request, Mapping):
            raise ValueError("product_request must be a mapping")
        _validate_delegation(self.product_request)

    def fingerprint(self) -> str:
        """Stable retry identity, including every artifact locator and selection."""
        material = "\x1f".join((
            self.operation_id, self.component, self.kind, self.installation_identity, self.requested_role,
            self.artifact.version, self.artifact.source_revision, self.artifact.source,
            self.artifact.digest, self.artifact.qualification,
            _canonical_delegation(self.product_request),
        ))
        return sha256(material.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class ProductInstallationReadback:
    """Non-secret observation from a product-owned installation resolver.

    Runtime, executable, server, and instance values are opaque identities
    issued by the product.  They are observations, never Forge Platform input
    or a PATH/filesystem lookup. ``artifact`` is only an
    :class:`ArtifactCorrelation`; its locator and qualification stay in Forge
    Platform's request/record evidence. ``inventory_coverage`` and
    ``conflict_state`` make an asserted single operational installation
    explicitly dependent on machine-wide product evidence.
    """

    component: str
    installation_identity: str
    state: str
    selected_runtime_identity: str | None
    selected_executable_identity: str | None
    selected_server_identity: str | None
    selected_instance_identity: str | None
    artifact: ArtifactCorrelation | None
    health_state: str
    inventory_coverage: str
    conflict_state: str
    evidence_reference: str
    health_evidence_reference: str | None = None
    conflict_evidence_reference: str | None = None

    def __post_init__(self) -> None:
        if self.component not in COMPONENT_IDENTITIES:
            raise ValueError(f"unknown component identity: {self.component}")
        _require(self.installation_identity, "installation_identity")
        if self.state not in INSTALLATION_READBACK_STATES:
            raise ValueError(f"unsupported installation readback state: {self.state}")
        if self.health_state not in HEALTH_STATES:
            raise ValueError(f"unsupported installation health state: {self.health_state}")
        if self.inventory_coverage not in INVENTORY_COVERAGE_STATES:
            raise ValueError(f"unsupported inventory coverage: {self.inventory_coverage}")
        if self.conflict_state not in CONFLICT_STATES:
            raise ValueError(f"unsupported installation conflict state: {self.conflict_state}")
        _require(self.evidence_reference, "evidence_reference")
        for label, identity in (
            ("selected_runtime_identity", self.selected_runtime_identity),
            ("selected_executable_identity", self.selected_executable_identity),
            ("selected_server_identity", self.selected_server_identity),
            ("selected_instance_identity", self.selected_instance_identity),
            ("health_evidence_reference", self.health_evidence_reference),
            ("conflict_evidence_reference", self.conflict_evidence_reference),
        ):
            if identity is not None:
                _require(identity, label)
        if self.conflict_state == "CONFLICTING":
            _require(self.conflict_evidence_reference or "", "conflict_evidence_reference")
        if self.state == "ABSENT":
            if any(identity is not None for identity in self._selected_identities()) or self.artifact is not None:
                raise ValueError("absent installation readback cannot identify a runtime or artifact")
            if self.health_state != "UNKNOWN" or self.health_evidence_reference is not None:
                raise ValueError("absent installation readback must have unknown health without health evidence")
        elif self.state in {"ACTIVE", "UNHEALTHY"}:
            _require(self.selected_runtime_identity or "", "selected_runtime_identity")
            _require(self.selected_executable_identity or "", "selected_executable_identity")
            _require(self.selected_instance_identity or "", "selected_instance_identity")
            if not isinstance(self.artifact, ArtifactCorrelation):
                raise ValueError("selected installation readback requires an artifact correlation")
            _require(self.health_evidence_reference or "", "health_evidence_reference")
            expected_health = "HEALTHY" if self.state == "ACTIVE" else "UNHEALTHY"
            if self.health_state != expected_health:
                raise ValueError("installation readback state and health state disagree")
        else:
            if any(identity is not None for identity in self._selected_identities()) or self.artifact is not None:
                raise ValueError("unknown installation readback cannot identify a selected runtime or artifact")
            if self.health_state != "UNKNOWN" or self.health_evidence_reference is not None:
                raise ValueError("unknown installation readback must have unknown health without health evidence")

    def _selected_identities(self) -> tuple[str | None, ...]:
        return (
            self.selected_runtime_identity,
            self.selected_executable_identity,
            self.selected_server_identity,
            self.selected_instance_identity,
        )

    @property
    def single_operational_installation_verified(self) -> bool:
        """Whether the product supplied sufficient machine-wide uniqueness evidence."""
        return (
            self.state == "ACTIVE"
            and self.health_state == "HEALTHY"
            and self.inventory_coverage == "MACHINE_WIDE"
            and self.conflict_state == "NONE"
        )


@dataclass(frozen=True)
class ProductUpdateAssessment:
    """The product-owned compatibility decision for one exact correlation."""

    component: str
    installation_identity: str
    candidate_artifact: ArtifactCorrelation
    state: str
    evidence_reference: str

    def __post_init__(self) -> None:
        if self.component not in COMPONENT_IDENTITIES:
            raise ValueError(f"unknown component identity: {self.component}")
        _require(self.installation_identity, "installation_identity")
        if not isinstance(self.candidate_artifact, ArtifactCorrelation):
            raise ValueError("candidate_artifact must be an artifact correlation")
        if self.state not in UPDATE_AVAILABILITY:
            raise ValueError(f"unsupported update availability: {self.state}")
        _require(self.evidence_reference, "evidence_reference")


@dataclass(frozen=True)
class ProductOperationReceipt:
    """Product-owned operation state correlated without FP provenance fields."""

    product_operation_id: str
    component: str
    installation_identity: str
    artifact: ArtifactCorrelation
    state: str
    evidence_reference: str
    cleanup_evidence_reference: str | None = None

    def __post_init__(self) -> None:
        _require(self.product_operation_id, "product_operation_id")
        if self.component not in COMPONENT_IDENTITIES:
            raise ValueError(f"unknown component identity: {self.component}")
        _require(self.installation_identity, "installation_identity")
        if not isinstance(self.artifact, ArtifactCorrelation):
            raise ValueError("receipt artifact must be an artifact correlation")
        if self.state not in PRODUCT_OPERATION_STATES:
            raise ValueError(f"unsupported product operation state: {self.state}")
        _require(self.evidence_reference, "evidence_reference")
        if self.cleanup_evidence_reference is not None:
            _require(self.cleanup_evidence_reference, "cleanup_evidence_reference")
        if self.state == "CLEANUP_PENDING":
            _require(self.cleanup_evidence_reference or "", "cleanup_evidence_reference")


class ProductOperationAdapter(Protocol):
    """Public product boundary; concrete adapters stay with product owners."""

    def readback(self, request: ComponentOperationRequest) -> ProductInstallationReadback:
        """Resolve and observe the selected product installation."""

    def assess_update(self, request: ComponentOperationRequest) -> ProductUpdateAssessment:
        """Assess the exact candidate; only the product may determine compatibility."""

    def execute(self, request: ComponentOperationRequest) -> ProductOperationReceipt:
        """Perform the product-owned operation for the exact requested artifact."""

    def resume(
        self,
        request: ComponentOperationRequest,
        prior_receipt: ProductOperationReceipt,
    ) -> ProductOperationReceipt:
        """Resume the same product operation after a recoverable product state."""


@dataclass(frozen=True)
class ComponentOperationRecord:
    """Forge Platform's coordination view, including its qualified artifact evidence."""

    operation_id: str
    request_fingerprint: str
    artifact: QualifiedArtifact
    update_assessment: ProductUpdateAssessment | None
    preflight: ProductInstallationReadback
    product_receipt: ProductOperationReceipt
    postflight: ProductInstallationReadback
    prior_product_receipts: tuple[ProductOperationReceipt, ...] = ()

    def __post_init__(self) -> None:
        _require(self.operation_id, "operation_id")
        _require(self.request_fingerprint, "request_fingerprint")
        if not isinstance(self.artifact, QualifiedArtifact):
            raise ValueError("artifact must be Forge Platform qualified artifact evidence")
        if not isinstance(self.preflight, ProductInstallationReadback):
            raise ValueError("preflight must be a product installation readback")
        if self.update_assessment is not None and not isinstance(self.update_assessment, ProductUpdateAssessment):
            raise ValueError("update_assessment must be a product update assessment")
        if not isinstance(self.product_receipt, ProductOperationReceipt):
            raise ValueError("product_receipt must be a product operation receipt")
        if not isinstance(self.postflight, ProductInstallationReadback):
            raise ValueError("postflight must be a product installation readback")
        for observation in (self.preflight, self.postflight):
            if (
                observation.component != self.product_receipt.component
                or observation.installation_identity != self.product_receipt.installation_identity
            ):
                raise ValueError("readbacks must describe the receipt component and installation")
        if self.update_assessment is not None and (
            self.update_assessment.component != self.product_receipt.component
            or self.update_assessment.installation_identity != self.product_receipt.installation_identity
            or self.update_assessment.candidate_artifact != self.artifact.correlation
        ):
            raise ValueError("update assessment must describe the receipt target and artifact")
        if self.product_receipt.artifact != self.artifact.correlation:
            raise ValueError("product receipt must correlate to Forge Platform artifact evidence")
        if not isinstance(self.prior_product_receipts, tuple):
            raise ValueError("prior_product_receipts must be a tuple")
        for prior in self.prior_product_receipts:
            if not isinstance(prior, ProductOperationReceipt):
                raise ValueError("prior_product_receipts must contain product operation receipts")
            if (
                prior.product_operation_id != self.product_receipt.product_operation_id
                or prior.component != self.product_receipt.component
                or prior.installation_identity != self.product_receipt.installation_identity
                or prior.artifact != self.artifact.correlation
            ):
                raise ValueError("prior product receipts must describe the same product operation")


class ComponentOperationCoordinator:
    """Idempotently delegates evidence-bound product operations in-process.

    The durable coordinator adds process locks and durable records.  Neither
    coordinator replaces the product-owned installation lock, which remains
    authoritative across product clients and reboot recovery.
    """

    def __init__(self) -> None:
        self._records: dict[str, ComponentOperationRecord] = {}

    @staticmethod
    def _readback(request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ProductInstallationReadback:
        observation = adapter.readback(request)
        if not isinstance(observation, ProductInstallationReadback):
            raise TypeError("product adapter must return ProductInstallationReadback")
        if observation.component != request.component:
            raise RuntimeError("product readback does not describe the requested component")
        if observation.installation_identity != request.installation_identity:
            raise RuntimeError("product readback does not describe the requested installation identity")
        return observation

    @staticmethod
    def _update_assessment(
        request: ComponentOperationRequest,
        adapter: ProductOperationAdapter,
    ) -> ProductUpdateAssessment:
        assessment = adapter.assess_update(request)
        if not isinstance(assessment, ProductUpdateAssessment):
            raise TypeError("product adapter must return ProductUpdateAssessment")
        if assessment.component != request.component:
            raise RuntimeError("product update assessment does not describe the requested component")
        if assessment.installation_identity != request.installation_identity:
            raise RuntimeError("product update assessment does not describe the requested installation identity")
        if assessment.candidate_artifact != request.artifact.correlation:
            raise RuntimeError("product update assessment does not correlate to the requested artifact")
        return assessment

    @staticmethod
    def _verify_receipt(request: ComponentOperationRequest, receipt: ProductOperationReceipt) -> None:
        if not isinstance(receipt, ProductOperationReceipt):
            raise TypeError("product adapter must return ProductOperationReceipt")
        if receipt.component != request.component:
            raise RuntimeError("product receipt does not describe the requested component")
        if receipt.installation_identity != request.installation_identity:
            raise RuntimeError("product receipt does not describe the requested installation identity")
        if receipt.artifact != request.artifact.correlation:
            raise RuntimeError("product receipt does not correlate to the requested artifact")

    @staticmethod
    def _verify_completed(request: ComponentOperationRequest, observation: ProductInstallationReadback) -> None:
        if request.kind == "remove":
            if observation.state != "ABSENT":
                raise RuntimeError("completed product removal did not report the exact installation absent")
            return
        if observation.state != "ACTIVE" or observation.health_state != "HEALTHY":
            raise RuntimeError("completed product operation did not report a healthy selected runtime")
        if observation.artifact != request.artifact.correlation:
            raise RuntimeError("completed product operation did not select the requested artifact correlation")

    def observe(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ProductInstallationReadback:
        """Ask the product resolver which runtime it selected.

        The returned data is product evidence; this method never derives a
        runtime from PATH, file locations, services, or a local package scan.
        """
        return self._readback(request, adapter)

    def assess_update(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ProductUpdateAssessment:
        """Ask the product whether the exact candidate is safe and available."""
        if request.kind != "update":
            raise ValueError("update assessment is only valid for an update operation")
        return self._update_assessment(request, adapter)

    def _delegate_once(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ComponentOperationRecord:
        preflight = self.observe(request, adapter)
        assessment = self.assess_update(request, adapter) if request.kind == "update" else None
        if assessment is not None and assessment.state != "UPDATE_AVAILABLE":
            raise RuntimeError(f"product did not authorize update dispatch: {assessment.state}")
        receipt = adapter.execute(request)
        self._verify_receipt(request, receipt)
        postflight = self.observe(request, adapter)
        if receipt.state == "COMPLETED":
            self._verify_completed(request, postflight)
        return ComponentOperationRecord(
            request.operation_id,
            request.fingerprint(),
            request.artifact,
            assessment,
            preflight,
            receipt,
            postflight,
        )

    def _resume_once(
        self,
        request: ComponentOperationRequest,
        existing: ComponentOperationRecord,
        adapter: ProductOperationAdapter,
    ) -> ComponentOperationRecord:
        preflight = self.observe(request, adapter)
        receipt = adapter.resume(request, existing.product_receipt)
        self._verify_receipt(request, receipt)
        if receipt.product_operation_id != existing.product_receipt.product_operation_id:
            raise RuntimeError("product resume returned a different product operation identity")
        postflight = self.observe(request, adapter)
        if receipt.state == "COMPLETED":
            self._verify_completed(request, postflight)
        return ComponentOperationRecord(
            request.operation_id,
            request.fingerprint(),
            request.artifact,
            existing.update_assessment,
            preflight,
            receipt,
            postflight,
            existing.prior_product_receipts + (existing.product_receipt,),
        )

    @staticmethod
    def _same_target(record: ComponentOperationRecord, request: ComponentOperationRequest) -> bool:
        return (
            record.product_receipt.component == request.component
            and record.product_receipt.installation_identity == request.installation_identity
        )

    def _pending_target_operation(self, request: ComponentOperationRequest) -> ComponentOperationRecord | None:
        for record in self._records.values():
            if (
                record.operation_id != request.operation_id
                and record.product_receipt.state in RESUMABLE_PRODUCT_STATES
                and self._same_target(record, request)
            ):
                return record
        return None

    def delegate(self, request: ComponentOperationRequest, adapter: ProductOperationAdapter) -> ComponentOperationRecord:
        fingerprint = request.fingerprint()
        existing = self._records.get(request.operation_id)
        if existing:
            if existing.request_fingerprint != fingerprint:
                raise RuntimeError("operation ID already binds a different component artifact or action")
            if existing.artifact != request.artifact:
                raise RuntimeError("operation record artifact does not match the requested qualified artifact")
            if existing.product_receipt.state in RESUMABLE_PRODUCT_STATES:
                record = self._resume_once(request, existing, adapter)
                self._records[request.operation_id] = record
                return record
            return existing
        pending = self._pending_target_operation(request)
        if pending:
            raise RuntimeError(
                f"product target has resumable operation {pending.operation_id}; resume it before another dispatch"
            )
        record = self._delegate_once(request, adapter)
        self._records[request.operation_id] = record
        return record
