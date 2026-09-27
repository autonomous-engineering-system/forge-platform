#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import unittest
from unittest.mock import patch

from forge_platform.forge_server_adapter import ForgeUninstallBinding
from forge_platform.managed_install_flow import ManagedForgeEPInstallationCoordinator
from forge_platform.managed_product_removal_dispatch import (
    ManagedProductRemovalDispatcher, ManagedProductRemovalDispatchError,
)
from forge_platform.managed_product_removal_admission import ManagedProductRemovalAdmissionError
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
        with self.assertRaises(ManagedProductRemovalAdmissionError):
            dispatcher.dispatch(admitted)
        with self.assertRaisesRegex(ValueError, "share an EP consumer scope"):
            ManagedProductRemovalDispatcher(
                coordinator=self.coordinator,
                routes={"deployment-a": self.route(), "deployment-b": self.route(
                    forge_id="forge-b", ep_id="ep-b", deployment_id="deployment-b"
                )},
                current_installer_release=self.admission.release,
            )


if __name__ == "__main__":
    unittest.main()
