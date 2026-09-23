"""End-to-end Forge+EP managed-install orchestration.

This coordinator composes the already qualified Forge Platform deployment saga,
product-owned adapters, Forge↔EP pairing boundary and final product readbacks.
It deliberately does not implement Forge or Engineering Platform lifecycle
internals.

Every actual mutation is preceded by an installer-currency guard.  Read-only
inventory, update assessment and readiness calls do not consume mutation
authority.  A retry reuses the durable component/deployment operation IDs; if a
previous mutation already completed, it is read back instead of being repeated.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from pathlib import Path
from typing import Mapping, Protocol
import re

from .component_operations import (
    ComponentOperationRequest,
    ProductInstallationReadback,
    ProductOperationAdapter,
)
from .managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V2,
    ManagedCompositionBinding,
    ManagedDeployment,
    ManagedDeploymentPlan,
    ManagedDeploymentRegistry,
)
from .managed_installer import (
    ManagedDeploymentExecutionRecord,
    ManagedDeploymentOperationCoordinator,
)
from .managed_pairing import (
    ManagedDeploymentPairingCoordinator,
    ManagedPairingEvidence,
)


FORGE_COMPONENT = "forge-runtime"
EP_COMPONENT = "engineering-platform-server"
_REQUIRED_COMPONENTS = frozenset({FORGE_COMPONENT, EP_COMPONENT})
_MUTATING_ACTIONS = frozenset({"ADD_COMPONENT", "UPDATE", "REPAIR", "REMOVE_COMPONENT"})
_REFERENCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._/-]{0,255}$")


class ManagedForgeEPInstallationError(RuntimeError):
    """The reviewed Forge+EP route cannot safely make further progress."""


class InstallerMutationCurrencyGuard(Protocol):
    """Fresh signed-installer currency boundary for one exact mutation.

    Implementations must return a non-secret evidence reference only after the
    running installer has been proven current.  A newer/unknown release must
    raise instead of returning authority.
    """

    def require_current(
        self,
        *,
        deployment_id: str,
        mutation: str,
        component: str | None,
        instance_id: str | None,
        operation_id: str,
    ) -> str: ...


class ForgeEPPairingExecutor(Protocol):
    """Product-bound pairing action.

    The implementation owns any Forge/EP command details and must be idempotent
    for the same operation_id and exact instance pair.
    """

    def pair(
        self,
        *,
        operation_id: str,
        deployment: ManagedDeployment,
        forge_request: ComponentOperationRequest,
        ep_request: ComponentOperationRequest,
        forge_adapter: ProductOperationAdapter,
        ep_adapter: ProductOperationAdapter,
    ) -> ManagedPairingEvidence: ...


@dataclass(frozen=True)
class ManagedForgeEPInstallationResult:
    operation_id: str
    deployment_id: str
    state: str
    registry_revision: int | None
    pairing_receipt_reference: str | None
    readiness_receipt_references: tuple[str, ...]
    currency_receipt_references: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.state not in {"RECOVERY_PENDING", "FAILED", "READINESS_FAILED", "COMPLETE"}:
            raise ValueError("managed Forge+EP result state is unsupported")
        for reference in (
            *self.readiness_receipt_references,
            *self.currency_receipt_references,
        ):
            _evidence_reference(reference)
        if self.pairing_receipt_reference is not None:
            _evidence_reference(self.pairing_receipt_reference)
        if self.state == "COMPLETE":
            if self.registry_revision is None or self.registry_revision <= 0:
                raise ValueError("complete Forge+EP result requires a registry revision")
            if self.pairing_receipt_reference is None:
                raise ValueError("complete Forge+EP result requires pairing evidence")
            if len(self.readiness_receipt_references) != 2:
                raise ValueError("complete Forge+EP result requires both readiness receipts")


def _evidence_reference(value: object) -> str:
    if not isinstance(value, str) or _REFERENCE.fullmatch(value) is None:
        raise ValueError("installer evidence reference is invalid")
    lowered = value.casefold()
    if any(fragment in lowered for fragment in (
        "authorization:", "bearer ", "password=", "secret=", "token=",
    )):
        raise ValueError("installer evidence reference appears to contain secret material")
    return value


class _CurrencyEvidence:
    def __init__(self, guard: InstallerMutationCurrencyGuard) -> None:
        self.guard = guard
        self.references: list[str] = []

    def require(
        self,
        *,
        deployment_id: str,
        mutation: str,
        component: str | None,
        instance_id: str | None,
        operation_id: str,
    ) -> None:
        reference = self.guard.require_current(
            deployment_id=deployment_id,
            mutation=mutation,
            component=component,
            instance_id=instance_id,
            operation_id=operation_id,
        )
        self.references.append(_evidence_reference(reference))


class _CurrencyGuardedAdapter:
    """Delegates all product semantics; only execute/resume consume authority."""

    def __init__(
        self,
        delegate: ProductOperationAdapter,
        evidence: _CurrencyEvidence,
        deployment_id: str,
    ) -> None:
        self.delegate = delegate
        self.evidence = evidence
        self.deployment_id = deployment_id

    def readback(self, request: ComponentOperationRequest):
        return self.delegate.readback(request)

    def assess_update(self, request: ComponentOperationRequest):
        return self.delegate.assess_update(request)

    def execute(self, request: ComponentOperationRequest):
        self.evidence.require(
            deployment_id=self.deployment_id,
            mutation=f"product-{request.kind}",
            component=request.component,
            instance_id=request.installation_identity,
            operation_id=request.operation_id,
        )
        return self.delegate.execute(request)

    def resume(self, request: ComponentOperationRequest, prior_receipt):
        self.evidence.require(
            deployment_id=self.deployment_id,
            mutation=f"product-{request.kind}-resume",
            component=request.component,
            instance_id=request.installation_identity,
            operation_id=request.operation_id,
        )
        return self.delegate.resume(request, prior_receipt)


class _CurrencyGuardedRegistry:
    """CAS registry facade that rechecks currency immediately before writes."""

    def __init__(
        self,
        delegate: ManagedDeploymentRegistry,
        evidence: _CurrencyEvidence,
        operation_id: str,
    ) -> None:
        self.delegate = delegate
        self.evidence = evidence
        self.operation_id = operation_id

    def inventory(self):
        return self.delegate.inventory()

    def load(self, deployment_id: str):
        return self.delegate.load(deployment_id)

    def create(self, deployment: ManagedDeployment):
        self._guard("deployment-create", deployment)
        return self.delegate.create(deployment)

    def replace(self, deployment: ManagedDeployment, *, expected_revision: int):
        self._guard("deployment-replace", deployment)
        return self.delegate.replace(deployment, expected_revision=expected_revision)

    def remove(self, deployment_id: str, *, expected_revision: int):
        current = self.delegate.load(deployment_id)
        if current is None:
            raise ManagedForgeEPInstallationError("deployment disappeared before registry removal")
        self._guard("deployment-remove", current)
        return self.delegate.remove(deployment_id, expected_revision=expected_revision)

    def _guard(self, mutation: str, deployment: ManagedDeployment) -> None:
        self.evidence.require(
            deployment_id=deployment.deployment_id,
            mutation=mutation,
            component=None,
            instance_id=None,
            operation_id=self.operation_id,
        )


class ManagedForgeEPInstallationCoordinator:
    """Runs one reviewed Forge+EP deployment through pairing and readiness.

    The component saga remains the sole dispatcher of product install/update/
    repair operations. Pairing remains a separate product-owned operation and
    registry commit. COMPLETE is returned only after both exact product
    instances independently read back ACTIVE/HEALTHY on their reviewed
    artifacts after pairing.
    """

    def __init__(
        self,
        *,
        operations_root: Path,
        component_operations_root: Path,
        registry: ManagedDeploymentRegistry,
        currency_guard: InstallerMutationCurrencyGuard,
    ) -> None:
        if not operations_root.is_absolute() or not component_operations_root.is_absolute():
            raise ValueError("managed Forge+EP operation roots must be absolute")
        self.operations_root = operations_root.resolve(strict=False)
        self.component_operations_root = component_operations_root.resolve(strict=False)
        self.registry = registry
        self.currency_guard = currency_guard

    def execute(
        self,
        operation_id: str,
        plan: ManagedDeploymentPlan,
        *,
        mutation_requests: Mapping[str, ComponentOperationRequest],
        readback_requests: Mapping[str, ComponentOperationRequest],
        adapters: Mapping[str, ProductOperationAdapter],
        pairing_executor: ForgeEPPairingExecutor,
        composition_id: str,
        composition_manifest_digest: str,
    ) -> ManagedForgeEPInstallationResult:
        desired = self._validate_route(
            plan,
            mutation_requests=mutation_requests,
            readback_requests=readback_requests,
            adapters=adapters,
        )
        # Construction validates the exact composition grammar/digest before
        # any product mutation can occur. The receipt itself is created only
        # after terminal pairing and readiness.
        ManagedCompositionBinding(
            composition_id,
            composition_manifest_digest,
            "receipt:composition-validation",
        )
        currency = _CurrencyEvidence(self.currency_guard)
        guarded_registry = _CurrencyGuardedRegistry(
            self.registry, currency, operation_id
        )
        guarded_adapters = {
            component: _CurrencyGuardedAdapter(adapter, currency, plan.deployment_id)
            for component, adapter in adapters.items()
        }
        mutating_components = {
            diff.component for diff in plan.component_diffs
            if diff.action in _MUTATING_ACTIONS
        }
        deployment_coordinator = ManagedDeploymentOperationCoordinator(
            operations_root=self.operations_root / "deployment-saga",
            component_operations_root=self.component_operations_root,
            registry=guarded_registry,  # structural facade; no extra product authority
        )
        deployment_result = deployment_coordinator.execute(
            operation_id,
            plan,
            requests={
                component: mutation_requests[component]
                for component in mutating_components
            },
            adapters={
                component: guarded_adapters[component]
                for component in mutating_components
            },
        )
        if deployment_result.state != "COMPLETE":
            return self._nonterminal_result(deployment_result, currency)

        current = self.registry.load(plan.deployment_id)
        if current is None:
            raise ManagedForgeEPInstallationError(
                "deployment registry commit was not observable after product operations"
            )
        self._require_exact_component_binding(current, desired)

        pairing_reference: str
        expected_forge = desired.by_component[FORGE_COMPONENT].instance_id
        expected_ep = desired.by_component[EP_COMPONENT].instance_id
        if current.peer_binding is not None:
            if (
                current.peer_binding.forge_instance_id != expected_forge
                or current.peer_binding.ep_instance_id != expected_ep
            ):
                raise ManagedForgeEPInstallationError(
                    "existing pairing binds different product instances"
                )
            pairing_reference = current.peer_binding.receipt_reference
        else:
            currency.require(
                deployment_id=plan.deployment_id,
                mutation="forge-ep-pairing",
                component=None,
                instance_id=None,
                operation_id=operation_id,
            )
            pairing_evidence = pairing_executor.pair(
                operation_id=operation_id,
                deployment=current,
                forge_request=readback_requests[FORGE_COMPONENT],
                ep_request=readback_requests[EP_COMPONENT],
                forge_adapter=adapters[FORGE_COMPONENT],
                ep_adapter=adapters[EP_COMPONENT],
            )
            if (
                pairing_evidence.forge_instance_id != expected_forge
                or pairing_evidence.ep_instance_id != expected_ep
            ):
                raise ManagedForgeEPInstallationError(
                    "product pairing evidence targets different instances"
                )
            paired = ManagedDeploymentPairingCoordinator(guarded_registry).commit(
                plan.deployment_id,
                expected_revision=current.revision,
                evidence=pairing_evidence,
            )
            pairing_reference = paired.peer_binding.receipt_reference  # type: ignore[union-attr]
            current = paired

        readiness = self._final_readiness(
            desired,
            readback_requests=readback_requests,
            adapters=adapters,
        )
        if readiness is None:
            return ManagedForgeEPInstallationResult(
                operation_id,
                plan.deployment_id,
                "READINESS_FAILED",
                current.revision,
                pairing_reference,
                (),
                tuple(currency.references),
            )

        current = self._commit_composition_provenance(
            operation_id,
            current=current,
            composition_id=composition_id,
            composition_manifest_digest=composition_manifest_digest,
            pairing_reference=pairing_reference,
            readiness=readiness,
            currency=currency,
        )
        return ManagedForgeEPInstallationResult(
            operation_id,
            plan.deployment_id,
            "COMPLETE",
            current.revision,
            pairing_reference,
            readiness,
            tuple(currency.references),
        )


    def _commit_composition_provenance(
        self,
        operation_id: str,
        *,
        current: ManagedDeployment,
        composition_id: str,
        composition_manifest_digest: str,
        pairing_reference: str,
        readiness: tuple[str, str],
        currency: _CurrencyEvidence,
    ) -> ManagedDeployment:
        existing = current.composition_binding
        if existing is not None:
            if (
                current.schema == MANAGED_DEPLOYMENT_SCHEMA_V2
                and existing.composition_id == composition_id
                and existing.manifest_digest == composition_manifest_digest
            ):
                return current
            raise ManagedForgeEPInstallationError(
                "managed deployment already carries different composition provenance"
            )
        if current.peer_binding is None or current.peer_binding.receipt_reference != pairing_reference:
            raise ManagedForgeEPInstallationError(
                "composition provenance requires the exact terminal pairing receipt"
            )
        payload = {
            "operation_id": operation_id,
            "deployment_id": current.deployment_id,
            "forge_instance_id": current.peer_binding.forge_instance_id,
            "ep_instance_id": current.peer_binding.ep_instance_id,
            "composition_id": composition_id,
            "manifest_digest": composition_manifest_digest,
            "pairing_receipt_reference": pairing_reference,
            "readiness_receipt_references": list(readiness),
        }
        receipt = "receipt:composition-" + sha256(
            json.dumps(
                payload, sort_keys=True, separators=(",", ":"), allow_nan=False
            ).encode("utf-8")
        ).hexdigest()
        binding = ManagedCompositionBinding(
            composition_id,
            composition_manifest_digest,
            receipt,
        )
        currency.require(
            deployment_id=current.deployment_id,
            mutation="composition-commit",
            component=None,
            instance_id=None,
            operation_id=operation_id,
        )
        updated = ManagedDeployment(
            current.deployment_id,
            current.revision + 1,
            current.label,
            current.components,
            current.peer_binding,
            MANAGED_DEPLOYMENT_SCHEMA_V2,
            binding,
        )
        try:
            return self.registry.replace(updated, expected_revision=current.revision)
        except Exception as error:
            raise ManagedForgeEPInstallationError(
                "managed deployment changed during composition provenance commit"
            ) from error

    @staticmethod
    def _validate_route(
        plan: ManagedDeploymentPlan,
        *,
        mutation_requests: Mapping[str, ComponentOperationRequest],
        readback_requests: Mapping[str, ComponentOperationRequest],
        adapters: Mapping[str, ProductOperationAdapter],
    ) -> ManagedDeployment:
        if not isinstance(plan, ManagedDeploymentPlan):
            raise ValueError("managed Forge+EP route requires a reviewed deployment plan")
        if plan.deployment_action != "CREATE_OR_UPDATE" or plan.desired is None:
            raise ManagedForgeEPInstallationError(
                "Forge+EP install route does not authorize deployment removal"
            )
        desired = plan.desired
        if set(desired.by_component) != _REQUIRED_COMPONENTS:
            raise ManagedForgeEPInstallationError(
                "Forge+EP install route requires exactly Forge Server and Engineering Platform Server"
            )
        if plan.current_revision is None and desired.peer_binding is not None:
            raise ManagedForgeEPInstallationError(
                "a fresh deployment cannot pre-authorize terminal pairing evidence"
            )

        mutating = {
            diff.component for diff in plan.component_diffs
            if diff.action in _MUTATING_ACTIONS
        }
        if set(mutation_requests) != mutating:
            raise ManagedForgeEPInstallationError(
                "mutation requests do not match the reviewed product diff"
            )
        if set(readback_requests) != _REQUIRED_COMPONENTS or set(adapters) != _REQUIRED_COMPONENTS:
            raise ManagedForgeEPInstallationError(
                "final readiness requires exact Forge and EP request/adapter bindings"
            )
        for component, binding in desired.by_component.items():
            request = readback_requests[component]
            if (
                request.component != component
                or request.installation_identity != binding.instance_id
            ):
                raise ManagedForgeEPInstallationError(
                    "readiness request changed an exact reviewed product target"
                )
        return desired

    @staticmethod
    def _require_exact_component_binding(
        current: ManagedDeployment,
        desired: ManagedDeployment,
    ) -> None:
        if set(current.by_component) != _REQUIRED_COMPONENTS:
            raise ManagedForgeEPInstallationError(
                "registry does not contain the exact Forge+EP component set"
            )
        for component, desired_binding in desired.by_component.items():
            actual = current.by_component[component]
            if actual.instance_id != desired_binding.instance_id:
                raise ManagedForgeEPInstallationError(
                    "registry component identity changed after product operations"
                )

    @staticmethod
    def _final_readiness(
        desired: ManagedDeployment,
        *,
        readback_requests: Mapping[str, ComponentOperationRequest],
        adapters: Mapping[str, ProductOperationAdapter],
    ) -> tuple[str, str] | None:
        references: list[str] = []
        for component in (FORGE_COMPONENT, EP_COMPONENT):
            request = readback_requests[component]
            observation = adapters[component].readback(request)
            if not isinstance(observation, ProductInstallationReadback):
                raise ManagedForgeEPInstallationError(
                    "product readiness did not return a typed installation readback"
                )
            binding = desired.by_component[component]
            if (
                observation.component != component
                or observation.installation_identity != binding.instance_id
                or observation.selected_instance_identity != binding.instance_id
                or observation.state != "ACTIVE"
                or observation.health_state != "HEALTHY"
                or observation.artifact != request.artifact.correlation
                or observation.health_evidence_reference is None
            ):
                return None
            references.append(_evidence_reference(observation.health_evidence_reference))
        return references[0], references[1]

    @staticmethod
    def _nonterminal_result(
        deployment_result: ManagedDeploymentExecutionRecord,
        currency: _CurrencyEvidence,
    ) -> ManagedForgeEPInstallationResult:
        state = (
            "RECOVERY_PENDING"
            if deployment_result.state == "RECOVERY_PENDING"
            else "FAILED"
        )
        return ManagedForgeEPInstallationResult(
            deployment_result.operation_id,
            deployment_result.deployment_id,
            state,
            deployment_result.registry_revision,
            None,
            (),
            tuple(currency.references),
        )
