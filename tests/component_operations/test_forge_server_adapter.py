#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.forge_server_adapter import (
    ForgeCommandResult,
    ForgePreparedInstance,
    ForgeServerProductAdapter,
    ForgeServerTarget,
)


ARTIFACT = QualifiedArtifact(
    "2.7.34",
    "a4c4a3fab5227150e5f3219241709cfca85f3d82",
    "https://files.pythonhosted.org/forge-autonomy-2.7.34.whl",
    "sha256:" + "a" * 64,
    "https://evidence.example.invalid/forge-2.7.34",
)


class Runner:
    def __init__(self) -> None:
        self.initialized = False
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv):
        import json
        args = tuple(argv)
        self.calls.append(args)
        command = args[args.index("server") + 1] if "server" in args else None
        if command == "init":
            self.initialized = True
        if command in {"status", "init"}:
            payload = {
                "product_version": "2.7.34",
                "initialized": self.initialized,
                "runtime_status": "active" if self.initialized else "uninitialized",
            }
            if self.initialized:
                payload.update({"instance_id": "forge-instance-1", "storage_schema": "39"})
        elif "health" in args:
            payload = {"outcome": "HEALTHY"}
        elif "provider-context" in args:
            payload = {"provider_id": "codex-chatgpt-session", "configuration_digest": "sha256:" + "b" * 64}
        elif "execution-host" in args:
            payload = {"status": "CONFIGURED"}
        else:
            payload = {"status": "COMPLETE"}
        return ForgeCommandResult(0, json.dumps(payload), "")


class Supervisor:
    def __init__(self) -> None:
        self.running = False
        self.calls: list[str] = []

    def register(self, target, executable):
        self.calls.append("register")
        return {"result": "REGISTERED"}

    def start(self, target):
        self.calls.append("start")
        self.running = True
        return {"result": "RUNNING"}

    def stop(self, target):
        self.calls.append("stop")
        self.running = False
        return {"result": "STOPPED"}

    def remove(self, target):
        self.calls.append("remove")
        self.running = False
        return {"result": "REMOVED"}

    def loaded(self, target):
        return self.running


class Probe:
    def readiness(self, target):
        return {"ready": True, "instance_id": target.instance_id}


class ForgeServerAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name).resolve()
        self.data = root / "instances" / "forge-slot"
        self.data.mkdir(parents=True)
        self.runner = Runner()
        self.prepared: ForgePreparedInstance = ForgeServerProductAdapter.prepare_instance(
            forge_executable=Path("/opt/forge/bin/forge"),
            data_root=self.data,
            runner=self.runner,
        )
        self.supervisor = Supervisor()
        self.target = ForgeServerTarget(
            self.prepared.instance_id,
            self.data,
            root / "instances",
            "_forge_test",
            8765,
            root / "credentials" / "forge-api",
        )
        self.adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            target=self.target,
            installed_artifact=ARTIFACT,
            staged_artifacts={},
            supervisor=self.supervisor,
            runner=self.runner,
            readiness_probe=Probe(),
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def request(self, kind: str, op: str = "forge-operation-001") -> ComponentOperationRequest:
        return ComponentOperationRequest(op, "forge-runtime", kind, ARTIFACT, self.prepared.instance_id, "server", {})

    def test_product_init_supplies_authoritative_instance_identity_before_binding(self) -> None:
        self.assertEqual(self.prepared.instance_id, "forge-instance-1")
        init = [call for call in self.runner.calls if call[-2:] == ("server", "init")]
        self.assertEqual(len(init), 1)

    def test_install_supervises_exact_initialized_instance_and_readiness(self) -> None:
        before = self.adapter.readback(self.request("install"))
        self.assertEqual(before.state, "ABSENT")
        receipt = self.adapter.execute(self.request("install"))
        self.assertEqual(receipt.state, "COMPLETED")
        after = self.adapter.readback(self.request("install"))
        self.assertEqual(after.state, "ACTIVE")
        self.assertEqual(after.selected_instance_identity, "forge-instance-1")
        self.assertEqual(self.supervisor.calls, ["register", "start"])

    def test_provider_context_and_peer_configuration_use_product_cli(self) -> None:
        self.adapter.configure_provider_context(
            codex_executable=Path("/opt/forge/providers/codex/bin/codex"),
            provider_home=Path("/var/lib/forge/provider-home"),
            provider_config_home=Path("/var/lib/forge/codex-home"),
        )
        self.adapter.configure_ep_peer(
            binding_id="binding-1",
            endpoint="http://127.0.0.1:8876",
            expected_instance_id="ep-prod",
            consumer_id="consumer-1",
            host_id="host-1",
            project_id="project-1",
            repository_id="repo-1",
            repository_identity="owner/repo",
            credential_reference="secret-ref",
            operator_id="installer",
        )
        flattened = [" ".join(call) for call in self.runner.calls]
        self.assertTrue(any("provider-context configure" in call for call in flattened))
        self.assertTrue(any("execution-host configure" in call for call in flattened))

    def test_remove_remains_blocked_without_product_owned_uninstall_dispatcher(self) -> None:
        self.assertEqual(self.adapter.removal_support(), "UNSUPPORTED")
        with self.assertRaisesRegex(Exception, "no product-owned uninstall"):
            self.adapter.execute(self.request("remove", "forge-operation-remove"))
        self.assertTrue(self.data.exists())
        self.assertNotIn("remove", self.supervisor.calls)

    def test_update_remains_blocked_without_product_owned_update_assessment(self) -> None:
        candidate = QualifiedArtifact(
            "2.7.35", "b" * 40, ARTIFACT.source,
            "sha256:" + "c" * 64, ARTIFACT.qualification,
        )
        req = ComponentOperationRequest(
            "forge-operation-update", "forge-runtime", "update", candidate,
            self.prepared.instance_id, "server", {},
        )
        self.assertEqual(self.adapter.assess_update(req).state, "UNKNOWN")
        with self.assertRaisesRegex(Exception, "updater binding"):
            self.adapter.execute(req)


if __name__ == "__main__":
    unittest.main()
