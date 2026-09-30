#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
import json
import unittest
from unittest.mock import patch

from forge_platform.forge_server_adapter import ForgeUninstallBinding
from forge_platform.managed_install_flow import ManagedForgeEPInstallationCoordinator
from forge_platform.managed_installer import (
    ManagedComponentExecution, ManagedDeploymentExecutionRecord,
)
from forge_platform.managed_product_operation_dispatch import (
    ManagedProductOperationDispatcher, PinnedManagedProductRouteResolver,
)
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService, ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from forge_platform.managed_product_removal_dispatch import (
    ManagedProductRemovalDispatcher, ManagedProductRemovalDispatchError,
)
from forge_platform.released_product_routes import ReleasedManagedProductRouteBuilder
import tests.installer.test_managed_product_removal_admission as admission_fixtures
import tests.installer.test_released_product_routes as route_fixtures
from tests.installer.test_managed_install_flow import Guard


class ManagedProductRemovalDispatchTests(unittest.TestCase):
    def setUp(self):
        self.admission = admission_fixtures.ManagedProductRemovalAdmissionTests(
            "test_exact_paired_component_removal_retains_ep_and_other_deployment"
        )
        self.admission.setUp()
        self.route_fixture = route_fixtures.ReleasedManagedProductRouteBuilderTests(
            "test_builds_exact_concrete_routes_from_catalog_authority"
        )
        self.route_fixture.setUp()
        self.root = self.admission.root
        self.coordinator = ManagedForgeEPInstallationCoordinator(
            operations_root=self.root / "operations",
            component_operations_root=self.root / "components",
            registry=self.admission.registry,
            currency_guard=Guard(),
        )

    def tearDown(self):
        self.route_fixture.tearDown()
        self.admission.tearDown()

    def route(self, *, forge_id="forge-a", ep_id="ep-a", deployment_id="deployment-a"):
        template = self.route_fixture.config
        config = replace(
            template,
            deployment_id=deployment_id,
            forge_target=replace(template.forge_target, instance_id=forge_id),
            engineering_platform_target=replace(
                template.engineering_platform_target, instance_id=ep_id,
            ),
            pairing_binding=replace(
                template.pairing_binding, expected_ep_instance_id=ep_id,
            ),
            forge_lifecycle_executable=self.root / "forge-lifecycle/bin/forge",
            forge_uninstall_binding=ForgeUninstallBinding(forge_id, "installation-1"),
        )
        return ReleasedManagedProductRouteBuilder.build_from_manifests(
            configurations=(config,),
            candidate_manifests=(self.admission.manifest,),
        )[deployment_id]

    def dispatcher(self, route, *, deployment_id="deployment-a"):
        return ManagedProductRemovalDispatcher(
            coordinator=self.coordinator, routes={deployment_id: route},
            current_installer_release=self.admission.release,
            expected_owner_uid=self.root.stat().st_uid,
        )

    def test_paired_component_dispatch_uses_exact_product_owned_boundaries(self):
        admitted = self.admission.admit(self.admission.payload())
        route = self.route()
        dispatcher = self.dispatcher(route)
        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedPairedForgeComponentRemovalCoordinator"
        ) as coordinator:
            coordinator.return_value.remove.return_value = "terminal"
            self.assertEqual(dispatcher.dispatch(admitted), "terminal")
        arguments = coordinator.return_value.remove.call_args
        constructor = coordinator.call_args.kwargs
        self.assertIs(constructor["detachment"], dispatcher.detachment)
        self.assertIs(constructor["pairing_binding"], route.pairing_executor.binding)
        self.assertEqual(arguments.args[0], "remove-a")
        self.assertEqual(arguments.args[1], admitted.plan)
        self.assertIs(arguments.kwargs["forge_adapter"], route.adapters["forge-runtime"])
        self.assertIs(arguments.kwargs["ep_adapter"], route.adapters["engineering-platform-server"])
        self.assertIs(arguments.kwargs["revoker"], route.ep_consumer_revoker)
        self.assertEqual(arguments.kwargs["forge_request"].kind, "remove")
        self.assertEqual(arguments.kwargs["forge_request"].installation_identity, "forge-a")
        self.assertEqual(arguments.kwargs["forge_request"].product_request, {})
        self.assertEqual(arguments.kwargs["ep_readback_request"].kind, "repair")
        self.assertEqual(arguments.kwargs["ep_readback_request"].installation_identity, "ep-a")
        self.assertEqual(arguments.kwargs["ep_readback_request"].product_request, {})

    def test_paired_deployment_dispatch_selects_ep_first_coordinator(self):
        admitted = self.admission.admit(
            self.admission.payload(action="REMOVE_DEPLOYMENT")
        )
        dispatcher = self.dispatcher(self.route())
        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedPairedDeploymentRemovalCoordinator"
        ) as coordinator:
            dispatcher.dispatch(admitted)
        arguments = coordinator.return_value.remove.call_args
        constructor = coordinator.call_args.kwargs
        self.assertIs(constructor["detachment"], dispatcher.detachment)
        self.assertIs(
            constructor["pairing_binding"],
            dispatcher.routes["deployment-a"].pairing_executor.binding,
        )
        self.assertEqual(arguments.kwargs["ep_request"].kind, "remove")
        self.assertEqual(arguments.kwargs["forge_request"].kind, "remove")
        self.assertIs(arguments.kwargs["revoker"], dispatcher.routes["deployment-a"].ep_consumer_revoker)

    def test_forge_only_deployment_dispatch_uses_exact_unpaired_coordinator(self):
        admitted = self.admission.admit(self.admission.payload(
            current=self.admission.other, action="REMOVE_DEPLOYMENT",
            operation_id="remove-b",
        ))
        dispatcher = self.dispatcher(
            self.route(forge_id="forge-b", ep_id="ep-b", deployment_id="deployment-b"),
            deployment_id="deployment-b",
        )
        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedForgeOnlyRemovalCoordinator"
        ) as coordinator:
            dispatcher.dispatch(admitted)
        arguments = coordinator.return_value.remove.call_args
        self.assertEqual(arguments.kwargs["request"].installation_identity, "forge-b")
        self.assertEqual(arguments.kwargs["request"].kind, "remove")

    def test_stale_registry_wrong_route_and_duplicate_scope_fail_closed(self):
        admitted = self.admission.admit(self.admission.payload())
        dispatcher = self.dispatcher(self.route())
        wrong = self.dispatcher(self.route(forge_id="forge-other"))
        with self.assertRaisesRegex(ManagedProductRemovalDispatchError, "Forge uninstall route"):
            wrong.dispatch(admitted)
        self.admission.registry.replace(
            replace(self.admission.paired, revision=2), expected_revision=1,
        )
        with self.assertRaises(ManagedProductRemovalDispatchError):
            dispatcher.dispatch(admitted)
        with self.assertRaisesRegex(ValueError, "share an EP consumer scope"):
            ManagedProductRemovalDispatcher(
                coordinator=self.coordinator,
                routes={"deployment-a": self.route(), "deployment-b": self.route(
                    forge_id="forge-b", ep_id="ep-b", deployment_id="deployment-b"
                )},
                current_installer_release=self.admission.release,
            )

    def test_paired_component_terminal_replay_uses_same_reviewed_operation(self):
        admitted = self.admission.admit(self.admission.payload())
        dispatcher = self.dispatcher(self.route())
        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedPairedForgeComponentRemovalCoordinator"
        ):
            dispatcher.dispatch(admitted)
        self.admission.registry.replace(
            replace(admitted.plan.desired, revision=2), expected_revision=1,
        )
        restored = dispatcher.admit_or_restore(
            admitted.request, installed_manifest=admitted.installed_manifest,
        )
        self.assertEqual(restored, admitted)
        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedPairedForgeComponentRemovalCoordinator"
        ) as coordinator:
            dispatcher.dispatch(restored)
            coordinator.return_value.remove.assert_called_once()
        self.assertEqual(self.admission.registry.load("deployment-a").revision, 2)

    def test_full_removal_terminal_replay_rejects_reassigned_instance(self):
        admitted = self.admission.admit(
            self.admission.payload(action="REMOVE_DEPLOYMENT")
        )
        dispatcher = self.dispatcher(self.route())
        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedPairedDeploymentRemovalCoordinator"
        ):
            dispatcher.dispatch(admitted)
        self.admission.registry.remove("deployment-a", expected_revision=1)
        self.assertEqual(
            dispatcher.admit_or_restore(
                admitted.request, installed_manifest=admitted.installed_manifest,
            ), admitted,
        )
        self.admission.registry.replace(
            replace(self.admission.other, revision=2, components=(
                admission_fixtures.ManagedComponentBinding(
                    "forge-runtime", "forge-a", "receipt:reassigned"
                ),
            )), expected_revision=1,
        )
        with self.assertRaisesRegex(ManagedProductRemovalDispatchError, "reassigned"):
            dispatcher.admit_or_restore(
                admitted.request, installed_manifest=admitted.installed_manifest,
            )
    def test_helper_service_emits_bounded_secret_free_terminal_receipt(self):
        payload = self.admission.payload()
        admitted = self.admission.admit(payload)
        route = self.route()
        dispatcher = self.dispatcher(route)
        resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=self.admission.release,
            manifests=(self.admission.manifest,),
        )
        product_dispatcher = ManagedProductOperationDispatcher(
            coordinator=self.coordinator,
            resolver=PinnedManagedProductRouteResolver({"deployment-a": route}),
        )
        service = ManagedProductOperationHelperService(
            authority_resolver=resolver, dispatcher=product_dispatcher,
            removal_dispatcher=dispatcher,
        )
        components = tuple(
            ManagedComponentExecution(
                diff.component, diff.instance_id, diff.action,
                None if diff.action == "NO_CHANGE" else "child-forge",
                "UNCHANGED" if diff.action == "NO_CHANGE" else "COMPLETE",
                None if diff.action == "NO_CHANGE" else "private-product-receipt",
            )
            for diff in admitted.plan.component_diffs
        )
        record = ManagedDeploymentExecutionRecord(
            "remove-a", "deployment-a",
            "sha256:" + admitted.request.reviewed_plan_sha256,
            1, components, "COMPLETE", 2,
        )
        def complete(*_args, **_kwargs):
            if self.admission.registry.load("deployment-a").revision == 1:
                self.admission.registry.replace(
                    replace(admitted.plan.desired, revision=2), expected_revision=1,
                )
            return record

        with patch(
            "forge_platform.managed_product_removal_dispatch.ManagedPairedForgeComponentRemovalCoordinator"
        ) as coordinator:
            coordinator.return_value.remove.side_effect = complete
            response = service.execute_removal(admission_fixtures.canonical(payload))
            replay = service.execute_removal(admission_fixtures.canonical(payload))
        self.assertEqual(replay, response)
        self.assertNotIn(b"private-product-receipt", response)
        decoded = json.loads(response)
        self.assertEqual(decoded["state"], "COMPLETE")
        self.assertEqual(decoded["registry_revision"], 2)
        self.assertEqual(decoded["request_fingerprint"], payload["request_fingerprint"])
        self.assertEqual(
            decoded["components"][1]["product_receipt_digest"],
            "sha256:" + sha256(b"private-product-receipt").hexdigest(),
        )

    def test_helper_service_pending_receipt_never_claims_terminal_completion(self):
        payload = self.admission.payload(action="REMOVE_DEPLOYMENT")
        admitted = self.admission.admit(payload)
        route = self.route()
        dispatcher = self.dispatcher(route)
        service = ManagedProductOperationHelperService(
            authority_resolver=PinnedManagedProductOperationAuthorityResolver(
                current_installer_release=self.admission.release,
                manifests=(self.admission.manifest,),
            ),
            dispatcher=ManagedProductOperationDispatcher(
                coordinator=self.coordinator,
                resolver=PinnedManagedProductRouteResolver({"deployment-a": route}),
            ),
            removal_dispatcher=dispatcher,
        )
        components = tuple(
            ManagedComponentExecution(
                diff.component, diff.instance_id, diff.action,
                "child-" + diff.component, "RECOVERY_PENDING", None,
            )
            for diff in admitted.plan.component_diffs
        )
        pending = ManagedDeploymentExecutionRecord(
            "remove-a", "deployment-a",
            "sha256:" + admitted.request.reviewed_plan_sha256,
            1, components, "RECOVERY_PENDING", None,
        )
        with patch.object(dispatcher, "dispatch", return_value=pending):
            response = service.execute_removal(admission_fixtures.canonical(payload))
        self.assertEqual(json.loads(response)["state"], "RECOVERY_PENDING")
        self.assertEqual(self.admission.registry.load("deployment-a"), admitted.reviewed_current)
        with patch.object(dispatcher, "dispatch", return_value=replace(
            pending, plan_fingerprint="sha256:" + "0" * 64,
        )):
            with self.assertRaisesRegex(ManagedProductOperationServiceError, "rejected"):
                service.execute_removal(admission_fixtures.canonical(payload))


if __name__ == "__main__":
    unittest.main()
