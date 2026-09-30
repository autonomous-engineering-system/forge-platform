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
    InstallerProductWorkerUnavailable, execute_preserved_lifecycle_request,
    read_terminal_preserve_recovery_request, run,
)
from forge_platform.managed_preserve_recovery import (
    ManagedPreserveRecoveryError, NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA,
    decode_native_preserve_recovery_request,
    decode_native_preserve_recovery_receipt,
    encode_native_preserve_recovery_receipt,
)
from forge_platform.managed_preserve_execution import ManagedPreserveExecutionRecord
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
from tests.installer import test_managed_deployments as deployment_helpers
from tests.installer.test_managed_preserved_lifecycle_request import _request
from tests.installer.test_managed_preserved_lifecycle_proposal import _wire
from tests.installer.test_managed_preserved_product_adapters import FakeRunner, _ep_evidence
from tests.installer.test_managed_preserved_lifecycle_proposal import _intent
from forge_platform.managed_preserved_lifecycle_proposal import prepare_native_preserved_lifecycle_review
from forge_platform.product_preserved_lifecycle import EP_CONTRACT
from hashlib import sha256
import json
from tests.installer.test_managed_product_operation_admission import installer_release
from tests.installer.test_product_preserved_lifecycle import FORGE_COMPONENT, _REQUEST


class Resolver:
    def resolve(self, _request):
        raise AssertionError("ordinary product route was not requested")


class ManagedPreservedLifecycleDispatchTests(unittest.TestCase):
    @staticmethod
    def _recovery_request(manifest):
        payload = {
            "schema": NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA,
            "intent": _intent(manifest),
        }
        payload["request_fingerprint"] = sha256(_wire(payload)).hexdigest()
        return _wire(payload)

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

    def _service(self, root, *, paired=False):
        manifest, active, _ = _fixture()
        if not paired:
            active = replace(active, peer_binding=None)
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

    def test_paired_worker_route_fails_before_journal_service_or_product_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, currency, _, service = self._service(root, paired=True)
            request_bytes = _wire(_request(manifest, registry))
            supervisor = preserve_helpers.Supervisor()
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_adapter(root)[1]
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=supervisor),
                self.assertRaises(ManagedProductOperationServiceError) as failure,
            ):
                service.execute_preserved_lifecycle(request_bytes)
            self.assertIsInstance(failure.exception.__cause__, ManagedPreservedLifecycleDispatchError)
            self.assertIn("consumer revocation", str(failure.exception.__cause__))
            self.assertEqual(registry.load("reviewed-pair").revision, 1)
            self.assertFalse((root / "operations").exists())
            self.assertEqual(currency.calls, [])
            self.assertEqual(supervisor.calls, [])
            self.assertEqual(runner.calls, [])

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

    def test_worker_reads_exact_terminal_recovery_without_repeating_product_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, _, _, service = self._service(root)
            mutation = _wire(_request(manifest, registry))
            recovery = self._recovery_request(manifest)
            decoded = decode_native_preserve_recovery_request(recovery)
            with self.assertRaises(ManagedProductOperationServiceError):
                service.read_terminal_preserve_recovery(recovery)
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_adapter(root)[1]
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=preserve_helpers.Supervisor()),
            ):
                service.execute_preserved_lifecycle(mutation)
            current = registry.load("reviewed-pair")
            output = io.BytesIO()
            self.assertEqual(run(
                io.BytesIO(recovery), output, service_loader=lambda: service,
            ), 0)
            terminal = decode_native_preserve_recovery_receipt(
                output.getvalue(), request=decoded,
            )
            self.assertEqual(terminal.state, "COMPLETE")
            self.assertEqual(terminal.registry_revision, current.revision)
            self.assertEqual(terminal.receipt_digest,
                             current.preserved_by_component["forge-runtime"].preserve_receipt_digest)
            self.assertEqual(read_terminal_preserve_recovery_request(
                recovery, service_loader=lambda: service,
            ), output.getvalue())
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual(registry.load("reviewed-pair"), current)
            with patch.object(service, "read_terminal_preserve_recovery", return_value=b"{}"):
                with self.assertRaises(InstallerProductWorkerUnavailable):
                    read_terminal_preserve_recovery_request(
                        recovery, service_loader=lambda: service,
                    )

    def test_recovery_codec_rejects_substitution_noncanonical_and_nonterminal(self):
        manifest, _, _ = _fixture()
        request_bytes = self._recovery_request(manifest)
        request = decode_native_preserve_recovery_request(request_bytes)
        record = ManagedPreserveExecutionRecord(
            request.intent.operation_id, request.intent.deployment_id,
            "sha256:" + "a" * 64, request.intent.component,
            request.intent.instance_id, "COMPLETE",
            "sha256:" + "b" * 64, 2,
        )
        receipt = encode_native_preserve_recovery_receipt(request, record)
        self.assertEqual(decode_native_preserve_recovery_receipt(
            receipt, request=request,
        ), record)
        with self.assertRaises(ManagedPreserveRecoveryError):
            decode_native_preserve_recovery_request(request_bytes + b" ")
        with self.assertRaises(ManagedPreserveRecoveryError):
            decode_native_preserve_recovery_request(request_bytes.replace(
                b'"request_fingerprint":', b'"request_fingerprint":"bad","request_fingerprint":', 1,
            ))
        with self.assertRaises(ManagedPreserveRecoveryError):
            decode_native_preserve_recovery_receipt(receipt + b" ", request=request)
        with self.assertRaises(ManagedPreserveRecoveryError):
            decode_native_preserve_recovery_receipt(receipt, request=object())
        with self.assertRaises(ManagedPreserveRecoveryError):
            encode_native_preserve_recovery_receipt(
                request, replace(record, state="PREPARED"),
            )
        with self.assertRaises(ManagedPreserveRecoveryError):
            decode_native_preserve_recovery_receipt(_wire({
                **json.loads(receipt), "record": {
                    **json.loads(receipt)["record"], "receipt_digest": "sha256:BAD",
                },
            }), request=request)
        altered_intent = _intent(manifest)
        altered_intent["operation"] = "RESTORE"
        altered_intent["intent_fingerprint"] = sha256(_wire({
            key: value for key, value in altered_intent.items()
            if key != "intent_fingerprint"
        })).hexdigest()
        altered = {"schema": NATIVE_PRESERVE_RECOVERY_REQUEST_SCHEMA,
                   "intent": altered_intent}
        altered["request_fingerprint"] = sha256(_wire(altered)).hexdigest()
        with self.assertRaises(ManagedPreserveRecoveryError):
            decode_native_preserve_recovery_request(_wire(altered))

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

    def test_confirmed_purge_uses_same_worker_and_replays_exact_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, currency, _, service = self._service(root)
            request_bytes = _wire(_request(manifest, registry, "PURGE", "forge-a"))
            request = decode_native_preserved_lifecycle_request(request_bytes)
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_purge_adapter(root)[1]
            supervisor = preserve_helpers.Supervisor()
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=supervisor),
            ):
                output = io.BytesIO()
                self.assertEqual(run(
                    io.BytesIO(request_bytes), output, service_loader=lambda: service,
                ), 0)
                receipt = decode_native_preserved_lifecycle_receipt(
                    output.getvalue(), request=request,
                )
                self.assertEqual(receipt["state"], "COMPLETE")
                self.assertEqual(receipt["instance_id"], "forge-a")
                self.assertEqual(execute_preserved_lifecycle_request(
                    request_bytes, service_loader=lambda: service,
                ), output.getvalue())
            current = registry.load("reviewed-pair")
            self.assertEqual(set(current.active_by_component), {"engineering-platform-server"})
            self.assertEqual(len(runner.calls), 2)
            self.assertEqual([call[0] for call in supervisor.calls].count("remove"), 1)
            self.assertTrue(all(call["mutation"] == "PURGE" for call in currency.calls))

    def test_paired_purge_is_rejected_before_product_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, currency, _, service = self._service(root, paired=True)
            request_bytes = _wire(_request(manifest, registry, "PURGE", "forge-a"))
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_purge_adapter(root)[1]
            supervisor = preserve_helpers.Supervisor()
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=supervisor),
                self.assertRaises(ManagedProductOperationServiceError),
            ):
                service.execute_preserved_lifecycle(request_bytes)
            self.assertEqual(runner.calls, [])
            self.assertEqual(supervisor.calls, [])
            self.assertEqual(currency.calls, [])

    def test_final_component_purge_worker_receipt_replays_after_registry_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, _, _, service = self._service(root)
            current = registry.load("reviewed-pair")
            registry.remove("reviewed-pair", expected_revision=current.revision)
            registry.create(replace(
                current,
                components=(current.active_by_component["forge-runtime"],),
            ))
            request_bytes = _wire(_request(manifest, registry, "PURGE", "forge-a"))
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_purge_adapter(root)[1]
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=preserve_helpers.Supervisor()),
            ):
                receipt = execute_preserved_lifecycle_request(
                    request_bytes, service_loader=lambda: service,
                )
                self.assertIsNone(registry.load("reviewed-pair"))
                self.assertEqual(execute_preserved_lifecycle_request(
                    request_bytes, service_loader=lambda: service,
                ), receipt)
            self.assertEqual(len(runner.calls), 2)

    def test_preserved_forge_installation_id_must_match_sealed_route(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            manifest, registry, _, _, service = self._service(root)
            receipt, status = deployment_helpers.ManagedDeploymentTests._preserve_evidence(
                FORGE_COMPONENT, "forge-a", "preserve-a"
            )
            artifact = next(
                item.artifact for item in manifest.components
                if item.identity == FORGE_COMPONENT
            )
            registry.commit_preserved(
                deployment_id="reviewed-pair", expected_revision=1,
                component=FORGE_COMPONENT, instance_id="forge-a",
                operation_id="preserve-a", artifact=artifact,
                installed_manifest=manifest, request_digest=_REQUEST,
                receipt=receipt, status=status,
            )
            request_bytes = _wire(_request(manifest, registry, "PURGE", "forge-a"))
            runner = preserve_helpers.ManagedPreserveExecutionTests._forge_purge_adapter(root)[1]
            supervisor = preserve_helpers.Supervisor()
            with (
                patch("forge_platform.managed_preserved_product_adapters.SubprocessForgeCommandRunner", return_value=runner),
                patch("forge_platform.managed_preserved_lifecycle_dispatch.MacOSForgeLaunchDaemonSupervisor", return_value=supervisor),
                self.assertRaises(ManagedProductOperationServiceError) as failure,
            ):
                service.execute_preserved_lifecycle(request_bytes)
            self.assertIsInstance(failure.exception.__cause__, ManagedPreservedLifecycleDispatchError)
            self.assertEqual(runner.calls, [])
            self.assertEqual(supervisor.calls, [])

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

    def test_ep_preserve_uses_unpaired_route_and_product_owned_service(self):
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
