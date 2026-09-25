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
from .managed_deployments import (
    ManagedComponentBinding,
    ManagedDeployment,
    ManagedDeploymentPlanner,
)
from .managed_install_flow import (
    EP_COMPONENT,
    FORGE_COMPONENT,
    ForgeEPPairingExecutor,
    ManagedForgeEPInstallationCoordinator,
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
    forge_instance_id: str
    engineering_platform_instance_id: str
    adapters: Mapping[str, ProductOperationAdapter]
    pairing_executor: ForgeEPPairingExecutor

    def __post_init__(self) -> None:
        adapters = MappingProxyType(dict(self.adapters))
        object.__setattr__(self, "adapters", adapters)
        # ManagedComponentBinding owns the common safe opaque-ID grammar.
        ManagedComponentBinding(FORGE_COMPONENT, self.forge_instance_id, "receipt:route")
        ManagedComponentBinding(
            EP_COMPONENT, self.engineering_platform_instance_id, "receipt:route"
        )
        if self.forge_instance_id == self.engineering_platform_instance_id:
            raise ValueError("Forge and EP routes require distinct product instance identities")
        if set(adapters) != set(_COMPONENTS):
            raise ValueError("resolved product route requires exact Forge and EP adapters")
        if any(not _is_adapter(adapters[component]) for component in _COMPONENTS):
            raise ValueError("resolved product route contains an invalid adapter")
        if not _is_pairer(self.pairing_executor):
            raise ValueError("resolved product route requires a pairing executor")


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
                (FORGE_COMPONENT, route.forge_instance_id),
                (EP_COMPONENT, route.engineering_platform_instance_id),
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
        current = admitted.current_deployment
        if current is not None:
            by_component = current.by_component
            forge = by_component.get(FORGE_COMPONENT)
            ep = by_component.get(EP_COMPONENT)
            if (
                forge is None
                or ep is None
                or forge.instance_id != route.forge_instance_id
                or ep.instance_id != route.engineering_platform_instance_id
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
    pairing_receipt_reference: str
    readiness_receipt_references: tuple[str, ...]

    def canonical_json_bytes(self) -> bytes:
        completions = [
            {
                "component_identity": component,
                "state": "READY",
                "dashboard_url": None,
                "service_scope": None,
            }
            for component in _COMPONENTS
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
        manifest_components = {
            component.identity: component for component in admitted.manifest.components
        }
        desired = ManagedDeployment(
            request.deployment_id,
            1 if current is None else current.revision,
            None if current is None else current.label,
            (
                ManagedComponentBinding(
                    FORGE_COMPONENT, route.forge_instance_id, "receipt:planned-forge"
                ),
                ManagedComponentBinding(
                    EP_COMPONENT,
                    route.engineering_platform_instance_id,
                    "receipt:planned-ep",
                ),
            ),
            None if current is None else current.peer_binding,
        )
        plan = ManagedDeploymentPlanner.plan(
            current,
            desired,
            product_actions={
                component: _PRODUCT_ACTIONS[operations[component].change]
                for component in _COMPONENTS
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
            for component in _COMPONENTS
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
            for component in _COMPONENTS
            if operations[component].change != "retain"
        }
        result = self.coordinator.execute(
            request.operation_id,
            plan,
            mutation_requests=mutations,
            readback_requests=readbacks,
            adapters=route.adapters,
            pairing_executor=route.pairing_executor,
            composition_id=admitted.manifest.composition_id,
            composition_manifest_digest=admitted.manifest.manifest_digest,
        )
        if result.state != "COMPLETE":
            raise ManagedProductOperationDispatchError(
                f"product saga did not complete: {result.state}"
            )
        if (
            len(result.product_receipt_references) != 2
            or result.pairing_receipt_reference is None
            or len(result.readiness_receipt_references) != 2
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
        {},
    )


def _is_adapter(value: object) -> bool:
    return all(callable(getattr(value, method, None)) for method in (
        "readback", "assess_update", "execute", "resume",
    ))


def _is_pairer(value: object) -> bool:
    return callable(getattr(value, "pair", None))
