#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.engineering_platform_system_adapter import EPSystemInstanceTarget
from forge_platform.engineering_platform_system_adapter import ProductCommandResult
from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingBinding
from forge_platform.forge_server_adapter import ForgeServerTarget, ForgeUninstallBinding
from forge_platform.installer_product_worker import (
    InstallerProductWorkerUnavailable, execute_preserved_lifecycle_request, run,
)
from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_install_flow import ManagedForgeEPInstallationCoordinator
from forge_platform.managed_preserved_lifecycle_dispatch import (
    ManagedPreservedLifecycleDispatcher, ManagedPreservedLifecycleDispatchError,
)
from forge_platform.managed_preserved_lifecycle_request import (
    decode_native_preserved_lifecycle_receipt,
    decode_native_preserved_lifecycle_request,
)
from forge_platform.managed_product_operation_dispatch import ManagedProductOperationDispatcher
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService,
    ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from forge_platform.released_product_routes import ReleasedManagedProductRouteConfiguration
from tests.installer import test_managed_preserve_execution as preserve_helpers
from tests.installer.test_managed_preserved_lifecycle_plan import _fixture
from tests.installer.test_managed_preserved_lifecycle_request import _request
from tests.installer.test_managed_preserved_lifecycle_proposal import _wire
from tests.installer.test_managed_preserved_product_adapters import FakeRunner, _ep_evidence
from tests.installer.test_managed_preserved_lifecycle_proposal import _intent
from forge_platform.managed_preserved_lifecycle_proposal import prepare_native_preserved_lifecycle_review
from forge_platform.product_preserved_lifecycle import EP_CONTRACT
from hashlib import sha256
import json
from tests.installer.test_managed_product_operation_admission import installer_release


class Resolver:
    def resolve(self, _request):
        raise AssertionError("ordinary product route was not requested")


class ManagedPreservedLifecycleDispatchTests(unittest.TestCase):
    @staticmethod
    def _config(root, manifest):
        artifacts = {item.identity: item.artifact for item in manifest.components}
        forge_target = ForgeServerTarget(
            "forge-a", root / "instances/forge-a", root / "instances",
            "_forge", 8765, root / "credentials/forge-a.token",
        )
        return ReleasedManagedProductRouteConfiguration(
            deployment_id="reviewed-pair",
            forge_executable=root / "venvs/forge/bin/forge",
            forge_target=forge_target,
            forge_installed_artifact=artifacts["forge-runtime"],
            engineering_platform_installed_artifact=artifacts["engineering-platform-server"],
            engineering_platform_provisioner=root / "venvs/ep/bin/provisioner",
            engineering_platform_product_root=root / "products/ep",
            engineering_platform_target=EPSystemInstanceTarget("ep-a", "EP A", "_ep", 8766),
            staged_artifacts={
                artifact.digest: root / "staged" / f"{component}.whl"
                for component, artifact in artifacts.items()
            },
            pairing_binding=ForgeEPProductPairingBinding(
                "ep-primary", "http://127.0.0.1:8766", "ep-a", "forge-consumer",
                "engineering-platform", "forge-project", "forge-repository",
                "pcvantol:forge", "keychain://forge.ep/consumer", "installer", True,
            ),
            forge_lifecycle_executable=root / "venvs/forge/bin/forge",
            forge_uninstall_binding=ForgeUninstallBinding("forge-a", "Install-A"),
            launch_daemons_directory=root / "daemons",
        )

    def _service(self, root):
        manifest, active, _ = _fixture()
        registry = ManagedDeploymentRegistry(root / "registry")
        registry.create(active)
        currency = preserve_helpers.Currency()
        coordinator = ManagedForgeEPInstallationCoordinator(
            operations_root=root / "operations", component_operations_root=root / "components",
            registry=registry, currency_guard=currency,
        )
        config = self._config(root, manifest)
        preserved = ManagedPreservedLifecycleDispatcher(
            coordinator=coordinator, configurations=(config,),
            expected_owner_uid=os.getuid(),
        )
        resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=installer_release(),
            manifests=(manifest,), installed_manifests=(manifest,),
        )
        service = ManagedProductOperationHelperService(
            authority_resolver=resolver,
            dispatcher=ManagedProductOperationDispatcher(
                coordinator=coordinator, resolver=Resolver(),
            ),
            preserved_dispatcher=preserved,
        )
        return manifest, registry, currency, config, service

    def test_released_worker_executes_exact_review_and_replays_without_product_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, currency, _, service = self._service(root)
            request_bytes = _wire(_request(manifest, registry))
            request = decode_native_preserved_lifecycle_request(request_bytes)
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_adapter(root)[1]
            supervisor = preserve_helpers.Supervisor()
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=supervisor),
            ):
                response = execute_preserved_lifecycle_request(
                    request_bytes, service_loader=lambda: service,
                )
                receipt = decode_native_preserved_lifecycle_receipt(response, request=request)
                self.assertEqual(receipt["registry_revision"], 2)
                self.assertEqual(registry.load("reviewed-pair").preserved_by_component["forge-runtime"].instance_id, "forge-a")
                self.assertEqual(execute_preserved_lifecycle_request(
                    request_bytes, service_loader=lambda: service,
                ), response)
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual([call[0] for call in supervisor.calls].count("remove"), 1)
            self.assertEqual(len(currency.calls), 4)

    def test_worker_routes_schema_and_rejects_forged_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, _, _, service = self._service(root)
            request_bytes = _wire(_request(manifest, registry))
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_adapter(root)[1]
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=preserve_helpers.Supervisor()),
            ):
                output = io.BytesIO()
                self.assertEqual(run(
                    io.BytesIO(request_bytes), output, service_loader=lambda: service,
                ), 0)
                self.assertEqual(decode_native_preserved_lifecycle_receipt(
                    output.getvalue(), request=decode_native_preserved_lifecycle_request(request_bytes),
                )["state"], "COMPLETE")
            with patch.object(service, "execute_preserved_lifecycle", return_value=b"{}"):
                with self.assertRaises(InstallerProductWorkerUnavailable):
                    execute_preserved_lifecycle_request(
                        request_bytes, service_loader=lambda: service,
                    )

    def test_foreign_route_and_stale_composition_fail_before_service_or_product(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, _, config, service = self._service(root)
            request = decode_native_preserved_lifecycle_request(_wire(_request(manifest, registry)))
            foreign_target = replace(config.forge_target, instance_id="forge-b",
                                     data_root=root / "instances/forge-b")
            foreign = replace(config, forge_target=foreign_target,
                              forge_uninstall_binding=ForgeUninstallBinding("forge-b", "Install-B"))
            dispatcher = ManagedPreservedLifecycleDispatcher(
                coordinator=service.dispatcher.coordinator,
                configurations=(foreign,), expected_owner_uid=os.getuid(),
            )
            with self.assertRaisesRegex(ManagedPreservedLifecycleDispatchError, "another instance"):
                dispatcher.dispatch(request, installed_manifest=manifest)
            with self.assertRaisesRegex(ManagedPreservedLifecycleDispatchError, "release changed"):
                dispatcher.dispatch(request, installed_manifest=replace(
                    manifest, manifest_digest="sha256:" + "b" * 64,
                ))
            service.preserved_dispatcher = None
            with self.assertRaises(ManagedProductOperationServiceError):
                service.execute_preserved_lifecycle(_wire(_request(manifest, registry)))

    def test_ep_preserve_uses_paired_route_and_product_owned_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, currency, _, service = self._service(root)
            intent = _intent(manifest)
            intent["component"] = "engineering-platform-server"
            intent["instance_id"] = "ep-a"
            intent["intent_fingerprint"] = sha256(_wire({
                key: value for key, value in intent.items() if key != "intent_fingerprint"
            })).hexdigest()
            proposal = json.loads(prepare_native_preserved_lifecycle_review(
                _wire(intent), installed_manifest=manifest, registry=registry,
                current_installer_release=installer_release(),
            ))
            request = {
                "schema": "forge-platform.native-preserved-lifecycle-request/v1",
                "intent": intent, "proposal": proposal,
            }
            request["request_fingerprint"] = sha256(_wire(request)).hexdigest()
            receipt, status = _ep_evidence("PRESERVE", "preserve-a", "ep-a")
            outer = {"contract": EP_CONTRACT, "result": "COMPLETE", "instance_id": "ep-a", "receipt": receipt}
            runner = FakeRunner(ProductCommandResult, (
                (0, _wire(outer).decode()), (0, _wire(status).decode()),
            ))
            with patch(
                "forge_platform.managed_preserved_product_adapters.SubprocessProductCommandRunner",
                return_value=runner,
            ):
                response = service.execute_preserved_lifecycle(_wire(request))
            self.assertEqual(decode_native_preserved_lifecycle_receipt(
                response, request=decode_native_preserved_lifecycle_request(_wire(request)),
            )["registry_revision"], 2)
            current = registry.load("reviewed-pair")
            self.assertEqual(current.preserved_by_component["engineering-platform-server"].instance_id, "ep-a")
            self.assertEqual(current.active_by_component["forge-runtime"].instance_id, "forge-a")
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual(len(currency.calls), 2)


if __name__ == "__main__":
    unittest.main()
