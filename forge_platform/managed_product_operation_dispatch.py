"""Helper-owned route binding and dispatch for an admitted Forge+EP request.

Only an injected helper resolver may select concrete product adapters and new
product instance identities.  Native request bytes never carry those adapters,
paths, commands, environment values, or credentials.  The resulting route is
rebound to the admitted request and exact manifest before the existing durable
Forge+EP saga can mutate anything.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from types import MappingProxyType
from typing import Mapping, Protocol

from .component_operations import ComponentOperationRequest, ProductOperationAdapter
from .ep_consumer_revocation import EPConsumerRevocationAdapter
from .managed_deployments import (
    MANAGED_DEPLOYMENT_SCHEMA_V1,
    ManagedComponentBinding,
    ManagedDeployment,
    ManagedDeploymentPlanner,
)
from .managed_install_flow import (
    EP_COMPONENT,
    FORGE_COMPONENT,
    ForgeEPPairingExecutor,
    ManagedForgeEPInstallationCoordinator,
    ManagedSingleProductInstallationCoordinator,
)
from .managed_product_operation_admission import (
    AdmittedNativeProductOperation,
    NativeProductComponentOperation,
)


NATIVE_PRODUCT_OPERATION_RECEIPT_SCHEMA = (
    "forge-platform.native-product-operation-receipt/v1"
)
_COMPONENTS = (EP_COMPONENT, FORGE_COMPONENT)
_PRODUCT_ACTIONS = {
    "install": "ADD_COMPONENT",
    "update": "UPDATE",
    "repair": "REPAIR",
    "retain": "NO_CHANGE",
}
_PRODUCT_KINDS = {
    "install": "install",
    "update": "update",
    "repair": "repair",
    # Readback accepts the same immutable request type. A retained component is
    # never dispatched, so repair here is correlation-only and cannot mutate.
    "retain": "repair",
}


class ManagedProductOperationDispatchError(RuntimeError):
    """Helper route resolution or durable product execution failed closed."""


@dataclass(frozen=True)
class ResolvedManagedProductRoute:
    forge_instance_id: str | None
    engineering_platform_instance_id: str | None
    adapters: Mapping[str, ProductOperationAdapter]
    pairing_executor: ForgeEPPairingExecutor | None
    ep_consumer_revoker: EPConsumerRevocationAdapter | None = None

    def __post_init__(self) -> None:
        adapters = MappingProxyType(dict(self.adapters))
        object.__setattr__(self, "adapters", adapters)
        # ManagedComponentBinding owns the common safe opaque-ID grammar.
        identities = {
            component: instance for component, instance in (
                (FORGE_COMPONENT, self.forge_instance_id),
                (EP_COMPONENT, self.engineering_platform_instance_id),
            ) if instance is not None
        }
        if not identities or set(adapters) != set(identities):
            raise ValueError("resolved product route has inconsistent component targets")
        for component, instance in identities.items():
            ManagedComponentBinding(component, instance, "receipt:route")
        if len(set(identities.values())) != len(identities):
            raise ValueError("Forge and EP routes require distinct product instance identities")
        if any(not _is_adapter(adapters[component]) for component in identities):
            raise ValueError("resolved product route contains an invalid adapter")
        if len(identities) == 2:
            if not _is_pairer(self.pairing_executor):
                raise ValueError("paired product route requires a pairing executor")
        elif self.pairing_executor is not None:
            raise ValueError("single-component route cannot carry pairing authority")
        if self.ep_consumer_revoker is not None:
            if len(identities) != 2:
                raise ValueError("single-component route cannot carry EP consumer revocation")
            revoker = self.ep_consumer_revoker
            binding = getattr(self.pairing_executor, "binding", None)
            if (
                not isinstance(revoker, EPConsumerRevocationAdapter)
                or revoker.provisioner is not adapters[EP_COMPONENT]
                or revoker.provisioner.target.instance_id != self.engineering_platform_instance_id
                or binding is None
                or revoker.scope.consumer_id != binding.consumer_id
                or revoker.scope.project_id != binding.project_id
                or revoker.expected_artifact.digest not in revoker.provisioner.staged_artifacts
            ):
                raise ValueError("resolved EP consumer revocation authority is inconsistent")


class ManagedProductRouteResolver(Protocol):
    """Sealed helper authority for product targets, adapters, and pairing."""

    def resolve(
        self, admitted: AdmittedNativeProductOperation
    ) -> ResolvedManagedProductRoute: ...


class PinnedManagedProductRouteResolver:
    """Immutable helper-owned routes keyed by an admitted deployment ID.

    Route construction remains outside the native request boundary. The helper
    supplies fully typed adapters and its pairing executor once, this resolver
    snapshots them, and a request can only select the exact predeclared route
    matching its already admitted deployment identity.
    """

    def __init__(self, routes: Mapping[str, ResolvedManagedProductRoute]) -> None:
        if not isinstance(routes, Mapping) or not routes:
            raise TypeError("helper-owned product routes are required")
        snapshot = dict(routes)
        claimed_instances: set[tuple[str, str]] = set()
        for deployment_id, route in snapshot.items():
            # Deployment and instance identifiers use the same closed safe-ID
            # grammar. This validates the key without exposing registry paths.
            ManagedComponentBinding(FORGE_COMPONENT, deployment_id, "receipt:route")
            if not isinstance(route, ResolvedManagedProductRoute):
                raise TypeError("helper-owned product route is invalid")
            claims = {
                (component, instance)
                for component, instance in (
                    (FORGE_COMPONENT, route.forge_instance_id),
                    (EP_COMPONENT, route.engineering_platform_instance_id),
                ) if instance is not None
            }
            if claimed_instances.intersection(claims):
                raise ValueError("helper-owned product routes reuse a product instance")
            claimed_instances.update(claims)
        self._routes = MappingProxyType(snapshot)

    def resolve(
        self, admitted: AdmittedNativeProductOperation
    ) -> ResolvedManagedProductRoute:
        if not isinstance(admitted, AdmittedNativeProductOperation):
            raise TypeError("admitted native product operation is required")
        route = self._routes.get(admitted.request.deployment_id)
        if route is None:
            raise ManagedProductOperationDispatchError(
                "helper-owned product route is unavailable"
            )
        if (
            {component.identity for component in admitted.manifest.components}
                != set(route.adapters)
            or {component.identity for component in admitted.request.components}
                != set(route.adapters)
        ):
            raise ManagedProductOperationDispatchError(
                "helper-owned product route conflicts with reviewed component topology"
            )
        current = admitted.current_deployment
        if current is not None:
            by_component = current.by_component
            expected = {
                component: instance for component, instance in (
                    (FORGE_COMPONENT, route.forge_instance_id),
                    (EP_COMPONENT, route.engineering_platform_instance_id),
                ) if instance is not None
            }
            if set(by_component) != set(expected) or any(
                by_component[component].instance_id != instance
                for component, instance in expected.items()
            ):
                raise ManagedProductOperationDispatchError(
                    "helper-owned product route conflicts with existing topology"
                )
        return route


@dataclass(frozen=True)
class NativeProductOperationDispatchReceipt:
    request_fingerprint: str
    stable_plan_fingerprint: str
    operation_id: str
    product_receipt_references: tuple[str, ...]
    pairing_receipt_reference: str | None
    readiness_receipt_references: tuple[str, ...]
    completed_components: tuple[str, ...] = _COMPONENTS

    def canonical_json_bytes(self) -> bytes:
        completions = [
            {
                "component_identity": component,
                "state": "READY",
                "dashboard_url": None,
                "service_scope": None,
            }
            for component in self.completed_components
        ]
        return json.dumps(
            {
                "schema": NATIVE_PRODUCT_OPERATION_RECEIPT_SCHEMA,
                "request_fingerprint": self.request_fingerprint,
                "stable_plan_fingerprint": self.stable_plan_fingerprint,
                "operation_id": self.operation_id,
                "product_receipt_references": list(self.product_receipt_references),
                "pairing_receipt_reference": self.pairing_receipt_reference,
                "readiness_receipt_references": list(self.readiness_receipt_references),
                "completions": completions,
            },
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")


class ManagedProductOperationDispatcher:
    """Resolve one admitted request and execute the existing durable saga."""

    def __init__(
        self,
        *,
        coordinator: ManagedForgeEPInstallationCoordinator,
        resolver: ManagedProductRouteResolver,
    ) -> None:
        if not isinstance(coordinator, ManagedForgeEPInstallationCoordinator):
            raise TypeError("managed Forge+EP coordinator is required")
        if not callable(getattr(resolver, "resolve", None)):
            raise TypeError("helper-owned product route resolver is required")
        self.coordinator = coordinator
        self.single_coordinator = ManagedSingleProductInstallationCoordinator(
            operations_root=coordinator.operations_root,
            component_operations_root=coordinator.component_operations_root,
            registry=coordinator.registry,
            currency_guard=coordinator.currency_guard,
        )
        self.resolver = resolver

    def dispatch(
        self, admitted: AdmittedNativeProductOperation
    ) -> NativeProductOperationDispatchReceipt:
        if not isinstance(admitted, AdmittedNativeProductOperation):
            raise TypeError("admitted native product operation is required")
        route = self.resolver.resolve(admitted)
        if not isinstance(route, ResolvedManagedProductRoute):
            raise ManagedProductOperationDispatchError("product resolver returned an invalid route")
        request = admitted.request
        current = admitted.current_deployment
        observed = self.coordinator.registry.load(request.deployment_id)
        if observed != current:
            raise ManagedProductOperationDispatchError(
                "managed deployment changed after helper admission"
            )
        if current is not None and (
            route.forge_instance_id != request.forge_instance_id
            or route.engineering_platform_instance_id
            != request.engineering_platform_instance_id
        ):
            raise ManagedProductOperationDispatchError(
                "resolved product targets changed existing topology"
            )

        operations = {component.identity: component for component in request.components}
        components = tuple(sorted(route.adapters))
        manifest_components = {
            component.identity: component for component in admitted.manifest.components
        }
        desired = ManagedDeployment(
            request.deployment_id,
            1 if current is None else current.revision,
            None if current is None else current.label,
            tuple(ManagedComponentBinding(
                component,
                route.forge_instance_id if component == FORGE_COMPONENT
                    else route.engineering_platform_instance_id,
                f"receipt:planned-{component}",
            ) for component in components),
            None if current is None else current.peer_binding,
            schema=current.schema if current is not None else MANAGED_DEPLOYMENT_SCHEMA_V1,
            composition_binding=(
                None if current is None else current.composition_binding
            ),
        )
        plan = ManagedDeploymentPlanner.plan(
            current,
            desired,
            product_actions={
                component: _PRODUCT_ACTIONS[operations[component].change]
                for component in components
            },
        )
        readbacks = {
            component: _component_request(
                request.request_fingerprint,
                operations[component],
                manifest_components[component].artifact,
                manifest_components[component].role,
                route,
                readback=True,
            )
            for component in components
        }
        mutations = {
            component: _component_request(
                request.request_fingerprint,
                operations[component],
                manifest_components[component].artifact,
                manifest_components[component].role,
                route,
                readback=False,
            )
            for component in components
            if operations[component].change != "retain"
        }
        if len(components) == 2:
            result = self.coordinator.execute(
                request.operation_id, plan,
                mutation_requests=mutations, readback_requests=readbacks,
                adapters=route.adapters, pairing_executor=route.pairing_executor,
                composition_id=admitted.manifest.composition_id,
                composition_manifest_digest=admitted.manifest.manifest_digest,
            )
        else:
            result = self.single_coordinator.execute(
                request.operation_id, plan,
                mutation_requests=mutations, readback_requests=readbacks,
                adapters=route.adapters,
                composition_id=admitted.manifest.composition_id,
                composition_manifest_digest=admitted.manifest.manifest_digest,
            )
        if result.state != "COMPLETE":
            raise ManagedProductOperationDispatchError(
                f"product saga did not complete: {result.state}"
            )
        if (
            len(result.product_receipt_references) != len(components)
            or len(result.readiness_receipt_references) != len(components)
            or (result.pairing_receipt_reference is None) != (len(components) == 1)
        ):
            raise ManagedProductOperationDispatchError(
                "terminal product saga evidence is incomplete"
            )
        return NativeProductOperationDispatchReceipt(
            request.request_fingerprint,
            request.stable_plan_fingerprint,
            request.operation_id,
            tuple(sorted(result.product_receipt_references)),
            result.pairing_receipt_reference,
            tuple(sorted(result.readiness_receipt_references)),
            components,
        )


def _component_request(
    request_fingerprint: str,
    operation: NativeProductComponentOperation,
    artifact,
    role: str,
    route: ResolvedManagedProductRoute,
    *,
    readback: bool,
) -> ComponentOperationRequest:
    instance = (
        route.forge_instance_id
        if operation.identity == FORGE_COMPONENT
        else route.engineering_platform_instance_id
    )
    purpose = "readback" if readback else "mutation"
    operation_id = "product-" + sha256(
        f"{request_fingerprint}\x1f{operation.identity}\x1f{purpose}".encode("utf-8")
    ).hexdigest()
    return ComponentOperationRequest(
        operation_id,
        operation.identity,
        _PRODUCT_KINDS[operation.change],
        artifact,
        instance,
        role,
        (
            {"reviewed_update_assessment_reference": operation.update_assessment_reference}
            if operation.change == "update" else {}
        ),
    )


def _is_adapter(value: object) -> bool:
    return all(callable(getattr(value, method, None)) for method in (
        "readback", "assess_update", "execute", "resume",
    ))


def _is_pairer(value: object) -> bool:
    return callable(getattr(value, "pair", None))
