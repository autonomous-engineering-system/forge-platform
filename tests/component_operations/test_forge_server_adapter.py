#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import tempfile
import json
import hashlib
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
    ForgeUninstallBinding,
    ForgeUpdateBinding,
    MacOSForgeLaunchDaemonSupervisor,
    SubprocessForgeCommandRunner,
)
from forge_platform.forge_update_intent import ForgeUpdateIntent, ForgeUpdateIntentStore


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

    def test_remove_remains_blocked_without_helper_owned_uninstall_binding(self) -> None:
        self.assertEqual(self.adapter.removal_support(), "UNSUPPORTED")
        with self.assertRaisesRegex(Exception, "uninstall binding is unavailable"):
            self.adapter.execute(self.request("remove", "forge-operation-remove"))
        self.assertTrue(self.data.exists())
        self.assertNotIn("remove", self.supervisor.calls)

    def test_product_owned_exact_uninstall_receipt_status_and_replay(self) -> None:
        root = Path(self.temp.name).resolve()
        sibling = self.target.instances_root / "other-forge-instance"
        sibling.mkdir()
        (sibling / "preserve").write_text("untouched", encoding="utf-8")

        def product_digest(value):
            canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n"
            return "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()

        class UninstallRunner(Runner):
            receipt = None
            status_drift = False
            status_once_in_progress = False
            receipt_tamper: dict[str, object] = {}

            def run(self, argv):
                args = tuple(argv)
                if "uninstall-status" in args:
                    self.calls.append(args)
                    if self.receipt is None:
                        return ForgeCommandResult(2, "{}", "")
                    status = {
                        "contract": "forge-server-runtime-lifecycle/v1",
                        "operation": "UNINSTALL",
                        "operation_id": self.receipt["operation_id"],
                        "instance_id": self.receipt["instance_id"],
                        "phase": "COMPLETE", "state": "COMPLETE",
                        "request_digest": self.receipt["request_digest"],
                        "receipt_digest": self.receipt["receipt_digest"],
                    }
                    if self.status_once_in_progress:
                        self.status_once_in_progress = False
                        status["phase"] = "DETACHED"
                        status["state"] = "IN_PROGRESS"
                        del status["receipt_digest"]
                    if self.status_drift:
                        status["receipt_digest"] = "sha256:" + "0" * 64
                    return ForgeCommandResult(0, json.dumps(status), "")
                if "uninstall" not in args:
                    return super().run(args)
                self.calls.append(args)
                if self.receipt is None:
                    self_data.rmdir()
                    selected = {
                        "operation_id": args[args.index("--operation-id") + 1],
                        "instance_id": args[args.index("--instance-id") + 1],
                        "runtime_id": args[args.index("--runtime-id") + 1],
                        "installation_id": args[args.index("--installation-id") + 1],
                        "data_root": args[args.index("--data-root") + 1],
                        "instances_root": args[args.index("--instances-root") + 1],
                    }
                    receipt = {
                        "contract": "forge-server-runtime-lifecycle/v1",
                        "operation": "UNINSTALL",
                        "operation_id": selected["operation_id"],
                        "instance_id": selected["instance_id"],
                        "runtime_id": selected["runtime_id"],
                        "installation_id": selected["installation_id"],
                        "request_digest": product_digest(selected),
                        "state": "COMPLETE", "mutable_instance_data": "REMOVED",
                        "service_definition": "DEPLOYMENT_OWNER",
                        "immutable_runtime_slots": "PRESERVED",
                        "completed_at": "2026-09-27T00:00:00Z",
                    }
                    receipt["receipt_digest"] = product_digest(receipt)
                    self.receipt = receipt
                return ForgeCommandResult(0, json.dumps({**self.receipt, **self.receipt_tamper}), "")

        self_data = self.data
        runner = UninstallRunner()
        runner.initialized = True
        self.supervisor.running = True
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/current/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={}, supervisor=self.supervisor, runner=runner,
            readiness_probe=Probe(),
            uninstall_binding=ForgeUninstallBinding(self.target.instance_id, "installation-1"),
        )
        request = self.request("remove", "forge-uninstall-1")
        self.assertEqual(adapter.removal_support(), "SUPPORTED")
        receipt = adapter.execute(request)
        self.assertEqual(receipt.state, "COMPLETED")
        self.assertEqual(adapter.readback(request).state, "ABSENT")
        runner.status_once_in_progress = True
        self.assertEqual(adapter.execute(request), receipt)
        self.assertEqual(len([call for call in runner.calls if "uninstall" in call]), 2)
        self.assertEqual((sibling / "preserve").read_text(encoding="utf-8"), "untouched")
        self.assertFalse(self.data.exists())
        self.assertIn("remove", self.supervisor.calls)
        runner.status_drift = True
        removal_count = self.supervisor.calls.count("remove")
        with self.assertRaisesRegex(ForgeServerAdapterError, "terminal status differs"):
            adapter.execute(request)
        self.assertEqual(self.supervisor.calls.count("remove"), removal_count)
        runner.status_drift = False
        for tamper in (
            {"instance_id": "other-instance"},
            {"mutable_instance_data": "PRESERVED"},
            {"receipt_digest": "sha256:" + "0" * 64},
        ):
            runner.receipt_tamper = tamper
            with self.assertRaisesRegex(ForgeServerAdapterError, "terminal product receipt"):
                adapter.execute(request)
            self.assertEqual(self.supervisor.calls.count("remove"), removal_count)

    def test_uninstall_missing_or_foreign_binding_fails_before_service_mutation(self) -> None:
        for identity in ("", "..", "foreign/path", " bad"):
            with self.assertRaisesRegex(ValueError, "exact product identities"):
                ForgeUninstallBinding(identity, "installation-1")
        request = self.request("remove", "forge-uninstall-2")
        self.assertEqual(self.adapter.removal_support(), "UNSUPPORTED")
        with self.assertRaisesRegex(ForgeServerAdapterError, "binding is unavailable"):
            self.adapter.execute(request)
        self.adapter.lifecycle_executable = Path("/opt/forge/lifecycle-2.7.35/bin/forge")
        self.adapter.uninstall_binding = ForgeUninstallBinding("foreign-instance", "installation-1")
        with self.assertRaisesRegex(ForgeServerAdapterError, "exact selected instance"):
            self.adapter.execute(request)
        self.assertEqual(self.supervisor.calls, [])
        self.adapter.uninstall_binding = ForgeUninstallBinding(self.target.instance_id, "installation-1")
        with self.assertRaisesRegex(ForgeServerAdapterError, "operation identity is unsafe"):
            self.adapter.execute(self.request("remove", "unsafe/operation"))
        self.assertEqual(self.supervisor.calls, [])

        class DriftRunner(Runner):
            def run(self, argv):
                result = super().run(argv)
                if tuple(argv)[-2:] == ("server", "status"):
                    value = json.loads(result.stdout)
                    value["instance_id"] = "other-instance"
                    return ForgeCommandResult(0, json.dumps(value), "")
                return result

        self.adapter.runner = DriftRunner()
        with self.assertRaisesRegex(ForgeServerAdapterError, "target changed before service stop"):
            self.adapter.execute(request)
        self.assertEqual(self.supervisor.calls, [])

    def test_uninstall_resumes_detached_product_operation_without_new_target(self) -> None:
        selected = {
            "operation_id": "forge-uninstall-recovery",
            "instance_id": self.target.instance_id,
            "runtime_id": self.target.instance_id,
            "installation_id": "installation-1",
            "data_root": str(self.target.data_root),
            "instances_root": str(self.target.instances_root),
        }

        def digest(value):
            raw = (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
            return "sha256:" + hashlib.sha256(raw).hexdigest()

        receipt = {
            "contract": "forge-server-runtime-lifecycle/v1",
            "operation": "UNINSTALL",
            "operation_id": selected["operation_id"],
            "instance_id": selected["instance_id"],
            "runtime_id": selected["runtime_id"],
            "installation_id": selected["installation_id"],
            "request_digest": digest(selected),
            "state": "COMPLETE", "mutable_instance_data": "REMOVED",
            "service_definition": "DEPLOYMENT_OWNER",
            "immutable_runtime_slots": "PRESERVED",
            "completed_at": "2026-09-27T00:00:00Z",
        }
        receipt["receipt_digest"] = digest(receipt)

        class RecoveryRunner(Runner):
            completed = False

            def run(self, argv):
                args = tuple(argv)
                self.calls.append(args)
                if "uninstall-status" in args:
                    status = {
                        "contract": "forge-server-runtime-lifecycle/v1",
                        "operation": "UNINSTALL", "operation_id": selected["operation_id"],
                        "instance_id": selected["instance_id"],
                        "request_digest": digest(selected),
                        "phase": "COMPLETE" if self.completed else "DETACHED",
                        "state": "COMPLETE" if self.completed else "IN_PROGRESS",
                    }
                    if self.completed:
                        status["receipt_digest"] = receipt["receipt_digest"]
                    return ForgeCommandResult(0, json.dumps(status), "")
                if "uninstall" in args:
                    self.completed = True
                    return ForgeCommandResult(0, json.dumps(receipt), "")
                return super().run(args)

        self.data.rmdir()  # fixture represents Forge's already-detached phase
        runner = RecoveryRunner()
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/current/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={}, supervisor=self.supervisor, runner=runner,
            readiness_probe=Probe(),
            uninstall_binding=ForgeUninstallBinding(self.target.instance_id, "installation-1"),
        )
        request = self.request("remove", selected["operation_id"])
        self.assertEqual(adapter.execute(request).state, "COMPLETED")
        self.assertEqual(adapter.readback(request).state, "ABSENT")
        self.assertEqual(len([call for call in runner.calls if "uninstall" in call]), 1)

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
        with self.assertRaisesRegex(Exception, "reviewed product assessment"):
            self.adapter.execute(req)

    def test_forge_2735_product_owned_update_assessment_binds_exact_identity(self) -> None:
        root = Path(self.temp.name).resolve()
        candidate = QualifiedArtifact(
            "2.7.35", "f" * 40, ARTIFACT.source,
            "sha256:" + "c" * 64, ARTIFACT.qualification,
        )
        wheel = root / "staged" / "forge-2.7.35.whl"
        binding = ForgeUpdateBinding(
            Path("/opt/forge/update-installed-forge"), root / "qualification", "q" * 64,
            "f" * 40, "c" * 64, root / "resolver", "r" * 64,
            root / "runtimes", self.target.instance_id, "forge-installation-1",
            "sha256:" + "e" * 64, Path("/opt/forge/current/python"),
            ARTIFACT.version, Path("/usr/bin/python3"),
        )

        class AssessmentRunner(Runner):
            state = "UPDATE_AVAILABLE"
            overrides: dict[str, object] = {}
            bad_digest = False

            def run(self, argv):
                args = tuple(argv)
                if "update-assess" not in args:
                    return super().run(args)
                self.calls.append(args)
                value = {
                    "contract": "forge-server-runtime-lifecycle/v1",
                    "operation": "UPDATE_ASSESSMENT",
                    "state": self.state,
                    "mutating": False,
                    "selected_installation": {
                        "runtime_id": args[args.index("--runtime-id") + 1],
                        "installation_id": args[args.index("--installation-id") + 1],
                        "version": args[args.index("--installed-version") + 1],
                        "source_revision": args[args.index("--installed-source") + 1],
                        "artifact_digest": args[args.index("--installed-artifact-digest") + 1],
                    },
                    "candidate": {
                        "version": args[args.index("--candidate-version") + 1],
                        "source_revision": args[args.index("--candidate-source") + 1],
                        "artifact_digest": args[args.index("--candidate-artifact-digest") + 1],
                    },
                    "reason_codes": ["EXACT_SUPPORTED_TRANSITION"],
                    "evidence": {"runtime_snapshot_digest": "sha256:" + "d" * 64},
                }
                value.update(self.overrides)
                value["assessment_digest"] = "sha256:" + hashlib.sha256(
                    (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
                ).hexdigest()
                if self.bad_digest:
                    value["assessment_digest"] = "sha256:" + "0" * 64
                return ForgeCommandResult(0, json.dumps(value), "")

        runner = AssessmentRunner()
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/current/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=Probe(), update_binding=binding,
        )
        request = ComponentOperationRequest(
            "forge-assess-1", "forge-runtime", "update", candidate,
            self.target.instance_id, "server", {},
        )
        assessment = adapter.assess_update(request)
        self.assertEqual(assessment.state, "UPDATE_AVAILABLE")
        self.assertTrue(assessment.evidence_reference.startswith("forge-update-assess:sha256:"))
        self.assertEqual(runner.calls[-1][0], "/opt/forge/lifecycle-2.7.35/bin/forge")
        self.assertIn(str(wheel), runner.calls[-1])
        self.assertEqual(adapter.installed_artifact, ARTIFACT)
        for state in ("INCOMPATIBLE", "UNKNOWN"):
            runner.state = state
            self.assertEqual(adapter.assess_update(request).state, state)
        runner.state = "UP_TO_DATE"
        with self.assertRaisesRegex(ForgeServerAdapterError, "mismatched installed artifact"):
            adapter.assess_update(request)
        runner.state = "UPDATE_AVAILABLE"
        runner.overrides = {"selected_installation": {"runtime_id": "other"}}
        with self.assertRaisesRegex(ForgeServerAdapterError, "exact product target"):
            adapter.assess_update(request)
        runner.overrides = {"mutating": True}
        with self.assertRaisesRegex(ForgeServerAdapterError, "exact product target"):
            adapter.assess_update(request)
        runner.overrides = {"candidate": {"version": "2.7.36"}}
        with self.assertRaisesRegex(ForgeServerAdapterError, "exact product target"):
            adapter.assess_update(request)
        runner.overrides = {}
        runner.bad_digest = True
        with self.assertRaisesRegex(ForgeServerAdapterError, "exact product target"):
            adapter.assess_update(request)
        runner.bad_digest = False
        adapter.staged_artifacts[ARTIFACT.digest] = root / "staged" / "forge-current.whl"
        runner.state = "UP_TO_DATE"
        current = ComponentOperationRequest(
            "forge-assess-current", "forge-runtime", "update", ARTIFACT,
            self.target.instance_id, "server", {},
        )
        self.assertEqual(adapter.assess_update(current).state, "UP_TO_DATE")
        runner.state = "UPDATE_AVAILABLE"
        with self.assertRaisesRegex(ForgeServerAdapterError, "installed artifact as an update"):
            adapter.assess_update(current)
        binding_wrong = ForgeUpdateBinding(
            binding.updater_executable, binding.qualification_receipt,
            binding.qualification_receipt_sha256, binding.controller_source,
            binding.controller_sha256, binding.resolver, binding.resolver_sha256,
            binding.runtime_root, "other-runtime", binding.installation_id,
            binding.peer_configuration_digest, binding.existing_interpreter,
            binding.existing_version, binding.base_python,
        )
        adapter.update_binding = binding_wrong
        with self.assertRaisesRegex(ForgeServerAdapterError, "runtime identity"):
            adapter.assess_update(request)
        self.assertEqual(len([call for call in runner.calls if "update-assess" in call]), 10)


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

        class WrongInstanceProbe:
            def readiness(self, target):
                return {"ready": True, "instance_id": "other-instance"}

        self.adapter.readiness_probe = WrongInstanceProbe()
        with self.assertRaisesRegex(ForgeServerAdapterError, "different instance"):
            self.adapter.readback(self.request("repair"))

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
        with self.assertRaisesRegex(ForgeServerAdapterError, "operation identity"):
            self.adapter.resume(
                self.request("repair", "repair-1"),
                replace(receipt, installation_identity="forge-other"),
            )
        resumed = self.adapter.resume(self.request("repair", "repair-1"), receipt)
        self.assertEqual(resumed.state, "COMPLETED")

    def test_exact_up_to_date_assessment_and_external_updater_success_path(self) -> None:
        self.assertEqual(self.adapter.assess_update(self.request("update")).state, "UNKNOWN")
        root = Path(self.temp.name).resolve()
        candidate = QualifiedArtifact(
            "2.7.35", "b" * 40, ARTIFACT.source,
            "sha256:" + "c" * 64, ARTIFACT.qualification,
        )
        intent_root = root / "update-intents"
        intent_root.mkdir(mode=0o700)
        binding = ForgeUpdateBinding(
            updater_executable=Path("/opt/forge/bin/update-installed-forge"),
            qualification_receipt=root / "qualification.json",
            qualification_receipt_sha256="sha256:" + "d" * 64,
            controller_source="b" * 40,
            controller_sha256="sha256:" + "c" * 64,
            resolver=root / "resolver.json",
            resolver_sha256="sha256:" + "a" * 64,
            runtime_root=root / "runtimes",
            runtime_id=self.target.instance_id,
            installation_id="forge-installation",
            peer_configuration_digest="sha256:" + "e" * 64,
            existing_interpreter=Path("/opt/forge/2.7.34/bin/python"),
            existing_version="2.7.34",
            base_python=Path("/usr/bin/python3"),
            intent_root=intent_root,
        )
        wheel = root / "forge_autonomy-2.7.35-py3-none-any.whl"

        class ReceiptRunner(Runner):
            overrides: dict[str, object] = {}
            updated = False
            assessment_state = "UPDATE_AVAILABLE"

            def run(self, argv):
                args = tuple(argv)
                if "update-assess" in args:
                    self.calls.append(args)
                    selected = {
                        "runtime_id": args[args.index("--runtime-id") + 1],
                        "installation_id": args[args.index("--installation-id") + 1],
                        "version": args[args.index("--installed-version") + 1],
                        "source_revision": args[args.index("--installed-source") + 1],
                        "artifact_digest": args[args.index("--installed-artifact-digest") + 1],
                    }
                    candidate_value = {
                        "version": args[args.index("--candidate-version") + 1],
                        "source_revision": args[args.index("--candidate-source") + 1],
                        "artifact_digest": args[args.index("--candidate-artifact-digest") + 1],
                    }
                    assessment = {
                        "contract": "forge-server-runtime-lifecycle/v1",
                        "operation": "UPDATE_ASSESSMENT", "state": self.assessment_state,
                        "mutating": False, "selected_installation": selected,
                        "candidate": candidate_value,
                        "reason_codes": ["EXACT_SUPPORTED_TRANSITION"], "evidence": {},
                    }
                    assessment["assessment_digest"] = "sha256:" + hashlib.sha256(
                        (json.dumps(assessment, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
                    ).hexdigest()
                    return ForgeCommandResult(0, json.dumps(assessment), "")
                if args[-2:] == ("server", "status"):
                    observed = super().run(args)
                    if self.updated:
                        value = json.loads(observed.stdout)
                        value["product_version"] = candidate.version
                        return ForgeCommandResult(0, json.dumps(value), "")
                    return observed
                if args[0] != "/opt/forge/bin/update-installed-forge":
                    return super().run(args)
                self.calls.append(args)
                self.updated = True
                selected = {
                    name.replace("-", "_"): args[args.index("--" + name) + 1]
                    for name in (
                        "operation-id", "version", "product-source", "wheel", "wheel-sha256",
                        "qualification-receipt", "qualification-receipt-sha256",
                        "controller-source", "controller-sha256", "data-root", "runtime-root",
                        "runtime-id", "installation-id", "peer-configuration-digest",
                        "resolver", "resolver-sha256", "existing-interpreter", "existing-version",
                        "base-python",
                    )
                }
                selected["request_digest"] = "sha256:" + hashlib.sha256(
                    (json.dumps(selected, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
                ).hexdigest()
                payload = {
                    "contract_version": "forge-installed-update/v1",
                    "operation_id": selected["operation_id"],
                    "request_digest": selected["request_digest"],
                    "state": "COMPLETE", "product": "forge",
                    "version": selected["version"],
                    "product_source": selected["product_source"],
                    "wheel_sha256": selected["wheel_sha256"],
                    "controller_source": selected["controller_source"],
                    "controller_sha256": selected["controller_sha256"],
                    "runtime_id": selected["runtime_id"],
                    "installation_id": selected["installation_id"],
                    "data_root": selected["data_root"],
                    "backup": {"sha256": "sha256:" + "f" * 64},
                    "migration_qualification": {"status": "PASS"},
                    "live_migration": {"status": "PASS"},
                    "installed_readback": {"preservation": {"status": "PASS"}},
                    "credential_disposition": "PRESERVED_UNCHANGED",
                    "service_disposition": "NOT_STARTED",
                    "mission_disposition": "NOT_STARTED_OR_RESUMED",
                    "reset_disposition": "NOT_EXECUTED",
                }
                payload.update(self.overrides)
                return ForgeCommandResult(0, json.dumps(payload), "")

        runner = ReceiptRunner()
        runner.initialized = True
        self.supervisor.running = True
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target,
            installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel},
            supervisor=self.supervisor,
            runner=runner,
            readiness_probe=Probe(),
            update_binding=binding,
        )
        draft_req = ComponentOperationRequest(
            "forge-update-0001", "forge-runtime", "update", candidate,
            self.prepared.instance_id, "server", {},
        )
        req = replace(draft_req, product_request={
            "reviewed_update_assessment_reference": adapter.assess_update(draft_req).evidence_reference,
        })
        receipt = adapter.execute(req)
        self.assertEqual(receipt.state, "COMPLETED")
        self.assertTrue(receipt.evidence_reference.startswith("forge-update:sha256:"))
        self.assertEqual(adapter.installed_artifact, candidate)
        self.assertEqual(ForgeUpdateIntentStore(intent_root).read(req.operation_id).phase, "COMPLETE")
        supervisor_calls = tuple(self.supervisor.calls)
        self.assertEqual(adapter.execute(req), receipt)
        self.assertEqual(tuple(self.supervisor.calls), supervisor_calls)
        replay_adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=Probe(), update_binding=binding,
        )
        self.assertEqual(replay_adapter.execute(req), receipt)
        self.assertEqual(tuple(self.supervisor.calls), supervisor_calls)
        other_target = ForgeServerTarget(
            "forge-instance-2", root / "instances" / "other", root / "instances",
            "_forge_other", 9001, root / "credentials" / "other-api",
        )
        other_supervisor = Supervisor()
        other_adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=other_target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=other_supervisor,
            runner=runner, readiness_probe=Probe(),
            update_binding=replace(binding, runtime_id=other_target.instance_id),
        )
        other_request = ComponentOperationRequest(
            req.operation_id, "forge-runtime", "update", candidate,
            other_target.instance_id, "server", req.product_request,
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "exact operation selection"):
            other_adapter.execute(other_request)
        self.assertEqual(other_supervisor.calls, [])
        changed_candidate = replace(candidate, digest="sha256:" + "f" * 64)
        with self.assertRaisesRegex(ForgeServerAdapterError, "installed artifact changed"):
            adapter.execute(replace(req, artifact=changed_candidate))

        wrong_review_root = root / "update-intents-wrong-review"
        wrong_review_root.mkdir(mode=0o700)
        runner.updated = False
        self.supervisor.running = True
        wrong_review_adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=Probe(),
            update_binding=replace(binding, intent_root=wrong_review_root),
        )
        before_wrong_review = tuple(self.supervisor.calls)
        with self.assertRaisesRegex(ForgeServerAdapterError, "drifted after review"):
            wrong_review_adapter.execute(replace(
                req, operation_id="forge-update-wrong-review",
                product_request={
                    "reviewed_update_assessment_reference": "forge-update-assess:sha256:" + "0" * 64,
                },
            ))
        self.assertEqual(tuple(self.supervisor.calls), before_wrong_review)

        prepared_root = root / "update-intents-prepared"
        prepared_root.mkdir(mode=0o700)
        prepared_request = replace(
            req, operation_id="forge-update-prepared",
            product_request={
                "reviewed_update_assessment_reference": "forge-update-assess:sha256:" + "0" * 64,
            },
        )
        prepared_store = ForgeUpdateIntentStore(prepared_root)
        prepared_store.prepare(ForgeUpdateIntent(
            prepared_request.operation_id, prepared_request.fingerprint(),
            self.target.instance_id, ARTIFACT.digest, candidate.digest,
            "forge-update-assess:sha256:" + "0" * 64,
        ))
        runner.updated = False
        self.supervisor.running = True
        prepared_adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=Probe(),
            update_binding=replace(binding, intent_root=prepared_root),
        )
        pre_drift_calls = tuple(self.supervisor.calls)
        with self.assertRaisesRegex(ForgeServerAdapterError, "assessment drifted after review"):
            prepared_adapter.execute(prepared_request)
        self.assertEqual(tuple(self.supervisor.calls), pre_drift_calls)
        call = next(call for call in runner.calls if call[0] == "/opt/forge/bin/update-installed-forge")
        self.assertEqual(call[0], "/opt/forge/bin/update-installed-forge")
        self.assertIn("--qualification-receipt", call)
        self.assertIn(str(wheel), call)
        self.assertEqual(call[call.index("--wheel-sha256") + 1], candidate.digest)
        for index, mismatch in enumerate((
            {"operation_id": "foreign-operation"},
            {"request_digest": "sha256:" + "0" * 64},
            {"state": "RECOVERY_PENDING"},
            {"installed_readback": {}},
            {"credential_disposition": "UNKNOWN"},
            {"contract_version": None},
        )):
            runner.overrides = mismatch
            runner.updated = False
            self.supervisor.running = True
            bad_root = root / f"update-intents-bad-{index}"
            bad_root.mkdir(mode=0o700)
            retry = ForgeServerProductAdapter(
                forge_executable=Path("/opt/forge/bin/forge"),
                lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
                target=self.target,
                installed_artifact=ARTIFACT, staged_artifacts={candidate.digest: wheel},
                supervisor=self.supervisor, runner=runner, readiness_probe=Probe(),
                update_binding=replace(binding, intent_root=bad_root),
            )
            retry_req = ComponentOperationRequest(
                f"forge-update-bad-{index}", "forge-runtime", "update", candidate,
                self.prepared.instance_id, "server", req.product_request,
            )
            with self.assertRaisesRegex(ForgeServerAdapterError, "terminal product receipt"):
                retry.execute(retry_req)
            self.assertEqual(retry.installed_artifact, ARTIFACT)
            self.assertEqual(ForgeUpdateIntentStore(bad_root).read(retry_req.operation_id).phase, "UPDATER_INVOKED")
            if index == 0:
                runner.overrides = {}
                restarted = ForgeServerProductAdapter(
                    forge_executable=Path("/opt/forge/bin/forge"),
                    lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
                    target=self.target, installed_artifact=ARTIFACT,
                    staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
                    runner=runner, readiness_probe=Probe(),
                    update_binding=replace(binding, intent_root=bad_root),
                )
                recovered = restarted.execute(retry_req)
                self.assertEqual(recovered.state, "COMPLETED")
                self.assertEqual(ForgeUpdateIntentStore(bad_root).read(retry_req.operation_id).phase, "COMPLETE")
        runner.overrides = {}
        runner.updated = False
        runner.assessment_state = "UNKNOWN"
        self.supervisor.running = True
        self.supervisor.calls.clear()
        stale = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=Probe(), update_binding=binding,
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "fresh update"):
            stale.execute(ComponentOperationRequest(
                "forge-update-stale", "forge-runtime", "update", candidate,
                self.prepared.instance_id, "server", req.product_request,
            ))
        self.assertEqual(self.supervisor.calls, [])
        runner.assessment_state = "UPDATE_AVAILABLE"
        runner.updated = False
        self.supervisor.running = True

        class ReadinessLostAfterRestart:
            def readiness(self, target):
                return {
                    "ready": "stop" not in self_supervisor.calls,
                    "instance_id": target.instance_id,
                }

        self_supervisor = self.supervisor
        not_ready = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=ReadinessLostAfterRestart(),
            update_binding=binding,
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "restore exact instance readiness"):
            not_ready_request = ComponentOperationRequest(
                "forge-update-not-ready", "forge-runtime", "update", candidate,
                self.prepared.instance_id, "server", req.product_request,
            )
            not_ready.execute(not_ready_request)
        self.assertEqual(ForgeUpdateIntentStore(intent_root).read(not_ready_request.operation_id).phase, "PRODUCT_COMPLETE")
        updater_calls = len([call for call in runner.calls if call[0] == "/opt/forge/bin/update-installed-forge"])
        restarted = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"),
            lifecycle_executable=Path("/opt/forge/lifecycle-2.7.35/bin/forge"),
            target=self.target, installed_artifact=ARTIFACT,
            staged_artifacts={candidate.digest: wheel}, supervisor=self.supervisor,
            runner=runner, readiness_probe=Probe(), update_binding=binding,
        )
        self.assertEqual(restarted.execute(not_ready_request).state, "COMPLETED")
        self.assertEqual(len([call for call in runner.calls if call[0] == "/opt/forge/bin/update-installed-forge"]), updater_calls)

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
            adapter._run_update(req)

        class FailedUpdateRunner(Runner):
            def run(self, argv):
                if tuple(argv)[0] == "/opt/updater":
                    return ForgeCommandResult(0, '{"status":"COMPLETE"}', "")
                return super().run(argv)
        adapter = ForgeServerProductAdapter(
            forge_executable=Path("/opt/forge/bin/forge"), target=self.target,
            installed_artifact=ARTIFACT, staged_artifacts={candidate.digest: root / "wheel.whl"},
            supervisor=self.supervisor, runner=FailedUpdateRunner(),
            readiness_probe=Probe(), update_binding=binding,
        )
        with self.assertRaisesRegex(ForgeServerAdapterError, "terminal product receipt"):
            adapter._run_update(req)


if __name__ == "__main__":
    unittest.main()
