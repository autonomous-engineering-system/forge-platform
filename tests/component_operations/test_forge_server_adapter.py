#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import tempfile
import json
import plistlib
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import URLError

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.forge_server_adapter import (
    ForgeCommandResult,
    ForgeHTTPReadinessProbe,
    ForgePreparedInstance,
    ForgeServerAdapterError,
    ForgeServerProductAdapter,
    ForgeServerTarget,
    ForgeUpdateBinding,
    MacOSForgeLaunchDaemonSupervisor,
    SubprocessForgeCommandRunner,
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


    def test_target_validation_and_service_label_are_instance_scoped(self) -> None:
        root = Path(self.temp.name).resolve()
        target = ForgeServerTarget(
            "forge-other",
            root / "instances" / "other",
            root / "instances",
            "_forge_other",
            9001,
            root / "credentials" / "other-api",
        )
        self.assertNotEqual(target.service_label, self.target.service_label)
        self.assertTrue(target.service_label.startswith("com.forgeplatform.forge-server.instance-"))
        with self.assertRaisesRegex(ValueError, "contained"):
            ForgeServerTarget(
                "escape", root / "elsewhere", root / "instances",
                "_forge_escape", 9002, root / "credentials" / "escape",
            )
        with self.assertRaisesRegex(ValueError, "bind_port"):
            ForgeServerTarget(
                "bad-port", root / "instances" / "bad", root / "instances",
                "_forge_bad", 0, root / "credentials" / "bad",
            )

    def test_subprocess_runner_rejects_relative_executable_and_uses_bounded_environment(self) -> None:
        runner = SubprocessForgeCommandRunner()
        with self.assertRaisesRegex(ForgeServerAdapterError, "absolute"):
            runner.run(("forge", "server", "status"))
        completed = SimpleNamespace(returncode=0, stdout='{"ok":true}', stderr="")
        with patch("forge_platform.forge_server_adapter.subprocess.run", return_value=completed) as run:
            result = runner.run(("/opt/forge/bin/forge", "--version"))
        self.assertEqual(result.returncode, 0)
        kwargs = run.call_args.kwargs
        self.assertEqual(kwargs["env"]["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(kwargs["env"]["PYTHONSAFEPATH"], "1")

    def test_launchdaemon_supervisor_writes_exact_non_root_system_service(self) -> None:
        root = Path(self.temp.name).resolve()
        launch_dir = root / "LaunchDaemons"
        supervisor = MacOSForgeLaunchDaemonSupervisor(launch_dir)
        with patch("forge_platform.forge_server_adapter.os.geteuid", return_value=0), patch(
            "forge_platform.forge_server_adapter.pwd.getpwnam",
            return_value=SimpleNamespace(pw_uid=501),
        ):
            receipt = supervisor.register(self.target, Path("/opt/forge/bin/forge"))
        self.assertEqual(receipt["result"], "REGISTERED")
        plist_path = launch_dir / f"{self.target.service_label}.plist"
        with plist_path.open("rb") as handle:
            payload = plistlib.load(handle)
        self.assertEqual(payload["Label"], self.target.service_label)
        self.assertEqual(payload["UserName"], "_forge_test")
        self.assertEqual(payload["ProgramArguments"][0], "/opt/forge/bin/forge")
        self.assertIn(str(self.target.data_root), payload["ProgramArguments"])
        self.assertIn(str(self.target.api_credential_file), payload["ProgramArguments"])
        self.assertNotIn("token", json.dumps(payload).casefold())

    def test_launchdaemon_supervisor_fails_closed_on_privilege_account_and_launchctl_errors(self) -> None:
        root = Path(self.temp.name).resolve()
        supervisor = MacOSForgeLaunchDaemonSupervisor(root / "LaunchDaemons")
        with patch("forge_platform.forge_server_adapter.os.geteuid", return_value=501):
            with self.assertRaisesRegex(ForgeServerAdapterError, "requires root"):
                supervisor.register(self.target, Path("/opt/forge/bin/forge"))
        with patch("forge_platform.forge_server_adapter.os.geteuid", return_value=0), patch(
            "forge_platform.forge_server_adapter.pwd.getpwnam", side_effect=KeyError("missing"),
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "unavailable"):
                supervisor.register(self.target, Path("/opt/forge/bin/forge"))
        with patch("forge_platform.forge_server_adapter.os.geteuid", return_value=0), patch(
            "forge_platform.forge_server_adapter.pwd.getpwnam",
            return_value=SimpleNamespace(pw_uid=0),
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "non-root"):
                supervisor.register(self.target, Path("/opt/forge/bin/forge"))

        failure = SimpleNamespace(returncode=1, stdout="", stderr="failed")
        with patch.object(supervisor, "loaded", return_value=False), patch.object(
            supervisor, "_launchctl", return_value=failure,
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "started"):
                supervisor.start(self.target)
        with patch.object(supervisor, "loaded", return_value=True), patch.object(
            supervisor, "_launchctl", return_value=failure,
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "stopped"):
                supervisor.stop(self.target)

    def test_launchdaemon_loaded_start_stop_remove_use_exact_service_label(self) -> None:
        root = Path(self.temp.name).resolve()
        launch_dir = root / "LaunchDaemons"
        supervisor = MacOSForgeLaunchDaemonSupervisor(launch_dir)
        plist = launch_dir / f"{self.target.service_label}.plist"
        launch_dir.mkdir(parents=True)
        plist.write_text("placeholder", encoding="utf-8")
        calls = []
        def launchctl(*args):
            calls.append(args)
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        with patch.object(supervisor, "_launchctl", side_effect=launchctl):
            self.assertTrue(supervisor.loaded(self.target))
            self.assertEqual(supervisor.start(self.target)["result"], "RUNNING")
            self.assertEqual(supervisor.stop(self.target)["result"], "STOPPED")
            self.assertEqual(supervisor.remove(self.target)["result"], "REMOVED")
        self.assertFalse(plist.exists())
        self.assertTrue(any(args[:2] == ("print", f"system/{self.target.service_label}") for args in calls))
        self.assertTrue(any(args[:2] == ("bootout", "system") for args in calls))

    def test_http_readiness_probe_validates_secret_file_response_shape_and_bounds(self) -> None:
        credential = self.target.api_credential_file
        credential.parent.mkdir(parents=True, exist_ok=True)
        credential.write_text("synthetic-bearer\n", encoding="utf-8")
        probe = ForgeHTTPReadinessProbe()

        class Response:
            def __init__(self, payload: bytes): self.payload = payload
            def __enter__(self): return self
            def __exit__(self, *args): return None
            def read(self, _limit): return self.payload

        with patch(
            "forge_platform.forge_server_adapter.urllib_request.urlopen",
            return_value=Response(b'{"ready":true,"instance_id":"forge-instance-1"}'),
        ) as opener:
            value = probe.readiness(self.target)
        self.assertTrue(value["ready"])
        request = opener.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-bearer")

        credential.write_text("", encoding="utf-8")
        with self.assertRaisesRegex(ForgeServerAdapterError, "empty"):
            probe.readiness(self.target)
        credential.write_text("synthetic-bearer", encoding="utf-8")
        with patch(
            "forge_platform.forge_server_adapter.urllib_request.urlopen",
            side_effect=URLError("offline"),
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "unavailable"):
                probe.readiness(self.target)
        with patch(
            "forge_platform.forge_server_adapter.urllib_request.urlopen",
            return_value=Response(b"x" * 1_048_577),
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "response bound"):
                probe.readiness(self.target)
        with patch(
            "forge_platform.forge_server_adapter.urllib_request.urlopen",
            return_value=Response(b"not-json"),
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "invalid JSON"):
                probe.readiness(self.target)
        with patch(
            "forge_platform.forge_server_adapter.urllib_request.urlopen",
            return_value=Response(b'["not","object"]'),
        ):
            with self.assertRaisesRegex(ForgeServerAdapterError, "JSON object"):
                probe.readiness(self.target)

    def test_json_result_and_request_correlation_fail_closed(self) -> None:
        with self.assertRaisesRegex(ForgeServerAdapterError, "invalid JSON"):
            self.adapter._json_result(ForgeCommandResult(0, "broken", ""), "broken")
        with self.assertRaisesRegex(ForgeServerAdapterError, "JSON object"):
            self.adapter._json_result(ForgeCommandResult(0, "[]", ""), "list")
        with self.assertRaisesRegex(ForgeServerAdapterError, "failed"):
            self.adapter._json_result(ForgeCommandResult(2, '{"error":"x"}', ""), "failed")
        self.assertEqual(
            self.adapter._json_result(
                ForgeCommandResult(2, '{"initialized":false}', ""), "diagnostic", allow_nonzero=True
            )["initialized"],
            False,
        )
        wrong_instance = ComponentOperationRequest(
            "wrong-instance", "forge-runtime", "repair", ARTIFACT,
            "forge-other", "server", {},
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "initialized product instance"):
            self.adapter.readback(wrong_instance)
        wrong_role = ComponentOperationRequest(
            "wrong-role", "forge-runtime", "repair", ARTIFACT,
            self.prepared.instance_id, "client", {},
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "Server runtime role"):
            self.adapter.readback(wrong_role)
        extended = ComponentOperationRequest(
            "extension", "forge-runtime", "repair", ARTIFACT,
            self.prepared.instance_id, "server", {"channel": "stable"},
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "product_request"):
            self.adapter.readback(extended)

    def test_readback_rejects_wrong_identity_version_and_projects_unhealthy_readiness(self) -> None:
        self.supervisor.running = True
        self.runner.initialized = True
        original = self.runner.run
        def wrong_identity(argv):
            result = original(argv)
            args = tuple(argv)
            if args[-2:] == ("server", "status"):
                payload = json.loads(result.stdout)
                payload["instance_id"] = "forge-other"
                return ForgeCommandResult(0, json.dumps(payload), "")
            return result
        self.runner.run = wrong_identity
        with self.assertRaisesRegex(ForgeServerAdapterError, "different instance"):
            self.adapter.readback(self.request("repair"))

        self.runner.run = original
        def wrong_version(argv):
            result = original(argv)
            args = tuple(argv)
            if args[-2:] == ("server", "status"):
                payload = json.loads(result.stdout)
                payload["product_version"] = "2.7.33"
                return ForgeCommandResult(0, json.dumps(payload), "")
            return result
        self.runner.run = wrong_version
        with self.assertRaisesRegex(ForgeServerAdapterError, "version"):
            self.adapter.readback(self.request("repair"))

        self.runner.run = original
        class NotReady:
            def readiness(self, target): return {"ready": False}
        self.adapter.readiness_probe = NotReady()
        observed = self.adapter.readback(self.request("repair"))
        self.assertEqual(observed.state, "UNHEALTHY")
        self.assertEqual(observed.health_state, "UNHEALTHY")

        class FailedProbe:
            def readiness(self, target):
                raise ForgeServerAdapterError("unavailable")
        self.adapter.readiness_probe = FailedProbe()
        observed = self.adapter.readback(self.request("repair"))
        self.assertEqual(observed.state, "UNHEALTHY")

    def test_provider_guard_peer_loopback_flag_and_resume_identity(self) -> None:
        self.adapter.configure_provider_context(
            codex_executable=Path("/opt/forge/providers/codex/bin/codex"),
            provider_home=Path("/var/lib/forge/provider-home"),
            provider_config_home=Path("/var/lib/forge/codex-home"),
            expected_digest="sha256:" + "d" * 64,
        )
        self.assertIn("--expected-digest", self.runner.calls[-1])
        self.adapter.configure_ep_peer(
            binding_id="binding-2",
            endpoint="https://ep.example.test",
            expected_instance_id="ep-prod",
            consumer_id="consumer-2",
            host_id="host-2",
            project_id="project-2",
            repository_id="repo-2",
            repository_identity="owner/repo",
            credential_reference="secret-ref",
            operator_id="installer",
            allow_loopback_http=False,
        )
        self.assertNotIn("--allow-loopback-http", self.runner.calls[-1])
        receipt = self.adapter.execute(self.request("repair", "repair-1"))
        wrong = type(receipt)(
            "other-operation", receipt.component, receipt.installation_identity,
            receipt.artifact, receipt.state, receipt.evidence_reference,
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "operation identity"):
            self.adapter.resume(self.request("repair", "repair-1"), wrong)
        resumed = self.adapter.resume(self.request("repair", "repair-1"), receipt)
        self.assertEqual(resumed.state, "COMPLETED")

    def test_exact_up_to_date_assessment_and_external_updater_success_path(self) -> None:
        self.assertEqual(self.adapter.assess_update(self.request("update")).state, "UP_TO_DATE")
        root = Path(self.temp.name).resolve()
        candidate = QualifiedArtifact(
            "2.7.35", "b" * 40, ARTIFACT.source,
            "sha256:" + "c" * 64, ARTIFACT.qualification,
        )
        binding = ForgeUpdateBinding(
            updater_executable=Path("/opt/forge/bin/update-installed-forge"),
            qualification_receipt=root / "qualification.json",
            qualification_receipt_sha256="q" * 64,
            controller_source="controller-source",
            controller_sha256="c" * 64,
            resolver=root / "resolver.json",
            resolver_sha256="r" * 64,
            runtime_root=root / "runtimes",
            runtime_id="forge-runtime",
            installation_id="forge-installation",
            peer_configuration_digest="sha256:" + "e" * 64,
            existing_interpreter=Path("/opt/forge/2.7.34/bin/python"),
            existing_version="2.7.34",
            base_python=Path("/usr/bin/python3"),
        )
        wheel = root / "forge-2.7.35.whl"
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            target=self.target,
            installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel},
            supervisor=self.supervisor,
            runner=self.runner,
            readiness_probe=Probe(),
            update_binding=binding,
        )
        req = ComponentOperationRequest(
            "forge-update-0001", "forge-runtime", "update", candidate,
            self.prepared.instance_id, "server", {},
        )
        receipt = adapter.execute(req)
        self.assertEqual(receipt.state, "COMPLETED")
        self.assertEqual(adapter.installed_artifact, candidate)
        call = self.runner.calls[-1]
        self.assertEqual(call[0], "/opt/forge/bin/update-installed-forge")
        self.assertIn("--qualification-receipt", call)
        self.assertIn(str(wheel), call)

    def test_update_binding_paths_staged_wheel_and_terminal_state_are_validated(self) -> None:
        root = Path(self.temp.name).resolve()
        with self.assertRaisesRegex(ValueError, "absolute"):
            ForgeUpdateBinding(
                updater_executable=Path("relative-updater"),
                qualification_receipt=root / "q", qualification_receipt_sha256="q",
                controller_source="c", controller_sha256="c",
                resolver=root / "r", resolver_sha256="r", runtime_root=root / "rt",
                runtime_id="rid", installation_id="iid", peer_configuration_digest="p",
                existing_interpreter=Path("/opt/python"), existing_version="2.7.34",
                base_python=Path("/usr/bin/python3"),
            )
        candidate = QualifiedArtifact(
            "2.7.35", "b" * 40, ARTIFACT.source,
            "sha256:" + "c" * 64, ARTIFACT.qualification,
        )
        binding = ForgeUpdateBinding(
            Path("/opt/updater"), root / "q", "q", "c", "c", root / "r", "r",
            root / "rt", "rid", "iid", "peer", Path("/opt/python"), "2.7.34",
            Path("/usr/bin/python3"),
        )
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"), target=self.target,
            installed_artifact=ARTIFACT, staged_artifacts={}, supervisor=self.supervisor,
            runner=self.runner, readiness_probe=Probe(), update_binding=binding,
        )
        req = ComponentOperationRequest(
            "forge-update-0002", "forge-runtime", "update", candidate,
            self.prepared.instance_id, "server", {},
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "staged update wheel"):
            adapter.execute(req)

        class FailedUpdateRunner(Runner):
            def run(self, argv):
                if tuple(argv)[0] == "/opt/updater":
                    return ForgeCommandResult(0, '{"state":"FAILED"}', "")
                return super().run(argv)
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"), target=self.target,
            installed_artifact=ARTIFACT, staged_artifacts={candidate.digest: root / "wheel.whl"},
            supervisor=self.supervisor, runner=FailedUpdateRunner(),
            readiness_probe=Probe(), update_binding=binding,
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "did not complete"):
            adapter.execute(req)


if __name__ == "__main__":
    unittest.main()
