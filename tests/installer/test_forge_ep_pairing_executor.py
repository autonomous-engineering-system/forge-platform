import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    EngineeringPlatformAdapterError,
    EngineeringPlatformSystemProvisionerAdapter,
    ProductCommandResult,
)
from forge_platform.forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding,
    ForgeEPProductPairingError,
    ForgeEPProductPairingExecutor,
)
from forge_platform.forge_server_adapter import (
    ForgeCommandResult, ForgeServerAdapterError,
    ForgeServerProductAdapter,
    ForgeServerTarget,
)
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedPeerBinding,
)


ARTIFACT = QualifiedArtifact(
    "1.2.3",
    "a" * 40,
    "https://example.invalid/release.whl",
    "sha256:" + "b" * 64,
    "qualification:release",
)
FORGE_239 = QualifiedArtifact(
    "2.7.39", "ebc43dc12da27353f85c991a26da9852aa790f05",
    "released-wheel",
    "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
    "release-complete",
)


class ForgeRunner:
    def __init__(self, binding):
        self.binding = binding
        self.calls = []
        self.configuration_override = {}
        self.preflight_override = {}

    def run(self, argv):
        self.calls.append(tuple(argv))
        if argv[-2:] == ("execution-host", "preflight"):
            payload = {
                "status": "PASS",
                "configuration_status": "CONFIGURED",
                "peer_instance_consistency": "PASS",
                "compatibility": "PASS",
                "authenticated_consumer_identity": self.binding.consumer_id,
                "project_repository_scope": "PASS",
                "mutation_authority": "SUBMISSION_AUTHORIZED",
                "declaration": {
                    "instance": {"id": self.binding.expected_ep_instance_id},
                    "authentication": {
                        "consumer_id": self.binding.consumer_id,
                        "project_id": self.binding.project_id,
                        "repository_id": self.binding.repository_id,
                    },
                },
            }
            payload.update(self.preflight_override)
        else:
            payload = {
                "status": "CONFIGURED",
                "configuration": {
                    "binding_id": self.binding.binding_id,
                    "endpoint": self.binding.endpoint,
                    "expected_ep_instance_id": self.binding.expected_ep_instance_id,
                    "ep_consumer_id": self.binding.consumer_id,
                    "execution_host_id": self.binding.host_id,
                    "ep_project_id": self.binding.project_id,
                    "ep_repository_id": self.binding.repository_id,
                    "repository_identity": self.binding.repository_identity,
                    "credential_reference": self.binding.credential_reference,
                    "allow_loopback_http": self.binding.allow_loopback_http,
                },
            }
            payload["configuration"].update(self.configuration_override)
        import json

        return ForgeCommandResult(0, json.dumps(payload), "")


class EPRunner:
    def __init__(self):
        self.ready = True
        self.calls = []
        self.provider_override = {}

    def run(self, argv):
        self.calls.append(tuple(argv))
        descriptor = {
            "instance_id": "ep-prod",
            "service_label": "com.example.ep",
            "selected_runtime": {
                "version": ARTIFACT.version,
                "source_revision": ARTIFACT.source_revision,
                "artifact_digest": ARTIFACT.digest,
                "interpreter": "/opt/ep/python",
            },
        }
        if "inventory" in argv:
            payload = {"state": "READY", "instances": [descriptor]}
        else:
            providers = {
                provider: {
                    "provider": provider,
                    "instance_id": "ep-prod",
                    "state": "READY",
                    "executable": "/opt/ep/providers/" + provider + "/runtime/bin/" + (
                        "codex" if provider == "codex" else "gh"
                    ),
                    "executable_sha256": "sha256:" + ("d" if provider == "codex" else "e") * 64,
                    "version": "1.0.0",
                    "home": "/opt/ep/providers/" + provider + "/home",
                    "credential_scope": "COMPONENT_INSTANCE",
                    "authentication": {"state": "READY", "reference": provider + "-owned-reference"},
                    "cold_boot_ready": True,
                }
                for provider in ("codex", "github")
            }
            providers["github"].update(self.provider_override)
            payload = {
                "contract": "engineering-platform.system-provisioner/v1",
                "state": "READY" if self.ready else "DEGRADED",
                "ready": self.ready,
                "descriptor": descriptor,
                "providers": providers,
            }
        import json

        return ProductCommandResult(0, json.dumps(payload), "")


class Supervisor:
    def register(self, *args):
        return {}

    def start(self, *args):
        return {}

    def stop(self, *args):
        return {}

    def remove(self, *args):
        return {}

    def loaded(self, *args):
        return True


class ForgeEPProductPairingExecutorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name).resolve()
        self.binding = ForgeEPProductPairingBinding(
            "ep-primary",
            "http://127.0.0.1:8876/",
            "ep-prod",
            "forge-consumer",
            "engineering-platform",
            "forge-project",
            "forge-repository",
            "pcvantol:forge",
            "keychain://forge.ep/consumer",
            "installer",
            True,
        )
        self.forge_runner = ForgeRunner(self.binding)
        self.ep_runner = EPRunner()
        self.forge = ForgeServerProductAdapter(
            forge_executable=root / "forge-runtime/bin/forge",
            target=ForgeServerTarget(
                "forge-prod",
                root / "forge-instances/production",
                root / "forge-instances",
                "_forge_prod",
                8875,
                root / "credentials/forge-api",
            ),
            installed_artifact=ARTIFACT,
            staged_artifacts={},
            supervisor=Supervisor(),
            runner=self.forge_runner,
        )
        self.ep = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=root / "ep/bin/engineering-platform-system-provisioner",
            product_root=root / "ep",
            target=EPSystemInstanceTarget("ep-prod", "Production", "_ep_prod", 8876),
            staged_artifacts={ARTIFACT.digest: root / "staged/ep.whl"},
            runner=self.ep_runner,
        )
        self.deployment = ManagedDeployment(
            "production",
            1,
            "Production",
            (
                ManagedComponentBinding("forge-runtime", "forge-prod", "receipt:forge"),
                ManagedComponentBinding(
                    "engineering-platform-server", "ep-prod", "receipt:ep"
                ),
            ),
        )
        self.forge_request = self.request("forge-runtime", "forge-prod")
        self.ep_request = self.request("engineering-platform-server", "ep-prod")
        self.executor = ForgeEPProductPairingExecutor(self.binding)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def request(component, instance):
        return ComponentOperationRequest(
            f"read-{component}", component, "repair", ARTIFACT, instance, "server", {}
        )

    def pair(self):
        return self.executor.pair(
            operation_id="managed-product-operation",
            deployment=self.deployment,
            forge_request=self.forge_request,
            ep_request=self.ep_request,
            forge_adapter=self.forge,
            ep_adapter=self.ep,
        )

    def test_configure_preflight_and_independent_ep_readback_are_bound(self):
        evidence = self.pair()
        self.assertEqual(evidence.forge_instance_id, "forge-prod")
        self.assertEqual(evidence.ep_instance_id, "ep-prod")
        self.assertRegex(
            evidence.forge_configuration_reference,
            r"^forge-peer-configuration:sha256:[0-9a-f]{64}$",
        )
        self.assertRegex(
            evidence.forge_preflight_reference,
            r"^forge-peer-preflight:sha256:[0-9a-f]{64}$",
        )
        self.assertTrue(evidence.ep_readiness_reference.startswith("ep-status:sha256:"))
        joined = [" ".join(call) for call in self.forge_runner.calls]
        self.assertIn("execution-host configure", joined[0])
        self.assertIn("execution-host preflight", joined[1])
        self.assertEqual(len(self.ep_runner.calls), 2)

    def test_configuration_readback_drift_fails_before_preflight(self):
        self.forge_runner.configuration_override["expected_ep_instance_id"] = "other"
        with self.assertRaisesRegex(ForgeEPProductPairingError, "configuration readback"):
            self.pair()
        self.assertEqual(len(self.forge_runner.calls), 1)
        self.assertEqual(self.ep_runner.calls, [])

    def test_authenticated_preflight_must_bind_exact_scope(self):
        self.forge_runner.preflight_override["mutation_authority"] = "NOT_VERIFIED"
        with self.assertRaisesRegex(ForgeEPProductPairingError, "preflight did not pass"):
            self.pair()
        self.assertEqual(self.ep_runner.calls, [])

    def test_ep_must_read_back_exact_artifact_healthy(self):
        self.ep_runner.ready = False
        with self.assertRaisesRegex(ForgeEPProductPairingError, "readiness did not pass"):
            self.pair()

    def test_pairing_rejects_wrong_ep_provider_instance(self):
        self.ep_runner.provider_override["instance_id"] = "ep-other"
        with self.assertRaisesRegex(EngineeringPlatformAdapterError, "provider context does not match"):
            self.pair()

    def test_route_and_concrete_adapter_types_are_enforced(self):
        wrong_ep = self.request("engineering-platform-server", "ep-other")
        with self.assertRaisesRegex(ForgeEPProductPairingError, "exact product instances"):
            self.executor.pair(
                operation_id="operation",
                deployment=self.deployment,
                forge_request=self.forge_request,
                ep_request=wrong_ep,
                forge_adapter=self.forge,
                ep_adapter=self.ep,
            )
        for field, value, error in (
            ("deployment", object(), TypeError),
            ("forge_request", object(), TypeError),
            ("forge_adapter", object(), TypeError),
            ("ep_adapter", object(), TypeError),
        ):
            arguments = {
                "operation_id": "operation",
                "deployment": self.deployment,
                "forge_request": self.forge_request,
                "ep_request": self.ep_request,
                "forge_adapter": self.forge,
                "ep_adapter": self.ep,
            }
            arguments[field] = value
            with self.subTest(field=field), self.assertRaises(error):
                self.executor.pair(**arguments)

    def test_binding_rejects_unsafe_identity_endpoint_and_reference(self):
        values = list(self.binding.__dict__.values())
        for index, replacement, message in (
            (0, "bad binding", "binding_id"),
            (1, "http://example.com", "loopback"),
            (8, "https://not-a-keychain", "credential reference"),
            (10, "yes", "loopback setting"),
        ):
            candidate = values.copy()
            candidate[index] = replacement
            with self.subTest(index=index), self.assertRaisesRegex(ValueError, message):
                ForgeEPProductPairingBinding(*candidate)
        with self.assertRaises(TypeError):
            ForgeEPProductPairingExecutor(object())

    def replacement(self, **overrides):
        self.forge.installed_artifact = FORGE_239
        reviewed = replace(
            self.deployment,
            peer_binding=ManagedPeerBinding("forge-prod", "ep-prod", "receipt:old-peer"),
        )
        arguments = {
            "operation_id": "repair-pairing", "deployment": reviewed,
            "forge_request": self.forge_request, "ep_request": self.ep_request,
            "forge_adapter": self.forge, "ep_adapter": self.ep,
            "old_binding_id": "old-binding", "old_consumer_id": "old-consumer",
            "detach_operation_id": "detach-old", "detach_revision": 3,
            "detach_configuration_digest": "sha256:" + "a" * 64,
            "detach_operator_id": "installer",
        }
        arguments.update(overrides)
        return arguments

    def test_guarded_replacement_consumes_exact_detach_status_and_product_flags(self):
        arguments = self.replacement()
        status = {
            "current_peer_status": "DETACHED",
            "receipt": {
                "next_configuration_revision": 4,
                "receipt_digest": "sha256:" + "b" * 64,
            },
        }
        with patch.object(self.forge, "read_detach_ep_peer", return_value=status) as read:
            evidence = self.executor.pair_after_product_detach(**arguments)
        self.assertEqual(evidence.forge_instance_id, "forge-prod")
        read.assert_called_once_with(
            operation_id="detach-old", binding_id="old-binding", revision=3,
            configuration_digest="sha256:" + "a" * 64, operator_id="installer",
        )
        configure = self.forge_runner.calls[0]
        self.assertEqual(configure[-5:], (
            "--replace", "--expected-revision", "4",
            "--expected-digest", "sha256:" + "b" * 64,
        ))
        self.assertEqual(len(self.ep_runner.calls), 2)

    def test_replacement_rejects_changed_target_or_old_identity_before_product_read(self):
        for change in (
            {"old_binding_id": self.binding.binding_id},
            {"old_consumer_id": self.binding.consumer_id},
            {"detach_revision": 0},
            {"detach_configuration_digest": "not-a-digest"},
            {"deployment": self.deployment},
            {"deployment": replace(
                self.deployment,
                components=(
                    ManagedComponentBinding("forge-runtime", "forge-other", "receipt:forge"),
                    self.deployment.components[1],
                ),
                peer_binding=ManagedPeerBinding("forge-other", "ep-prod", "receipt:old-peer"),
            )},
        ):
            with self.subTest(change=change):
                arguments = self.replacement(**change)
                with patch.object(self.forge, "read_detach_ep_peer") as read:
                    with self.assertRaisesRegex(ForgeEPProductPairingError, "replacement product target"):
                        self.executor.pair_after_product_detach(**arguments)
                    read.assert_not_called()
                self.assertEqual(self.forge_runner.calls, [])

    def test_replacement_rejects_nonterminal_or_mismatched_detach_readback(self):
        arguments = self.replacement()
        for status in (
            None,
            {"current_peer_status": "PAIRED", "receipt": {}},
            {"current_peer_status": "DETACHED", "receipt": None},
            {"current_peer_status": "DETACHED", "receipt": {
                "next_configuration_revision": 5, "receipt_digest": "sha256:" + "b" * 64,
            }},
            {"current_peer_status": "DETACHED", "receipt": {
                "next_configuration_revision": 4, "receipt_digest": "bad",
            }},
        ):
            with self.subTest(status=status):
                with patch.object(self.forge, "read_detach_ep_peer", return_value=status):
                    with self.assertRaisesRegex(ForgeEPProductPairingError, "detach status"):
                        self.executor.pair_after_product_detach(**arguments)
                self.assertEqual(self.forge_runner.calls, [])

    def test_replacement_requires_exact_qualified_forge_producer(self):
        arguments = self.replacement()
        self.forge.installed_artifact = ARTIFACT
        with self.assertRaisesRegex(ForgeServerAdapterError, "detach authority"):
            self.executor.pair_after_product_detach(**arguments)
        self.assertEqual(self.forge_runner.calls, [])


if __name__ == "__main__":
    unittest.main()
