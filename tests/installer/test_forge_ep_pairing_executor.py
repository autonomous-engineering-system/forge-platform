import tempfile
import unittest
from pathlib import Path

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    EngineeringPlatformSystemProvisionerAdapter,
    ProductCommandResult,
)
from forge_platform.forge_ep_pairing_executor import (
    ForgeEPProductPairingBinding,
    ForgeEPProductPairingError,
    ForgeEPProductPairingExecutor,
)
from forge_platform.forge_server_adapter import (
    ForgeCommandResult,
    ForgeServerProductAdapter,
    ForgeServerTarget,
)
from forge_platform.managed_deployments import ManagedComponentBinding, ManagedDeployment


ARTIFACT = QualifiedArtifact(
    "1.2.3",
    "a" * 40,
    "https://example.invalid/release.whl",
    "sha256:" + "b" * 64,
    "qualification:release",
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
            payload = {
                "contract": "engineering-platform.system-provisioner/v1",
                "state": "READY" if self.ready else "DEGRADED",
                "ready": self.ready,
                "descriptor": descriptor,
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


if __name__ == "__main__":
    unittest.main()
