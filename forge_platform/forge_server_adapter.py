"""Forge 2.7.34 Server adapter for one managed Forge instance.

Forge owns instance initialization, provider/peer configuration, Server
readiness and update semantics. Forge Platform owns the surrounding system
service/filesystem choreography explicitly assigned by the frozen deployment
contract. No Forge database is read or rewritten here.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
from typing import Mapping, Protocol, Sequence
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError

from .component_operations import (
    ComponentOperationRequest,
    ProductInstallationReadback,
    ProductOperationAdapter,
    ProductOperationReceipt,
    ProductUpdateAssessment,
    QualifiedArtifact,
)


FORGE_COMPONENT = "forge-runtime"
FORGE_PROVIDER_ID = "codex-chatgpt-session"


class ForgeServerAdapterError(RuntimeError):
    """The exact Forge Server instance cannot be proven or safely operated."""


@dataclass(frozen=True)
class ForgeCommandResult:
    returncode: int
    stdout: str
    stderr: str


class ForgeCommandRunner(Protocol):
    def run(self, argv: Sequence[str]) -> ForgeCommandResult: ...


class SubprocessForgeCommandRunner:
    def run(self, argv: Sequence[str]) -> ForgeCommandResult:
        if not argv or not Path(argv[0]).is_absolute():
            raise ForgeServerAdapterError("Forge executable must be absolute")
        completed = subprocess.run(
            tuple(argv),
            text=True,
            capture_output=True,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONNOUSERSITE": "1", "PYTHONSAFEPATH": "1"},
        )
        return ForgeCommandResult(completed.returncode, completed.stdout, completed.stderr)


@dataclass(frozen=True)
class ForgePreparedInstance:
    instance_id: str
    data_root: Path


@dataclass(frozen=True)
class ForgeServerTarget:
    instance_id: str
    data_root: Path
    instances_root: Path
    service_account: str
    bind_port: int
    api_credential_file: Path

    def __post_init__(self) -> None:
        if not isinstance(self.instance_id, str) or not self.instance_id:
            raise ValueError("Forge target instance_id is required")
        for label, path in (
            ("data_root", self.data_root),
            ("instances_root", self.instances_root),
            ("api_credential_file", self.api_credential_file),
        ):
            if not isinstance(path, Path) or not path.is_absolute():
                raise ValueError(f"Forge target {label} must be absolute")
        resolved_root = self.instances_root.resolve(strict=False)
        resolved_data = self.data_root.resolve(strict=False)
        if resolved_data == resolved_root or not resolved_data.is_relative_to(resolved_root):
            raise ValueError("Forge data_root must be contained by the installer-owned instances_root")
        if not isinstance(self.service_account, str) or not self.service_account:
            raise ValueError("Forge service_account is required")
        if isinstance(self.bind_port, bool) or not isinstance(self.bind_port, int) or not 1 <= self.bind_port <= 65535:
            raise ValueError("Forge bind_port is invalid")

    @property
    def service_label(self) -> str:
        digest = sha256(self.instance_id.encode("utf-8")).hexdigest()[:20]
        return f"com.forgeplatform.forge-server.instance-{digest}"


class ForgeServiceSupervisor(Protocol):
    def register(self, target: ForgeServerTarget, forge_executable: Path) -> Mapping[str, object]: ...
    def start(self, target: ForgeServerTarget) -> Mapping[str, object]: ...
    def stop(self, target: ForgeServerTarget) -> Mapping[str, object]: ...
    def remove(self, target: ForgeServerTarget) -> Mapping[str, object]: ...
    def loaded(self, target: ForgeServerTarget) -> bool: ...


class MacOSForgeLaunchDaemonSupervisor:
    """Fixed-command system LaunchDaemon supervision; account creation is separate."""

    def __init__(self, launch_daemons_dir: Path = Path("/Library/LaunchDaemons")) -> None:
        if not launch_daemons_dir.is_absolute():
            raise ValueError("LaunchDaemon directory must be absolute")
        self.launch_daemons_dir = launch_daemons_dir

    def _plist_path(self, target: ForgeServerTarget) -> Path:
        return self.launch_daemons_dir / f"{target.service_label}.plist"

    @staticmethod
    def _launchctl(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(("/bin/launchctl", *args), text=True, capture_output=True, check=False)

    def register(self, target: ForgeServerTarget, forge_executable: Path) -> Mapping[str, object]:
        if os.geteuid() != 0:
            raise ForgeServerAdapterError("Forge system LaunchDaemon registration requires root")
        try:
            account = pwd.getpwnam(target.service_account)
        except KeyError as error:
            raise ForgeServerAdapterError("Forge service account is unavailable") from error
        if account.pw_uid <= 0:
            raise ForgeServerAdapterError("Forge service account must be non-root")
        if not forge_executable.is_absolute():
            raise ForgeServerAdapterError("Forge executable must be absolute")
        target.data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        logs = target.data_root / "logs"
        logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = {
            "Label": target.service_label,
            "ProgramArguments": [
                str(forge_executable), "--data-root", str(target.data_root),
                "server", "run",
                "--credential-file", str(target.api_credential_file),
                "--host", "127.0.0.1",
                "--port", str(target.bind_port),
                "--provider-id", FORGE_PROVIDER_ID,
            ],
            "UserName": target.service_account,
            "WorkingDirectory": str(target.data_root),
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ProcessType": "Background",
            "StandardOutPath": str(logs / "launchd.stdout.log"),
            "StandardErrorPath": str(logs / "launchd.stderr.log"),
        }
        self.launch_daemons_dir.mkdir(parents=True, exist_ok=True)
        destination = self._plist_path(target)
        temporary = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(descriptor, "wb") as handle:
                plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=True)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        return {"result": "REGISTERED", "label": target.service_label}

    def start(self, target: ForgeServerTarget) -> Mapping[str, object]:
        if not self.loaded(target):
            result = self._launchctl("bootstrap", "system", str(self._plist_path(target)))
            if result.returncode:
                raise ForgeServerAdapterError("Forge LaunchDaemon could not be started")
        return {"result": "RUNNING", "label": target.service_label}

    def stop(self, target: ForgeServerTarget) -> Mapping[str, object]:
        result = self._launchctl("bootout", "system", str(self._plist_path(target)))
        if result.returncode and self.loaded(target):
            raise ForgeServerAdapterError("Forge LaunchDaemon could not be stopped")
        return {"result": "STOPPED", "label": target.service_label}

    def remove(self, target: ForgeServerTarget) -> Mapping[str, object]:
        self.stop(target)
        self._plist_path(target).unlink(missing_ok=True)
        return {"result": "REMOVED", "label": target.service_label}

    def loaded(self, target: ForgeServerTarget) -> bool:
        return self._launchctl("print", f"system/{target.service_label}").returncode == 0


class ForgeReadinessProbe(Protocol):
    def readiness(self, target: ForgeServerTarget) -> Mapping[str, object]: ...


class ForgeHTTPReadinessProbe:
    """Authenticated loopback readiness; bearer bytes are never returned/logged."""

    def readiness(self, target: ForgeServerTarget) -> Mapping[str, object]:
        try:
            token = target.api_credential_file.read_text(encoding="utf-8").strip()
        except (OSError, UnicodeError) as error:
            raise ForgeServerAdapterError("Forge API credential file is unavailable") from error
        if not token:
            raise ForgeServerAdapterError("Forge API credential file is empty")
        req = urllib_request.Request(
            f"http://127.0.0.1:{target.bind_port}/v1/readiness",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        )
        try:
            with urllib_request.urlopen(req, timeout=5) as response:
                raw = response.read(1_048_577)
        except (HTTPError, URLError, TimeoutError, OSError) as error:
            raise ForgeServerAdapterError("Forge Server readiness is unavailable") from error
        if len(raw) > 1_048_576:
            raise ForgeServerAdapterError("Forge Server readiness exceeded the response bound")
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ForgeServerAdapterError("Forge Server readiness returned invalid JSON") from error
        if not isinstance(value, Mapping):
            raise ForgeServerAdapterError("Forge Server readiness is not a JSON object")
        return value


@dataclass(frozen=True)
class ForgeUpdateBinding:
    updater_executable: Path
    qualification_receipt: Path
    qualification_receipt_sha256: str
    controller_source: str
    controller_sha256: str
    resolver: Path
    resolver_sha256: str
    runtime_root: Path
    runtime_id: str
    installation_id: str
    peer_configuration_digest: str
    existing_interpreter: Path
    existing_version: str
    base_python: Path

    def __post_init__(self) -> None:
        for value in (
            self.updater_executable, self.qualification_receipt, self.resolver,
            self.runtime_root, self.existing_interpreter, self.base_python,
        ):
            if not isinstance(value, Path) or not value.is_absolute():
                raise ValueError("Forge update binding paths must be absolute")


class ForgeServerProductAdapter(ProductOperationAdapter):
    def __init__(
        self,
        *,
        forge_executable: Path,
        target: ForgeServerTarget,
        installed_artifact: QualifiedArtifact,
        staged_artifacts: Mapping[str, Path],
        supervisor: ForgeServiceSupervisor,
        runner: ForgeCommandRunner | None = None,
        readiness_probe: ForgeReadinessProbe | None = None,
        update_binding: ForgeUpdateBinding | None = None,
    ) -> None:
        if not forge_executable.is_absolute():
            raise ValueError("Forge executable must be absolute")
        self.forge_executable = forge_executable
        self.target = target
        self.installed_artifact = installed_artifact
        self.staged_artifacts = dict(staged_artifacts)
        self.supervisor = supervisor
        self.runner = runner or SubprocessForgeCommandRunner()
        self.readiness_probe = readiness_probe or ForgeHTTPReadinessProbe()
        self.update_binding = update_binding

    @staticmethod
    def prepare_instance(
        *,
        forge_executable: Path,
        data_root: Path,
        runner: ForgeCommandRunner | None = None,
    ) -> ForgePreparedInstance:
        if not forge_executable.is_absolute() or not data_root.is_absolute():
            raise ValueError("Forge prepare paths must be absolute")
        command_runner = runner or SubprocessForgeCommandRunner()
        result = command_runner.run((str(forge_executable), "--data-root", str(data_root), "server", "status"))
        status = ForgeServerProductAdapter._json_result(result, "Forge server status", allow_nonzero=True)
        if status.get("initialized") is not True:
            result = command_runner.run((str(forge_executable), "--data-root", str(data_root), "server", "init"))
            status = ForgeServerProductAdapter._json_result(result, "Forge server init")
        instance_id = status.get("instance_id")
        if not isinstance(instance_id, str) or not instance_id:
            raise ForgeServerAdapterError("Forge init did not return an authoritative instance identity")
        return ForgePreparedInstance(instance_id, data_root)

    @staticmethod
    def _json_result(
        result: ForgeCommandResult,
        label: str,
        *,
        allow_nonzero: bool = False,
    ) -> Mapping[str, object]:
        raw = result.stdout if result.stdout.strip() else result.stderr
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ForgeServerAdapterError(f"{label} returned invalid JSON") from error
        if not isinstance(value, Mapping):
            raise ForgeServerAdapterError(f"{label} is not a JSON object")
        if result.returncode != 0 and not allow_nonzero:
            raise ForgeServerAdapterError(f"{label} failed")
        return value

    def _run(self, *args: str, allow_nonzero: bool = False) -> Mapping[str, object]:
        result = self.runner.run((str(self.forge_executable), "--data-root", str(self.target.data_root), *args))
        return self._json_result(result, "Forge command", allow_nonzero=allow_nonzero)

    def _validate_request(self, request: ComponentOperationRequest) -> None:
        if request.component != FORGE_COMPONENT or request.requested_role not in {"server", "runtime"}:
            raise ForgeServerAdapterError("Forge adapter supports only the Forge Server runtime role")
        if request.installation_identity != self.target.instance_id:
            raise ForgeServerAdapterError("Forge request does not target the initialized product instance")
        if request.product_request:
            raise ForgeServerAdapterError("Forge adapter accepts no generic product_request extension")

    def configure_provider_context(
        self,
        *,
        codex_executable: Path,
        provider_home: Path,
        provider_config_home: Path,
        expected_digest: str | None = None,
    ) -> Mapping[str, object]:
        args = [
            "server", "provider-context", "configure",
            "--provider-id", FORGE_PROVIDER_ID,
            "--provider-type", "CODEX_CLI_CHATGPT_SESSION",
            "--executable-path", str(codex_executable),
            "--provider-home", str(provider_home),
            "--provider-config-home", str(provider_config_home),
        ]
        if expected_digest is not None:
            args += ["--expected-digest", expected_digest]
        return self._run(*args)

    def configure_ep_peer(
        self,
        *,
        binding_id: str,
        endpoint: str,
        expected_instance_id: str,
        consumer_id: str,
        host_id: str,
        project_id: str,
        repository_id: str,
        repository_identity: str,
        credential_reference: str,
        operator_id: str,
        allow_loopback_http: bool = True,
    ) -> Mapping[str, object]:
        args = [
            "execution-host", "configure",
            "--binding-id", binding_id,
            "--endpoint", endpoint,
            "--expected-instance-id", expected_instance_id,
            "--consumer-id", consumer_id,
            "--host-id", host_id,
            "--project-id", project_id,
            "--repository-id", repository_id,
            "--repository-identity", repository_identity,
            "--credential-reference", credential_reference,
            "--operator-id", operator_id,
        ]
        if allow_loopback_http:
            args.append("--allow-loopback-http")
        return self._run(*args)

    def readback(self, request: ComponentOperationRequest) -> ProductInstallationReadback:
        self._validate_request(request)
        status = self._run("server", "status", allow_nonzero=True)
        if status.get("initialized") is not True:
            return ProductInstallationReadback(
                FORGE_COMPONENT, self.target.instance_id, "ABSENT",
                None, None, None, None, None, "UNKNOWN", "MACHINE_WIDE", "NONE",
                "forge-status:" + _digest_json(status),
            )
        if status.get("instance_id") != self.target.instance_id:
            raise ForgeServerAdapterError("Forge status returned a different instance identity")
        if status.get("product_version") != self.installed_artifact.version:
            raise ForgeServerAdapterError("Forge status version does not match the selected installed artifact")
        if not self.supervisor.loaded(self.target):
            return ProductInstallationReadback(
                FORGE_COMPONENT, self.target.instance_id, "ABSENT",
                None, None, None, None, None, "UNKNOWN", "MACHINE_WIDE", "NONE",
                "forge-status:" + _digest_json(status),
            )
        health = self._run("health", "snapshot", allow_nonzero=True)
        try:
            readiness = self.readiness_probe.readiness(self.target)
        except ForgeServerAdapterError:
            readiness = {"ready": False}
        ready = health.get("outcome") == "HEALTHY" and readiness.get("ready") is True
        evidence = "forge-health:" + _digest_json({"health": health, "readiness": readiness})
        return ProductInstallationReadback(
            FORGE_COMPONENT,
            self.target.instance_id,
            "ACTIVE" if ready else "UNHEALTHY",
            "forge-runtime:" + self.installed_artifact.digest,
            "forge-executable:" + _digest_json({
                "instance_id": self.target.instance_id,
                "artifact": self.installed_artifact.digest,
                "executable": str(self.forge_executable),
            }),
            self.target.service_label,
            self.target.instance_id,
            self.installed_artifact.correlation,
            "HEALTHY" if ready else "UNHEALTHY",
            "MACHINE_WIDE",
            "NONE",
            "forge-status:" + _digest_json(status),
            evidence,
        )

    def assess_update(self, request: ComponentOperationRequest) -> ProductUpdateAssessment:
        self._validate_request(request)
        if request.kind != "update":
            raise ForgeServerAdapterError("Forge update assessment requires update kind")
        if self.update_binding is None:
            state = "UNKNOWN"
        elif request.artifact.version == self.installed_artifact.version and request.artifact.digest == self.installed_artifact.digest:
            state = "UP_TO_DATE"
        else:
            # The external Forge updater performs the authoritative version /
            # schema / artifact / peer checks again immediately before mutation.
            state = "UPDATE_AVAILABLE"
        return ProductUpdateAssessment(
            FORGE_COMPONENT,
            self.target.instance_id,
            request.artifact.correlation,
            state,
            "forge-update-assess:" + _digest_json({
                "instance_id": self.target.instance_id,
                "candidate": request.artifact.correlation.__dict__,
                "updater_bound": self.update_binding is not None,
            }),
        )

    def execute(self, request: ComponentOperationRequest) -> ProductOperationReceipt:
        self._validate_request(request)
        if request.kind in {"install", "repair"}:
            self.supervisor.register(self.target, self.forge_executable)
            self.supervisor.start(self.target)
            state = "COMPLETED"
        elif request.kind == "remove":
            self.supervisor.remove(self.target)
            expected_root = self.target.instances_root.resolve(strict=False)
            data_root = self.target.data_root.resolve(strict=False)
            if data_root == expected_root or not data_root.is_relative_to(expected_root):
                raise ForgeServerAdapterError("Forge removal target escaped installer-owned instances root")
            shutil.rmtree(data_root, ignore_errors=False)
            state = "COMPLETED"
        elif request.kind == "update":
            self._run_update(request)
            self.installed_artifact = request.artifact
            state = "COMPLETED"
        else:
            raise ForgeServerAdapterError("Forge operation kind is unsupported")
        return ProductOperationReceipt(
            request.operation_id,
            FORGE_COMPONENT,
            self.target.instance_id,
            request.artifact.correlation,
            state,
            "forge-operation:" + _digest_json({
                "operation_id": request.operation_id,
                "kind": request.kind,
                "instance_id": self.target.instance_id,
                "artifact": request.artifact.correlation.__dict__,
            }),
        )

    def resume(
        self,
        request: ComponentOperationRequest,
        prior_receipt: ProductOperationReceipt,
    ) -> ProductOperationReceipt:
        self._validate_request(request)
        if prior_receipt.product_operation_id != request.operation_id:
            raise ForgeServerAdapterError("Forge resume operation identity changed")
        # Forge's updater is itself durable/idempotent under the same operation
        # ID; install/repair/remove are re-read before ComponentOperationCoordinator
        # calls this method and have no custom pending receipt state here.
        return self.execute(request)

    def _run_update(self, request: ComponentOperationRequest) -> None:
        binding = self.update_binding
        if binding is None:
            raise ForgeServerAdapterError("Forge qualified external updater binding is unavailable")
        wheel = self.staged_artifacts.get(request.artifact.digest)
        if not isinstance(wheel, Path) or not wheel.is_absolute():
            raise ForgeServerAdapterError("Forge staged update wheel is unavailable")
        argv = (
            str(binding.updater_executable),
            "--operation-id", request.operation_id,
            "--version", request.artifact.version,
            "--product-source", request.artifact.source_revision,
            "--wheel", str(wheel),
            "--wheel-sha256", request.artifact.digest.removeprefix("sha256:"),
            "--qualification-receipt", str(binding.qualification_receipt),
            "--qualification-receipt-sha256", binding.qualification_receipt_sha256,
            "--controller-source", binding.controller_source,
            "--controller-sha256", binding.controller_sha256,
            "--data-root", str(self.target.data_root),
            "--runtime-root", str(binding.runtime_root),
            "--runtime-id", binding.runtime_id,
            "--installation-id", binding.installation_id,
            "--peer-configuration-digest", binding.peer_configuration_digest,
            "--resolver", str(binding.resolver),
            "--resolver-sha256", binding.resolver_sha256,
            "--existing-interpreter", str(binding.existing_interpreter),
            "--existing-version", binding.existing_version,
            "--base-python", str(binding.base_python),
        )
        result = self.runner.run(argv)
        payload = self._json_result(result, "Forge installed updater")
        if payload.get("state") not in {"COMPLETE", None} and payload.get("status") not in {"COMPLETE", "SUCCESS"}:
            raise ForgeServerAdapterError("Forge installed updater did not complete")


def _digest_json(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
    return "sha256:" + sha256(encoded).hexdigest()
