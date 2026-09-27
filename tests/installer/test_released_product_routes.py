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
from forge_platform.forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding,
    ForgeEPProductPairingExecutor,
)
from forge_platform.forge_server_adapter import ForgeServerProductAdapter, ForgeServerTarget, ForgeUninstallBinding
from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperBuilder,
)
from forge_platform.released_product_routes import (
    ReleasedManagedProductRouteBuilder,
    ReleasedManagedProductRouteConfiguration,
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


FORGE_DIGEST = "sha256:" + "4" * 64


def verified_forge_ep_selection(context, composition_id="forge-ep-current"):
    payload = manifest_payload(composition_id=composition_id)
    ep = payload["components"][0]
    forge = json.loads(json.dumps(ep))
    forge["identity"] = "forge-runtime"
    forge["artifact"] = {
        "version": "2.7.34",
        "source_revision": "f" * 40,
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
        self.assertEqual(route.forge_instance_id, "forge-prod")
        self.assertEqual(route.engineering_platform_instance_id, "ep-prod")
        with self.assertRaises(TypeError):
            routes["other"] = route

    def test_lifecycle_executable_is_fixed_by_helper_route(self):
        lifecycle = self.root / "lifecycle/forge-2.7.35/bin/forge"
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


if __name__ == "__main__":
    unittest.main()
