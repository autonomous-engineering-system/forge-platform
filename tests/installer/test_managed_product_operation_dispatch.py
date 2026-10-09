#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
from types import SimpleNamespace
from dataclasses import replace

from forge_platform.component_operations import ProductUpdateAssessment
from forge_platform.ep_consumer_revocation import EPConsumerRevocationAdapter, EPConsumerScope
from forge_platform.forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding, ForgeEPProductPairingExecutor,
)
from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_install_flow import ManagedForgeEPInstallationCoordinator
from forge_platform.managed_product_operation_admission import (
    ManagedProductOperationAdmissionError,
    admit_native_product_operation,
)
from forge_platform.managed_product_operation_dispatch import (
    ManagedProductOperationDispatchError,
    ManagedProductOperationDispatcher,
    PinnedManagedProductRouteResolver,
    ResolvedManagedProductRoute,
    _component_request,
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
    _refingerprint,
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
    def test_released_pairing_fails_before_mutation_without_private_secure_store(self) -> None:
        _installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=None, exists=False)),
                manifest=candidate, registry=registry,
                current_installer_release=installer_release(),
            )
            selected = route()
            ep = selected.adapters["engineering-platform-server"]
            ep.target = SimpleNamespace(instance_id="ep-new")
            ep.staged_artifacts = {EP_DIGEST: root / "ep.whl"}
            pairer = Mock(spec=ForgeEPProductPairingExecutor)
            pairer.binding = ForgeEPProductPairingBinding(
                "ep-primary", "http://127.0.0.1:8876", "ep-new",
                "consumer-a", "host-a", "project-a", "repository-a",
                "owner:repo", "keychain://forge.ep/consumer-a", "installer", True,
            )
            revoker = Mock(spec=EPConsumerRevocationAdapter)
            revoker.provisioner = ep
            revoker.scope = EPConsumerScope("consumer-a", "project-a")
            revoker.expected_artifact = SimpleNamespace(digest=EP_DIGEST)
            selected = ResolvedManagedProductRoute(
                "forge-new", "ep-new", selected.adapters, pairer, revoker,
            )
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry), resolver=Resolver(selected),
            )
            with self.assertRaisesRegex(ManagedProductOperationDispatchError, "credential authority"):
                dispatcher.dispatch(admitted)
            self.assertIsNone(registry.load("production"))

    def test_forge_only_route_dispatches_exact_durable_product_saga(self) -> None:
        candidate = composition_manifest(
            composition_id="forge-only", forge_version="2.7.35",
            forge_digest=FORGE_DIGEST, ep_version="2.3.102",
            ep_digest=EP_DIGEST, components=("forge-runtime",),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=None, exists=False)),
                manifest=candidate, registry=registry,
                current_installer_release=installer_release(),
            )
            selected = ResolvedManagedProductRoute(
                "forge-only-instance", None,
                {"forge-runtime": Adapter("forge-runtime", "forge-only-instance")},
                None,
            )
            resolver = PinnedManagedProductRouteResolver({"production": selected})
            self.assertIs(resolver.resolve(admitted), selected)
            with self.assertRaisesRegex(
                ManagedProductOperationDispatchError, "component topology"
            ):
                PinnedManagedProductRouteResolver({"production": route()}).resolve(admitted)
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry), resolver=resolver,
            )
            receipt = dispatcher.dispatch(admitted)
            self.assertIsNone(receipt.pairing_receipt_reference)
            self.assertEqual(len(receipt.product_receipt_references), 1)
            self.assertEqual(len(receipt.readiness_receipt_references), 1)
            self.assertEqual(
                [item["component_identity"] for item in
                 json.loads(receipt.canonical_json_bytes())["completions"]],
                ["forge-runtime"],
            )
            stored = registry.load("production")
            self.assertEqual(set(stored.by_component), {"forge-runtime"})
            self.assertIsNone(stored.peer_binding)
            self.assertEqual(stored.composition_binding.composition_id, "forge-only")

    def test_ep_only_route_dispatches_without_forge_or_pairing(self) -> None:
        candidate = composition_manifest(
            composition_id="ep-only", forge_version="2.7.35",
            forge_digest=FORGE_DIGEST, ep_version="2.3.102",
            ep_digest=EP_DIGEST,
            components=("engineering-platform-server",),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            admitted = admit_native_product_operation(
                decoded(request_payload(candidate, installed=None, exists=False)),
                manifest=candidate, registry=registry,
                current_installer_release=installer_release(),
            )
            ep = Adapter("engineering-platform-server", "ep-only-instance")
            selected = ResolvedManagedProductRoute(
                None, "ep-only-instance", {"engineering-platform-server": ep}, None,
            )
            receipt = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry),
                resolver=PinnedManagedProductRouteResolver({"production": selected}),
            ).dispatch(admitted)
            self.assertIsNone(receipt.pairing_receipt_reference)
            self.assertEqual(ep.execute_calls, 1)
            self.assertEqual(
                set(registry.load("production").by_component),
                {"engineering-platform-server"},
            )

    def test_update_component_request_binds_reviewed_product_assessment(self) -> None:
        installed, candidate = manifests()
        native = decoded(request_payload(candidate, installed=installed))
        selected = route(forge="forge-prod", ep="ep-prod")
        artifacts = {component.identity: component.artifact for component in candidate.components}
        for operation in native.components:
            product = _component_request(
                native.request_fingerprint, operation, artifacts[operation.identity],
                "server", selected, readback=False,
            )
            self.assertEqual(product.product_request, {
                "reviewed_update_assessment_reference": operation.update_assessment_reference,
            })
            self.assertEqual(product.kind, "update")

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

    def test_completed_create_resumes_pairing_without_repeating_products(self):
        _installed, candidate = manifests()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve(); registry=ManagedDeploymentRegistry(root/"registry")
            request=decoded(request_payload(candidate,installed=None,exists=False))
            class InterruptedPairer(Pairer):
                interrupted=True
                def pair(self, **kwargs):
                    if self.interrupted:
                        self.interrupted=False
                        raise RuntimeError("interrupted pairing")
                    return super().pair(**kwargs)
            original=route(); pairer=InterruptedPairer(forge=original.forge_instance_id, ep=original.engineering_platform_instance_id)
            resolved=replace(original,pairing_executor=pairer)
            engine=coordinator(root,registry);engine.expected_owner_uid=os.getuid()
            dispatcher=ManagedProductOperationDispatcher(coordinator=engine,resolver=Resolver(resolved))
            admitted=admit_native_product_operation(request,manifest=candidate,registry=registry,
                current_installer_release=installer_release())
            with self.assertRaisesRegex(RuntimeError,"interrupted pairing"):
                dispatcher.dispatch(admitted)
            current=registry.load(request.deployment_id)
            self.assertIsNotNone(current);self.assertIsNone(current.peer_binding)
            before={name:adapter.execute_calls for name,adapter in resolved.adapters.items()}
            # A registry entry alone cannot authorize recovery. It must still
            # match every receipt committed by the original completed saga.
            registry_path=registry.root / (request.deployment_id + ".json")
            original_bytes=registry_path.read_bytes()
            altered=json.loads(original_bytes)
            altered["components"][0]["receipt_reference"]="receipt:unrelated"
            registry_path.write_text(json.dumps(altered))
            with self.assertRaises(ManagedProductOperationAdmissionError):
                admit_native_product_operation(request,manifest=candidate,registry=registry,
                    current_installer_release=installer_release(),
                    completed_create_plan_reader=dispatcher.completed_create_plan)
            registry_path.write_bytes(original_bytes)
            resumed=admit_native_product_operation(request,manifest=candidate,registry=registry,
                current_installer_release=installer_release(),
                completed_create_plan_reader=dispatcher.completed_create_plan)
            self.assertEqual(resumed.current_deployment,current)
            self.assertIsNotNone(resumed.completed_create_plan)
            receipt=dispatcher.dispatch(resumed)
            self.assertIsNotNone(receipt.pairing_receipt_reference)
            self.assertEqual(before,{name:adapter.execute_calls for name,adapter in resolved.adapters.items()})

    def test_two_fresh_deployments_keep_exact_product_instances_isolated(self) -> None:
        candidate = composition_manifest(
            composition_id="forge-ep-current",
            forge_version="2.7.38", forge_digest=FORGE_DIGEST,
            ep_version="2.3.106", ep_digest=EP_DIGEST,
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            first_route = route(forge="forge-a", ep="ep-a")
            second_route = route(forge="forge-b", ep="ep-b")
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry),
                resolver=PinnedManagedProductRouteResolver({
                    "production": first_route,
                    "qualification": second_route,
                }),
            )
            first_request = decoded(request_payload(
                candidate, installed=None, exists=False,
            ))
            first = admit_native_product_operation(
                first_request, manifest=candidate, registry=registry,
                current_installer_release=installer_release(),
            )
            first_receipt = dispatcher.dispatch(first)
            first_record = registry.load("production")
            self.assertIsNotNone(first_record)
            first_bytes = (registry.root / "production.json").read_bytes()

            second_payload = request_payload(candidate, installed=None, exists=False)
            second_payload.update({
                "deployment_id": "qualification",
                "operation_id": "operation-two",
                "session_id": "session-two",
                "stable_plan_fingerprint": "2" * 64,
                "inventory_evidence_reference": "evidence:inventory-two",
            })
            second_request = decoded(_refingerprint(second_payload))
            second = admit_native_product_operation(
                second_request, manifest=candidate, registry=registry,
                current_installer_release=installer_release(),
            )
            second_receipt = dispatcher.dispatch(second)
            second_record = registry.load("qualification")
            self.assertIsNotNone(second_record)
            self.assertEqual(first_record, registry.load("production"))
            self.assertEqual(first_bytes, (registry.root / "production.json").read_bytes())
            self.assertEqual(first_record.by_component["forge-runtime"].instance_id, "forge-a")
            self.assertEqual(first_record.by_component["engineering-platform-server"].instance_id, "ep-a")
            self.assertEqual(second_record.by_component["forge-runtime"].instance_id, "forge-b")
            self.assertEqual(second_record.by_component["engineering-platform-server"].instance_id, "ep-b")
            self.assertNotEqual(first_receipt.request_fingerprint, second_receipt.request_fingerprint)
            self.assertEqual(
                [adapter.execute_calls for adapter in first_route.adapters.values()],
                [1, 1],
            )
            self.assertEqual(
                [adapter.execute_calls for adapter in second_route.adapters.values()],
                [1, 1],
            )
            self.assertEqual(
                {item.deployment_id for item in registry.inventory()},
                {"production", "qualification"},
            )

    def test_existing_forge_update_commits_reviewed_new_composition_after_readiness(self) -> None:
        class AvailableForgeAdapter(Adapter):
            def assess_update(self, request):
                return ProductUpdateAssessment(
                    request.component, request.installation_identity,
                    request.artifact.correlation, "UPDATE_AVAILABLE",
                    "evidence:forge-update-available",
                )

        installed = composition_manifest(
            composition_id="forge-ep-old", forge_version="1.0.0",
            forge_digest=OLD_FORGE_DIGEST, ep_version="2.0.0",
            ep_digest=OLD_EP_DIGEST,
        )
        candidate = composition_manifest(
            composition_id="forge-ep-current", forge_version="1.1.0",
            forge_digest=FORGE_DIGEST, ep_version="2.0.0",
            ep_digest=OLD_EP_DIGEST, upgrade_from=("forge-ep-old",),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            registry.create(stored_deployment(installed))
            payload = request_payload(candidate, installed=installed)
            payload["components"][0]["change"] = "retain"
            payload["components"][0]["update_assessment_reference"] = None
            request = decoded(_refingerprint(payload))
            admitted = admit_native_product_operation(
                request, manifest=candidate, installed_manifest=installed,
                registry=registry, current_installer_release=installer_release(),
            )
            forge = AvailableForgeAdapter("forge-runtime", "forge-prod")
            ep = Adapter("engineering-platform-server", "ep-prod")
            forge.active = True
            ep.active = True
            selected = ResolvedManagedProductRoute(
                "forge-prod", "ep-prod",
                {"forge-runtime": forge, "engineering-platform-server": ep},
                Pairer(),
            )
            receipt = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry),
                resolver=Resolver(selected),
            ).dispatch(admitted)
            stored = registry.load("production")
            self.assertEqual(stored.composition_binding.composition_id, candidate.composition_id)
            self.assertEqual(stored.composition_binding.manifest_digest, candidate.manifest_digest)
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(ep.execute_calls, 0)
            self.assertEqual(len(receipt.readiness_receipt_references), 2)

    def test_interrupted_existing_forge_update_resumes_without_losing_provenance(self) -> None:
        class PendingAvailableForgeAdapter(Adapter):
            def assess_update(self, request):
                return ProductUpdateAssessment(
                    request.component, request.installation_identity,
                    request.artifact.correlation, "UPDATE_AVAILABLE",
                    "evidence:forge-update-available",
                )

        installed = composition_manifest(
            composition_id="forge-ep-old", forge_version="1.0.0",
            forge_digest=OLD_FORGE_DIGEST, ep_version="2.0.0",
            ep_digest=OLD_EP_DIGEST,
        )
        candidate = composition_manifest(
            composition_id="forge-ep-current", forge_version="1.1.0",
            forge_digest=FORGE_DIGEST, ep_version="2.0.0",
            ep_digest=OLD_EP_DIGEST, upgrade_from=("forge-ep-old",),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            registry = ManagedDeploymentRegistry(root / "registry")
            registry.create(stored_deployment(installed))
            payload = request_payload(candidate, installed=installed)
            payload["components"][0]["change"] = "retain"
            payload["components"][0]["update_assessment_reference"] = None
            admitted = admit_native_product_operation(
                decoded(_refingerprint(payload)), manifest=candidate,
                installed_manifest=installed, registry=registry,
                current_installer_release=installer_release(),
            )
            forge = PendingAvailableForgeAdapter(
                "forge-runtime", "forge-prod", pending_once=True
            )
            ep = Adapter("engineering-platform-server", "ep-prod")
            forge.active = ep.active = True
            selected = ResolvedManagedProductRoute(
                "forge-prod", "ep-prod",
                {"forge-runtime": forge, "engineering-platform-server": ep},
                Pairer(),
            )
            dispatcher = ManagedProductOperationDispatcher(
                coordinator=coordinator(root, registry),
                resolver=Resolver(selected),
            )
            with self.assertRaisesRegex(ManagedProductOperationDispatchError, "RECOVERY_PENDING"):
                dispatcher.dispatch(admitted)
            self.assertEqual(
                registry.load("production").composition_binding.composition_id,
                installed.composition_id,
            )
            receipt = dispatcher.dispatch(admitted)
            self.assertEqual(len(receipt.readiness_receipt_references), 2)
            self.assertEqual(forge.execute_calls, 1)
            self.assertEqual(forge.resume_calls, 1)
            self.assertEqual(ep.execute_calls, 0)
            self.assertEqual(
                registry.load("production").composition_binding.composition_id,
                candidate.composition_id,
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
        with self.assertRaisesRegex(ValueError, "inconsistent component targets"):
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
