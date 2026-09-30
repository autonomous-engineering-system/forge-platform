#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
import json
from pathlib import Path
import tempfile
import unittest

from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    EngineeringPlatformSystemProvisionerAdapter,
)
from forge_platform.ep_consumer_revocation import EPConsumerRevocationAdapter, EPConsumerScope
from forge_platform.forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding,
    ForgeEPProductPairingExecutor,
)
from forge_platform.forge_server_adapter import ForgeServerProductAdapter, ForgeServerTarget, ForgeUninstallBinding
from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperBuilder,
)
from forge_platform.managed_product_removal_dispatch import ManagedProductRemovalDispatcher
from forge_platform.released_product_routes import (
    ReleasedManagedProductRouteBuilder,
    ReleasedManagedProductRouteConfiguration,
    ReleasedManagedSingleProductRouteConfiguration,
)
from forge_platform.universal_installer import VerifiedCompositionSelection
from tests.installer.test_managed_product_operation_dispatch import coordinator
from tests.installer.test_managed_product_operation_admission import installer_release
from tests.installer.test_universal_installer import (
    CATALOG_URL,
    COMPOSITION_CATALOG_SCHEMA,
    FIXTURE_SIGNATURE_ENVELOPE,
    FIXTURE_SIGNATURE_POLICY,
    FixtureVerifier,
    INSTALLER_CAPABILITIES,
    NOW,
    current_context,
    manifest_payload,
)


FORGE_DIGEST = "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938"
EP_DIGEST = "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694"


def verified_forge_ep_selection(
    context, composition_id="forge-ep-current",
    components=("engineering-platform-server", "forge-runtime"),
):
    payload = manifest_payload(composition_id=composition_id)
    ep = payload["components"][0]
    ep["artifact"]["version"] = "2.3.106"
    ep["artifact"]["source_revision"] = "7b99b578153ae5d72372a09db194306b49ec9f9c"
    ep["artifact"]["digest"] = EP_DIGEST
    forge = json.loads(json.dumps(ep))
    forge["identity"] = "forge-runtime"
    forge["artifact"] = {
        "version": "2.7.37",
        "source_revision": "a78523603d6ea081d07875ea6b557e73b5d4fe63",
        "source": "https://registry.example.invalid/forge-runtime.whl",
        "digest": FORGE_DIGEST,
        "qualification": "https://evidence.example.invalid/forge-runtime",
    }
    forge["service"]["product_service_reference"] = "forge-server-service-v1"
    payload["components"].append(forge)
    payload["product_venvs"].append({
        "component_identity": "forge-runtime",
        "venv_identity": "forge-runtime-primary",
        "python_runtime_identity": payload["python_runtime"]["identity_digest"],
    })
    payload["components"] = [
        item for item in payload["components"] if item["identity"] in components
    ]
    payload["product_venvs"] = [
        item for item in payload["product_venvs"]
        if item["component_identity"] in components
    ]
    raw_manifest = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    catalog = {
        "schema": COMPOSITION_CATALOG_SCHEMA,
        "sequence": 4,
        "channel": "stable",
        "published_at": "2026-09-01T00:00:00Z",
        "expires_at": "2026-10-01T00:00:00Z",
        "approved_python_runtime_identity": payload["python_runtime"]["identity_digest"],
        "compositions": [{
            "composition_id": composition_id,
            "channel": "stable",
            "url": f"https://github.example.invalid/releases/{composition_id}.json",
            "digest": "sha256:" + sha256(raw_manifest).hexdigest(),
            "requires_installer": {
                "minimum_version": "1.0.0",
                "capabilities": list(INSTALLER_CAPABILITIES),
            },
        }],
        "signatures": [dict(FIXTURE_SIGNATURE_ENVELOPE)],
    }
    return VerifiedCompositionSelection.establish(
        context,
        catalog_source_url=CATALOG_URL,
        catalog_raw_bytes=json.dumps(
            catalog, sort_keys=True, separators=(",", ":")
        ).encode(),
        catalog_verifier=FixtureVerifier(),
        catalog_signature_policy=FIXTURE_SIGNATURE_POLICY,
        accepted_catalog=None,
        composition_id=composition_id,
        manifest_raw_bytes=raw_manifest,
        now=NOW,
        trusted_clock=True,
    )


class ReleasedManagedProductRouteBuilderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.context = current_context()
        self.selection = verified_forge_ep_selection(self.context)
        self.components = {
            component.identity: component
            for component in self.selection.manifest.components
        }
        self.config = self.configuration()

    def tearDown(self):
        self.temporary.cleanup()

    def configuration(self, **changes):
        forge_target = ForgeServerTarget(
            "forge-prod",
            self.root / "forge/instances/forge-prod",
            self.root / "forge/instances",
            "_forge_prod",
            8875,
            self.root / "forge/credentials/api",
        )
        ep_target = EPSystemInstanceTarget("ep-prod", "Production", "_ep_prod", 8876)
        values = {
            "deployment_id": "production",
            "forge_executable": self.root / "venvs/forge/bin/forge",
            "forge_target": forge_target,
            "forge_installed_artifact": self.components["forge-runtime"].artifact,
            "engineering_platform_installed_artifact": self.components[
                "engineering-platform-server"
            ].artifact,
            "engineering_platform_provisioner": self.root / "venvs/ep/bin/engineering-platform-system-provisioner",
            "engineering_platform_product_root": self.root / "products/ep",
            "engineering_platform_target": ep_target,
            "staged_artifacts": {
                component.artifact.digest: self.root / "staged" / f"{component.identity}.whl"
                for component in self.components.values()
            },
            "pairing_binding": ForgeEPProductPairingBinding(
                "ep-primary",
                "http://127.0.0.1:8876",
                "ep-prod",
                "forge-consumer",
                "engineering-platform",
                "forge-project",
                "forge-repository",
                "pcvantol:forge",
                "keychain://forge.ep/consumer",
                "installer",
                True,
            ),
            "launch_daemons_directory": self.root / "LaunchDaemons",
        }
        values.update(changes)
        return ReleasedManagedProductRouteConfiguration(**values)

    def isolated_other_configuration(self):
        return self.configuration(
            deployment_id="production-other",
            forge_target=replace(
                self.config.forge_target,
                instance_id="forge-other",
                data_root=self.root / "forge/instances/forge-other",
                service_account="_forge_other",
                bind_port=8877,
                api_credential_file=self.root / "forge/credentials/api-other",
            ),
            engineering_platform_target=replace(
                self.config.engineering_platform_target,
                instance_id="ep-other", service_account="_ep_other", bind_port=8878,
            ),
            pairing_binding=replace(
                self.config.pairing_binding,
                endpoint="http://127.0.0.1:8878",
                expected_ep_instance_id="ep-other",
                consumer_id="forge-consumer-other",
                project_id="forge-project-other",
            ),
        )

    def test_builds_exact_concrete_routes_from_catalog_authority(self):
        routes = ReleasedManagedProductRouteBuilder.build(
            configurations=(self.config,),
            candidate_selections=(self.selection,),
        )

        route = routes["production"]
        self.assertIsInstance(route.adapters["forge-runtime"], ForgeServerProductAdapter)
        self.assertIsInstance(
            route.adapters["engineering-platform-server"],
            EngineeringPlatformSystemProvisionerAdapter,
        )
        self.assertIsInstance(route.pairing_executor, ForgeEPProductPairingExecutor)
        self.assertIsInstance(route.ep_consumer_revoker, EPConsumerRevocationAdapter)
        self.assertIs(
            route.ep_consumer_revoker.provisioner,
            route.adapters["engineering-platform-server"],
        )
        self.assertEqual(
            route.ep_consumer_revoker.scope,
            EPConsumerScope("forge-consumer", "forge-project"),
        )
        self.assertEqual(
            route.ep_consumer_revoker.expected_artifact,
            self.components["engineering-platform-server"].artifact,
        )
        self.assertEqual(route.forge_instance_id, "forge-prod")
        self.assertEqual(route.engineering_platform_instance_id, "ep-prod")
        with self.assertRaises(TypeError):
            routes["other"] = route

    def test_lifecycle_executable_is_fixed_by_helper_route(self):
        lifecycle = self.root / "lifecycle/forge-2.7.37/bin/forge"
        uninstall = ForgeUninstallBinding("forge-prod", "installation-1")
        config = self.configuration(
            forge_lifecycle_executable=lifecycle, forge_uninstall_binding=uninstall,
        )
        routes = ReleasedManagedProductRouteBuilder.build(
            configurations=(config,), candidate_selections=(self.selection,),
        )
        self.assertEqual(routes["production"].adapters["forge-runtime"].lifecycle_executable, lifecycle)
        self.assertEqual(routes["production"].adapters["forge-runtime"].uninstall_binding, uninstall)
        self.assertEqual(routes["production"].adapters["forge-runtime"].removal_support(), "SUPPORTED")
        with self.assertRaisesRegex(ValueError, "lifecycle executable must be absolute"):
            self.configuration(forge_lifecycle_executable=Path("relative/forge"))
        with self.assertRaisesRegex(TypeError, "uninstall binding is invalid"):
            self.configuration(forge_uninstall_binding="foreign")
        with self.assertRaisesRegex(ValueError, "different instance"):
            self.configuration(
                forge_uninstall_binding=ForgeUninstallBinding("foreign", "installation-1")
            )

    def test_closed_helper_builder_constructs_routes_and_authority_together(self):
        product_coordinator = coordinator(
            self.root,
            ManagedDeploymentRegistry(self.root / "registry"),
        )

        service = ManagedProductOperationHelperBuilder.build_released(
            current_installer_context=self.context,
            candidate_selections=(self.selection,),
            coordinator=product_coordinator,
            route_configurations=(self.config,),
        )

        self.assertIs(service.dispatcher.coordinator, product_coordinator)
        self.assertIsInstance(service.removal_dispatcher, ManagedProductRemovalDispatcher)
        self.assertIs(service.removal_dispatcher.coordinator, product_coordinator)
        self.assertEqual(
            service.authority_resolver.current_installer_release.version,
            "1.1.0",
        )

    def test_pinned_worker_builder_uses_exact_typed_manifest_snapshot(self):
        product_coordinator = coordinator(
            self.root,
            ManagedDeploymentRegistry(self.root / "registry"),
        )

        routes = ReleasedManagedProductRouteBuilder.build_from_manifests(
            configurations=(self.config,),
            candidate_manifests=(self.selection.manifest,),
        )
        service = ManagedProductOperationHelperBuilder.build_pinned(
            current_installer_release=installer_release(),
            candidate_manifests=(self.selection.manifest,),
            coordinator=product_coordinator,
            route_configurations=(self.config,),
        )

        self.assertEqual(tuple(routes), ("production",))
        self.assertEqual(
            service.authority_resolver.current_installer_release,
            installer_release(),
        )
        self.assertIs(service.dispatcher.coordinator, product_coordinator)

    def test_pinned_worker_builder_rejects_untyped_manifest_or_coordinator(self):
        product_coordinator = coordinator(
            self.root,
            ManagedDeploymentRegistry(self.root / "registry"),
        )
        with self.assertRaises(TypeError):
            ReleasedManagedProductRouteBuilder.build_from_manifests(
                configurations=(self.config,),
                candidate_manifests=(object(),),
            )
        with self.assertRaises(TypeError):
            ManagedProductOperationHelperBuilder.build_pinned(
                current_installer_release=installer_release(),
                candidate_manifests=(self.selection.manifest,),
                coordinator=object(),
                route_configurations=(self.config,),
            )

    def test_route_configuration_rejects_path_pairing_and_artifact_ambiguity(self):
        for changes, message in (
            ({"forge_executable": Path("relative")}, "absolute"),
            ({"staged_artifacts": {}}, "staged"),
            ({"pairing_binding": replace(
                self.config.pairing_binding,
                expected_ep_instance_id="ep-other",
            )}, "configured EP"),
            ({"pairing_binding": replace(
                self.config.pairing_binding,
                endpoint="http://127.0.0.1:9999",
            )}, "local EP"),
        ):
            with self.subTest(message=message), self.assertRaisesRegex(
                (TypeError, ValueError), message
            ):
                self.configuration(**changes)
        duplicate_path = self.root / "staged/same.whl"
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.configuration(staged_artifacts={
                self.components["forge-runtime"].artifact.digest: duplicate_path,
                self.components["engineering-platform-server"].artifact.digest: duplicate_path,
            })

    def test_builder_rejects_missing_extra_or_unauthorized_artifacts(self):
        staged = dict(self.config.staged_artifacts)
        staged.pop(self.components["forge-runtime"].artifact.digest)
        wrong_installed = replace(
            self.components["forge-runtime"].artifact,
            digest="sha256:" + "9" * 64,
        )
        cases = (
            self.configuration(staged_artifacts=staged),
            self.configuration(staged_artifacts={
                **self.config.staged_artifacts,
                "sha256:" + "8" * 64: self.root / "staged/extra.whl",
            }),
            self.configuration(forge_installed_artifact=wrong_installed),
        )
        for config in cases:
            with self.subTest(config=config), self.assertRaisesRegex(
                ValueError, "catalog authority"
            ):
                ReleasedManagedProductRouteBuilder.build(
                    configurations=(config,),
                    candidate_selections=(self.selection,),
                )

    def test_builder_rejects_invalid_or_duplicate_configuration(self):
        for arguments in (
            {"configurations": (), "candidate_selections": (self.selection,)},
            {"configurations": (object(),), "candidate_selections": (self.selection,)},
            {"configurations": (self.config,), "candidate_selections": ()},
            {"configurations": (self.config,), "candidate_selections": (object(),)},
            {
                "configurations": (self.config,),
                "candidate_selections": (self.selection,),
                "installed_selections": (object(),),
            },
        ):
            with self.subTest(arguments=arguments), self.assertRaises(TypeError):
                ReleasedManagedProductRouteBuilder.build(**arguments)
        with self.assertRaisesRegex(ValueError, "deployment identities"):
            ReleasedManagedProductRouteBuilder.build(
                configurations=(self.config, self.config),
                candidate_selections=(self.selection,),
            )

    def test_routes_reject_shared_ep_consumer_scope_across_deployments(self):
        other = self.isolated_other_configuration()
        other = replace(
            other,
            pairing_binding=replace(
                other.pairing_binding,
                consumer_id=self.config.pairing_binding.consumer_id,
                project_id=self.config.pairing_binding.project_id,
            ),
        )
        with self.assertRaisesRegex(ValueError, "scope is shared"):
            ReleasedManagedProductRouteBuilder.build(
                configurations=(self.config, other),
                candidate_selections=(self.selection,),
            )

    def test_distinct_deployments_have_isolated_product_routes(self):
        other = self.isolated_other_configuration()
        routes = ReleasedManagedProductRouteBuilder.build(
            configurations=(self.config, other),
            candidate_selections=(self.selection,),
        )
        self.assertEqual(set(routes), {"production", "production-other"})
        self.assertEqual(routes["production-other"].forge_instance_id, "forge-other")
        self.assertEqual(routes["production-other"].engineering_platform_instance_id, "ep-other")

    def test_duplicate_product_instance_ids_fail_before_route_construction(self):
        other = self.isolated_other_configuration()
        for altered in (
            replace(other, forge_target=replace(
                other.forge_target, instance_id="forge-prod"
            )),
            replace(other, engineering_platform_target=replace(
                other.engineering_platform_target, instance_id="ep-prod"
            ), pairing_binding=replace(
                other.pairing_binding, expected_ep_instance_id="ep-prod"
            )),
        ):
            with self.subTest(altered=altered.deployment_id), self.assertRaisesRegex(
                ValueError, "claimed by multiple deployments"
            ):
                ReleasedManagedProductRouteBuilder.build(
                    configurations=(self.config, altered),
                    candidate_selections=(self.selection,),
                )

        single_forge = ReleasedManagedSingleProductRouteConfiguration(
            deployment_id="forge-single-other",
            component_identity="forge-runtime",
            executable=self.config.forge_executable,
            target=replace(
                self.config.forge_target,
                data_root=self.root / "forge/instances/forge-single-other",
                service_account="_forge_single_other",
                bind_port=8880,
                api_credential_file=self.root / "forge/credentials/api-single-other",
            ),
            installed_artifact=self.components["forge-runtime"].artifact,
            staged_artifacts={
                self.components["forge-runtime"].artifact.digest:
                    self.root / "staged/forge-runtime.whl"
            },
        )
        with self.assertRaisesRegex(ValueError, "claimed by multiple deployments"):
            ReleasedManagedProductRouteBuilder.build_from_manifests(
                configurations=(self.config, single_forge),
                candidate_manifests=(self.selection.manifest,),
            )

    def test_forge_state_aliases_and_shared_os_authority_fail_closed(self):
        other = self.isolated_other_configuration()
        cases = (
            (replace(other, forge_target=replace(
                other.forge_target, data_root=self.config.forge_target.data_root
            )), "data roots overlap"),
            (replace(other, forge_target=replace(
                other.forge_target,
                data_root=self.config.forge_target.data_root / "nested"
            )), "data roots overlap"),
            (replace(other, forge_target=replace(
                other.forge_target,
                api_credential_file=self.config.forge_target.api_credential_file,
            )), "credential path is shared"),
            (replace(other, forge_target=replace(
                other.forge_target, service_account=self.config.forge_target.service_account,
            )), "OS authority is shared"),
            (replace(
                other,
                engineering_platform_target=replace(
                    other.engineering_platform_target,
                    bind_port=self.config.engineering_platform_target.bind_port,
                ),
                pairing_binding=replace(
                    other.pairing_binding, endpoint="http://127.0.0.1:8876"
                ),
            ), "OS authority is shared"),
        )
        for altered, error in cases:
            with self.subTest(error=error), self.assertRaisesRegex(ValueError, error):
                ReleasedManagedProductRouteBuilder.build(
                    configurations=(self.config, altered),
                    candidate_selections=(self.selection,),
                )

    def test_builds_exact_forge_only_route_without_ep_or_pairing_authority(self):
        selection = verified_forge_ep_selection(
            self.context, "forge-only", ("forge-runtime",)
        )
        artifact = selection.manifest.components[0].artifact
        config = ReleasedManagedSingleProductRouteConfiguration(
            deployment_id="forge-only-deployment",
            component_identity="forge-runtime",
            executable=self.config.forge_executable,
            target=self.config.forge_target,
            installed_artifact=artifact,
            staged_artifacts={artifact.digest: self.root / "staged/forge.whl"},
            forge_lifecycle_executable=self.root / "venvs/forge/bin/forge",
            forge_uninstall_binding=ForgeUninstallBinding("forge-prod", "installation-1"),
        )
        routes = ReleasedManagedProductRouteBuilder.build_from_manifests(
            configurations=(config,), candidate_manifests=(selection.manifest,),
        )
        route = routes[config.deployment_id]
        self.assertEqual(set(route.adapters), {"forge-runtime"})
        self.assertEqual(route.forge_instance_id, "forge-prod")
        self.assertIsNone(route.engineering_platform_instance_id)
        self.assertIsNone(route.pairing_executor)
        self.assertIsNone(route.ep_consumer_revoker)
        self.assertEqual(route.adapters["forge-runtime"].removal_support(), "SUPPORTED")

        with self.assertRaisesRegex(ValueError, "catalog authority"):
            ReleasedManagedProductRouteBuilder.build_from_manifests(
                configurations=(replace(config, staged_artifacts={
                    **config.staged_artifacts,
                    self.components["engineering-platform-server"].artifact.digest:
                        self.root / "staged/ep.whl",
                }),),
                candidate_manifests=(selection.manifest,),
            )
        with self.assertRaisesRegex(ValueError, "different instance"):
            replace(config, forge_uninstall_binding=ForgeUninstallBinding(
                "forge-other", "installation-1"
            ))

    def test_builds_exact_ep_only_route_without_forge_or_pairing_authority(self):
        selection = verified_forge_ep_selection(
            self.context, "ep-only", ("engineering-platform-server",)
        )
        artifact = selection.manifest.components[0].artifact
        config = ReleasedManagedSingleProductRouteConfiguration(
            deployment_id="ep-only-deployment",
            component_identity="engineering-platform-server",
            executable=self.config.engineering_platform_provisioner,
            target=self.config.engineering_platform_target,
            installed_artifact=artifact,
            staged_artifacts={artifact.digest: self.root / "staged/ep.whl"},
            engineering_platform_product_root=self.config.engineering_platform_product_root,
        )
        route = ReleasedManagedProductRouteBuilder.build(
            configurations=(config,), candidate_selections=(selection,),
        )[config.deployment_id]
        self.assertEqual(set(route.adapters), {"engineering-platform-server"})
        self.assertIsNone(route.forge_instance_id)
        self.assertEqual(route.engineering_platform_instance_id, "ep-prod")
        self.assertIsNone(route.pairing_executor)
        with self.assertRaisesRegex(ValueError, "Forge lifecycle"):
            replace(config, forge_lifecycle_executable=self.config.forge_executable)
        with self.assertRaisesRegex(TypeError, "exact EP target"):
            replace(config, target=self.config.forge_target)


if __name__ == "__main__":
    unittest.main()
