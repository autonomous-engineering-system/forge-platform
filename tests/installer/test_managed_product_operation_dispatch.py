#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_install_flow import ManagedForgeEPInstallationCoordinator
from forge_platform.managed_product_operation_admission import (
    admit_native_product_operation,
)
from forge_platform.managed_product_operation_dispatch import (
    ManagedProductOperationDispatchError,
    ManagedProductOperationDispatcher,
    PinnedManagedProductRouteResolver,
    ResolvedManagedProductRoute,
)
from tests.installer.test_managed_install_flow import Adapter, Guard, Pairer
from tests.installer.test_managed_product_operation_admission import (
    EP_DIGEST,
    FORGE_DIGEST,
    OLD_EP_DIGEST,
    OLD_FORGE_DIGEST,
    composition_manifest,
    decoded,
    installer_release,
    request_payload,
    stored_deployment,
)


class Resolver:
    def __init__(self, route) -> None:
        self.route = route
        self.calls = 0

    def resolve(self, admitted):
        self.calls += 1
        return self.route


def manifests():
    installed = composition_manifest(
        composition_id="forge-ep-old",
        forge_version="1.0.0",
        forge_digest=OLD_FORGE_DIGEST,
        ep_version="2.0.0",
        ep_digest=OLD_EP_DIGEST,
    )
    candidate = composition_manifest(
        composition_id="forge-ep-current",
        forge_version="1.1.0",
        forge_digest=FORGE_DIGEST,
        ep_version="2.1.0",
        ep_digest=EP_DIGEST,
        upgrade_from=("forge-ep-old",),
    )
    return installed, candidate


def coordinator(root: Path, registry: ManagedDeploymentRegistry, guard=None):
    return ManagedForgeEPInstallationCoordinator(
        operations_root=root / "operations",
        component_operations_root=root / "components",
        registry=registry,
        currency_guard=guard or Guard(),
    )


def route(*, forge="forge-new", ep="ep-new", pending_ep=False, degrade_ep=False):
    forge_adapter = Adapter("forge-runtime", forge)
    ep_adapter = Adapter(
        "engineering-platform-server", ep, pending_once=pending_ep
    )
    return ResolvedManagedProductRoute(
        forge,
        ep,
        {
            "forge-runtime": forge_adapter,
            "engineering-platform-server": ep_adapter,
        },
        Pairer(forge=forge, ep=ep, degrade_ep=degrade_ep),
    )


class ManagedProductOperationDispatchTests(unittest.TestCase):
    def test_pinned_resolver_snapshots_exact_helper_owned_route(self) -> None:
        _installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve() / "registry")
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=None, exists=False)),
                manifest=candidate,
                registry=registry,
                current_installer_release=installer_release(),
            )
            expected = route()
            routes = {"production": expected}
            resolver = PinnedManagedProductRouteResolver(routes)
            routes.clear()

            self.assertIs(resolver.resolve(admitted), expected)

    def test_pinned_resolver_rejects_unknown_or_conflicting_existing_route(self) -> None:
        installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            registry = ManagedDeploymentRegistry(Path(directory).resolve() / "registry")
            registry.create(stored_deployment(installed))
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=installed)),
                manifest=candidate,
                installed_manifest=installed,
                registry=registry,
                current_installer_release=installer_release(),
            )
            with self.assertRaisesRegex(
                ManagedProductOperationDispatchError, "existing topology"
            ):
                PinnedManagedProductRouteResolver({
                    "production": route(forge="other-forge", ep="other-ep")
                }).resolve(admitted)
            with self.assertRaisesRegex(
                ManagedProductOperationDispatchError, "unavailable"
            ):
                PinnedManagedProductRouteResolver({"other": route()}).resolve(admitted)
            with self.assertRaises(TypeError):
                PinnedManagedProductRouteResolver({"production": route()}).resolve(object())

    def test_pinned_resolver_rejects_invalid_or_reused_helper_routes(self) -> None:
        valid = route()
        for routes in (
            {},
            {"production": object()},
            {"unsafe/path": valid},
        ):
            with self.subTest(routes=routes), self.assertRaises((TypeError, ValueError)):
                PinnedManagedProductRouteResolver(routes)
        with self.assertRaisesRegex(ValueError, "reuse"):
            PinnedManagedProductRouteResolver({
                "production": valid,
                "staging": route(forge=valid.forge_instance_id, ep="ep-staging"),
            })

    def test_fresh_admitted_route_dispatches_saga_and_returns_native_receipt(self) -> None:
        _installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            request = decoded(request_payload(candidate, installed=None, exists=False))
            admitted = admit_native_product_operation(
                request,
                manifest=candidate,
                registry=registry,
                current_installer_release=installer_release(),
            )
            resolved = route()
            resolver = Resolver(resolved)

            receipt = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry),
                resolver=resolver,
            ).dispatch(admitted)

            self.assertEqual(resolver.calls, 1)
            self.assertEqual(len(receipt.product_receipt_references), 2)
            self.assertEqual(len(receipt.readiness_receipt_references), 2)
            payload = json.loads(receipt.canonical_json_bytes())
            self.assertEqual(
                payload["schema"],
                "forge-platform.native-product-operation-receipt/v1",
            )
            self.assertEqual(payload["request_fingerprint"], request.request_fingerprint)
            self.assertEqual(
                [item["component_identity"] for item in payload["completions"]],
                ["engineering-platform-server", "forge-runtime"],
            )
            self.assertTrue(all(item["state"] == "READY" for item in payload["completions"]))
            stored = registry.load("production")
            self.assertEqual(stored.schema, "forge-platform.managed-deployment/v2")
            self.assertEqual(stored.composition_binding.composition_id, "forge-ep-current")
            self.assertEqual(stored.by_component["forge-runtime"].instance_id, "forge-new")
            self.assertEqual(
                stored.by_component["engineering-platform-server"].instance_id,
                "ep-new",
            )

    def test_existing_route_cannot_change_admitted_product_targets(self) -> None:
        installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            registry.create(stored_deployment(installed))
            request = decoded(request_payload(candidate, installed=installed))
            admitted = admit_native_product_operation(
                request,
                manifest=candidate,
                installed_manifest=installed,
                registry=registry,
                current_installer_release=installer_release(),
            )
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry),
                resolver=Resolver(route(forge="other-forge", ep="other-ep")),
            )
            with self.assertRaisesRegex(
                ManagedProductOperationDispatchError, "existing topology"
            ):
                dispatcher.dispatch(admitted)

    def test_recovery_pending_and_readiness_failure_never_emit_native_complete(self) -> None:
        _installed, candidate = manifests()
        for resolved, expected in (
            (route(pending_ep=True), "RECOVERY_PENDING"),
            (route(degrade_ep=True), "READINESS_FAILED"),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                registry = ManagedDeploymentRegistry(root / "registry")
                admitted = admit_native_product_operation(
                    decoded(request_payload(candidate, installed=None, exists=False)),
                    manifest=candidate,
                    registry=registry,
                    current_installer_release=installer_release(),
                )
                dispatcher = ManagedProductOperationDispatcher(
                    coordinator=coordinator(root, registry),
                    resolver=Resolver(resolved),
                )
                with self.assertRaisesRegex(ManagedProductOperationDispatchError, expected):
                    dispatcher.dispatch(admitted)

    def test_currency_failure_is_not_converted_into_completion(self) -> None:
        _installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=None, exists=False)),
                manifest=candidate,
                registry=registry,
                current_installer_release=installer_release(),
            )
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(
                    root, registry, Guard(fail_mutation="product-install")
                ),
                resolver=Resolver(route()),
            )
            with self.assertRaisesRegex(RuntimeError, "update required"):
                dispatcher.dispatch(admitted)
            self.assertIsNone(registry.load("production"))

    def test_route_and_dispatcher_construction_reject_incomplete_authority(self) -> None:
        valid = route()
        with self.assertRaisesRegex(ValueError, "distinct"):
            ResolvedManagedProductRoute(
                "same",
                "same",
                valid.adapters,
                valid.pairing_executor,
            )
        with self.assertRaisesRegex(ValueError, "exact Forge and EP"):
            ResolvedManagedProductRoute(
                "forge-new",
                "ep-new",
                {"forge-runtime": valid.adapters["forge-runtime"]},
                valid.pairing_executor,
            )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            with self.assertRaises(TypeError):
                ManagedProductOperationDispatcher(coordinator=object(), resolver=Resolver(valid))
            with self.assertRaises(TypeError):
                ManagedProductOperationDispatcher(
                    coordinator=coordinator(root, registry), resolver=object()
                )

    def test_resolver_must_return_typed_route_and_dispatch_requires_admission(self) -> None:
        class BadResolver:
            def resolve(self, admitted):
                return object()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry), resolver=BadResolver()
            )
            with self.assertRaises(TypeError):
                dispatcher.dispatch(object())
            _installed, candidate = manifests()
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=None, exists=False)),
                manifest=candidate,
                registry=registry,
                current_installer_release=installer_release(),
            )
            with self.assertRaisesRegex(ManagedProductOperationDispatchError, "invalid route"):
                dispatcher.dispatch(admitted)


if __name__ == "__main__":
    unittest.main()
