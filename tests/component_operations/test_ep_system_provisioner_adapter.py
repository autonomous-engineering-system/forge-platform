#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    EngineeringPlatformAdapterError,
    EngineeringPlatformSystemProvisionerAdapter,
    ProductCommandResult,
)


ARTIFACT = QualifiedArtifact(
    "2.3.102",
    "c" * 40,
    "https://files.pythonhosted.org/engineering-platform-2.3.102.whl",
    "sha256:" + "a" * 64,
    "https://evidence.example.invalid/ep-2.3.102",
)


class Runner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.inventory_instances: list[dict[str, object]] = []
        self.ready = True
        self.operation_result = "COMPLETE"

    def run(self, argv):
        args = tuple(argv)
        self.calls.append(args)
        command = args[1]
        if command == "inventory":
            payload = {"state": "READY", "instances": self.inventory_instances}
        elif command == "status":
            payload = {
                "contract": "engineering-platform.system-provisioner/v1",
                "instance_id": "ep-prod",
                "state": "READY" if self.ready else "NOT_READY",
                "ready": self.ready,
                "descriptor": {
                    "instance_id": "ep-prod",
                    "service_label": "com.engineeringplatform.server.instance-deadbeef",
                    "selected_runtime": {
                        "version": "2.3.102",
                        "artifact_digest": ARTIFACT.digest,
                        "source_revision": ARTIFACT.source_revision,
                        "interpreter": "/Library/EP/runtime/bin/python",
                    },
                },
                "providers": {},
                "health": {"result": "PASS" if self.ready else "FAIL"},
            }
        elif command == "update-assess":
            payload = {
                "contract": "engineering-platform.system-provisioner/v1",
                "instance_id": "ep-prod",
                "state": "UPDATE_AVAILABLE",
                "current": {},
                "target": {},
            }
        elif command == "provider-register":
            payload = {
                "contract": "engineering-platform.system-provisioner/v1",
                "provider": "codex",
                "instance_id": "ep-prod",
                "state": "READY",
            }
        else:
            if command == "remove":
                self.inventory_instances = []
            else:
                self.inventory_instances = [{
                    "instance_id": "ep-prod",
                    "service_label": "com.engineeringplatform.server.instance-deadbeef",
                    "selected_runtime": {
                        "version": "2.3.102",
                        "artifact_digest": ARTIFACT.digest,
                        "source_revision": ARTIFACT.source_revision,
                        "interpreter": "/Library/EP/runtime/bin/python",
                    },
                }]
            payload = {
                "contract": "engineering-platform.system-provisioner/v1",
                "result": self.operation_result,
                "instance_id": "ep-prod",
                "receipt": {
                    "contract": "engineering-platform.system-provisioner/v1",
                    "operation_id": next(
                        (args[index + 1] for index, value in enumerate(args) if value == "--operation-id"),
                        "operation-unknown",
                    ),
                    "operation": command,
                    "state": self.operation_result,
                    "instance_id": "ep-prod",
                    "evidence": {},
                },
            }
        import json
        return ProductCommandResult(0, json.dumps(payload), "")


def request(kind: str, operation_id: str = "operation-0001") -> ComponentOperationRequest:
    return ComponentOperationRequest(
        operation_id,
        "engineering-platform-server",
        kind,
        ARTIFACT,
        "ep-prod",
        "server",
        {},
    )


class EPSystemAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name).resolve()
        self.wheel = root / "ep.whl"
        # Fixture bytes intentionally do not match ARTIFACT; remove existence so
        # adapter tests validate command binding without pretending byte proof.
        self.runner = Runner()
        self.adapter = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=Path("/opt/ep/bin/engineering-platform-system-provisioner"),
            product_root=Path("/Library/Application Support/EngineeringPlatform"),
            target=EPSystemInstanceTarget("ep-prod", "Production", "_ep_prod", 8876),
            staged_artifacts={ARTIFACT.digest: root / "not-materialized.whl"},
            runner=self.runner,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_absent_inventory_is_exact_install_target(self) -> None:
        observed = self.adapter.readback(request("install"))
        self.assertEqual(observed.state, "ABSENT")
        self.assertEqual(observed.installation_identity, "ep-prod")
        self.assertEqual(observed.inventory_coverage, "MACHINE_WIDE")

    def test_create_uses_fixed_product_command_and_exact_release_identity(self) -> None:
        receipt = self.adapter.execute(request("install"))
        self.assertEqual(receipt.state, "COMPLETED")
        call = self.runner.calls[-1]
        self.assertEqual(call[0], "/opt/ep/bin/engineering-platform-system-provisioner")
        self.assertEqual(call[1], "create")
        self.assertIn("--product-root", call)
        self.assertIn("--artifact-digest", call)
        self.assertIn(ARTIFACT.digest, call)
        self.assertNotIn("launchctl", call)

    def test_active_status_maps_to_identity_aware_product_readback(self) -> None:
        self.runner.inventory_instances = [{
            "instance_id": "ep-prod",
            "service_label": "com.engineeringplatform.server.instance-deadbeef",
            "selected_runtime": {
                "version": "2.3.102",
                "artifact_digest": ARTIFACT.digest,
                "source_revision": ARTIFACT.source_revision,
                "interpreter": "/Library/EP/runtime/bin/python",
            },
        }]
        observed = self.adapter.readback(request("repair"))
        self.assertEqual(observed.state, "ACTIVE")
        self.assertEqual(observed.artifact, ARTIFACT.correlation)
        self.assertEqual(observed.selected_instance_identity, "ep-prod")

    def test_update_assessment_and_execute_keep_exact_target(self) -> None:
        assessment = self.adapter.assess_update(request("update"))
        self.assertEqual(assessment.state, "UPDATE_AVAILABLE")
        receipt = self.adapter.execute(request("update"))
        self.assertEqual(receipt.state, "COMPLETED")
        self.assertIn("update-execute", self.runner.calls[-1])

    def test_remove_confirms_exact_instance_and_post_readback_is_absent(self) -> None:
        self.runner.inventory_instances = [{
            "instance_id": "ep-prod",
            "service_label": "com.engineeringplatform.server.instance-deadbeef",
            "selected_runtime": {
                "version": "2.3.102",
                "artifact_digest": ARTIFACT.digest,
                "source_revision": ARTIFACT.source_revision,
                "interpreter": "/Library/EP/runtime/bin/python",
            },
        }]
        receipt = self.adapter.execute(request("remove"))
        self.assertEqual(receipt.state, "COMPLETED")
        call = self.runner.calls[-1]
        self.assertIn("--confirm-instance-id", call)
        self.assertEqual(call[call.index("--confirm-instance-id") + 1], "ep-prod")
        self.assertEqual(self.adapter.readback(request("remove")).state, "ABSENT")

    def test_provider_registration_is_target_scoped_and_secret_free_to_generic_request(self) -> None:
        result = self.adapter.register_provider(
            provider="codex",
            executable_digest="sha256:" + "d" * 64,
            version="0.146.0",
            auth_reference="provider-owned-reference",
            auth_bootstrap_receipt="receipt:provider-bootstrap",
        )
        self.assertEqual(result["instance_id"], "ep-prod")
        call = self.runner.calls[-1]
        self.assertIn("provider-register", call)
        self.assertIn("--instance-id", call)
        self.assertNotIn("token", " ".join(call).lower())

    def test_wrong_instance_or_generic_runtime_extension_fails_before_product_call(self) -> None:
        wrong = ComponentOperationRequest(
            "operation-0002", "engineering-platform-server", "repair", ARTIFACT,
            "ep-other", "server", {},
        )
        with self.assertRaisesRegex(EngineeringPlatformAdapterError, "target"):
            self.adapter.execute(wrong)
        extended = ComponentOperationRequest(
            "operation-0003", "engineering-platform-server", "repair", ARTIFACT,
            "ep-prod", "server", {"channel": "stable"},
        )
        with self.assertRaisesRegex(EngineeringPlatformAdapterError, "product_request"):
            self.adapter.execute(extended)


if __name__ == "__main__":
    unittest.main()
