"""Concrete adapter for the frozen Engineering Platform 2.3.102 system provisioner.

The adapter invokes only the published `engineering-platform-system-provisioner`
contract with a fixed absolute executable and product root. Runtime/service/data
selection remains inside EP. Forge Platform supplies an exact instance target,
a staged qualified wheel and operation identity, then validates EP's JSON
readback/receipt correlation.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
from typing import Mapping, Protocol, Sequence

from .component_operations import (
    ArtifactCorrelation,
    ComponentOperationRequest,
    ProductInstallationReadback,
    ProductOperationAdapter,
    ProductOperationReceipt,
    ProductUpdateAssessment,
    QualifiedArtifact,
)


EP_SYSTEM_PROVISIONER_CONTRACT = "engineering-platform.system-provisioner/v1"
EP_COMPONENT = "engineering-platform-server"


class EngineeringPlatformAdapterError(RuntimeError):
    """EP rejected, contradicted, or could not prove the exact target operation."""


@dataclass(frozen=True)
class EPSystemInstanceTarget:
    instance_id: str
    display_label: str
    service_account: str
    bind_port: int

    def __post_init__(self) -> None:
        for label, value in (
            ("instance_id", self.instance_id),
            ("display_label", self.display_label),
            ("service_account", self.service_account),
        ):
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"EP target {label} is required")
        if isinstance(self.bind_port, bool) or not isinstance(self.bind_port, int) or not 1 <= self.bind_port <= 65535:
            raise ValueError("EP target bind_port is invalid")


@dataclass(frozen=True)
class ProductCommandResult:
    returncode: int
    stdout: str
    stderr: str


class ProductCommandRunner(Protocol):
    def run(self, argv: Sequence[str]) -> ProductCommandResult: ...


class SubprocessProductCommandRunner:
    """Run one fixed absolute product executable without ambient PATH authority."""

    def run(self, argv: Sequence[str]) -> ProductCommandResult:
        if not argv or not Path(argv[0]).is_absolute():
            raise EngineeringPlatformAdapterError("EP provisioner executable must be absolute")
        completed = subprocess.run(
            tuple(argv),
            text=True,
            capture_output=True,
            check=False,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PYTHONNOUSERSITE": "1",
                "PYTHONSAFEPATH": "1",
            },
        )
        return ProductCommandResult(completed.returncode, completed.stdout, completed.stderr)


def _canonical_digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return "sha256:" + sha256(encoded).hexdigest()


def _mapping(value: object, label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise EngineeringPlatformAdapterError(f"{label} is not a JSON object")
    return value


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise EngineeringPlatformAdapterError(f"{label} is missing")
    return value


class EngineeringPlatformSystemProvisionerAdapter(ProductOperationAdapter):
    """One exact EP system instance target.

    The generic component request carries no EP filesystem/service internals.
    The adapter's target is selected by the managed-deployment coordinator and
    EP remains the authority that derives its service label, roots and runtime.
    """

    def __init__(
        self,
        *,
        provisioner_executable: Path,
        product_root: Path,
        target: EPSystemInstanceTarget,
        staged_artifacts: Mapping[str, Path],
        runner: ProductCommandRunner | None = None,
    ) -> None:
        if not provisioner_executable.is_absolute() or not product_root.is_absolute():
            raise ValueError("EP adapter paths must be absolute")
        self.provisioner_executable = provisioner_executable
        self.product_root = product_root
        self.target = target
        self.staged_artifacts = dict(staged_artifacts)
        self.runner = runner or SubprocessProductCommandRunner()

    def _validate_request(self, request: ComponentOperationRequest) -> None:
        if not isinstance(request, ComponentOperationRequest):
            raise EngineeringPlatformAdapterError("EP adapter requires a component operation request")
        if request.component != EP_COMPONENT or request.requested_role != "server":
            raise EngineeringPlatformAdapterError("EP adapter supports only the EP Server role")
        if request.installation_identity != self.target.instance_id:
            raise EngineeringPlatformAdapterError("EP request does not target the configured instance")
        if request.product_request:
            raise EngineeringPlatformAdapterError("EP system provisioner accepts no generic product_request extension")

    def _artifact_path(self, artifact: QualifiedArtifact) -> Path:
        path = self.staged_artifacts.get(artifact.digest)
        if not isinstance(path, Path) or not path.is_absolute():
            raise EngineeringPlatformAdapterError("EP exact staged wheel is unavailable")
        if path.exists():
            if path.is_symlink() or not path.is_file():
                raise EngineeringPlatformAdapterError("EP staged wheel is unsafe")
            actual = "sha256:" + sha256(path.read_bytes()).hexdigest()
            if actual != artifact.digest:
                raise EngineeringPlatformAdapterError("EP staged wheel digest changed")
        return path

    def _run(self, command: str, *arguments: str) -> Mapping[str, object]:
        argv = (
            str(self.provisioner_executable),
            command,
            "--product-root", str(self.product_root),
            *arguments,
        )
        result = self.runner.run(argv)
        raw = result.stdout if result.returncode == 0 else result.stderr
        try:
            payload = json.loads(raw)
        except (TypeError, json.JSONDecodeError) as error:
            raise EngineeringPlatformAdapterError("EP provisioner returned non-JSON evidence") from error
        wire = _mapping(payload, "EP provisioner result")
        if wire.get("contract") != EP_SYSTEM_PROVISIONER_CONTRACT:
            # Inventory is the one product surface whose machine inventory
            # payload predates the outer command envelope. Accept it only for
            # read-only discovery; all mutating/status operations are contract-bound.
            if command != "inventory":
                raise EngineeringPlatformAdapterError("EP provisioner contract mismatch")
        if result.returncode != 0:
            raise EngineeringPlatformAdapterError("EP provisioner rejected the exact operation")
        return wire

    def _release_arguments(self, artifact: QualifiedArtifact) -> tuple[str, ...]:
        path = self._artifact_path(artifact)
        return (
            "--version", artifact.version,
            "--artifact", str(path),
            "--artifact-digest", artifact.digest,
            "--source-revision", artifact.source_revision,
        )

    def _target_arguments(self) -> tuple[str, ...]:
        return (
            "--instance-id", self.target.instance_id,
            "--display-label", self.target.display_label,
            "--service-account", self.target.service_account,
            "--bind-port", str(self.target.bind_port),
        )

    def inventory(self) -> Mapping[str, object]:
        return self._run("inventory")

    def _inventory_entry(self) -> tuple[Mapping[str, object] | None, Mapping[str, object]]:
        inventory = self.inventory()
        entries = inventory.get("instances")
        if not isinstance(entries, list):
            raise EngineeringPlatformAdapterError("EP inventory lacks instance collection")
        matches = [
            item for item in entries
            if isinstance(item, Mapping) and item.get("instance_id") == self.target.instance_id
        ]
        if len(matches) > 1:
            raise EngineeringPlatformAdapterError("EP inventory contains duplicate target instances")
        return (matches[0] if matches else None), inventory

    def readback(self, request: ComponentOperationRequest) -> ProductInstallationReadback:
        self._validate_request(request)
        entry, inventory = self._inventory_entry()
        inventory_ref = "ep-inventory:" + _canonical_digest(inventory)
        if inventory.get("state") == "AMBIGUOUS":
            return ProductInstallationReadback(
                EP_COMPONENT, self.target.instance_id, "UNKNOWN",
                None, None, None, None, None, "UNKNOWN", "MACHINE_WIDE",
                "CONFLICTING", inventory_ref, None, inventory_ref,
            )
        if entry is None:
            return ProductInstallationReadback(
                EP_COMPONENT, self.target.instance_id, "ABSENT",
                None, None, None, None, None, "UNKNOWN", "MACHINE_WIDE",
                "NONE", inventory_ref,
            )

        status = self._run("status", "--instance-id", self.target.instance_id)
        descriptor = status.get("descriptor")
        if not isinstance(descriptor, Mapping):
            descriptor = entry
        runtime = descriptor.get("selected_runtime") if isinstance(descriptor, Mapping) else None
        if not isinstance(runtime, Mapping):
            return ProductInstallationReadback(
                EP_COMPONENT, self.target.instance_id, "UNKNOWN",
                None, None, None, None, None, "UNKNOWN", "MACHINE_WIDE",
                "UNKNOWN", inventory_ref,
            )
        correlation = ArtifactCorrelation(
            _string(runtime.get("version"), "EP runtime version"),
            _string(runtime.get("source_revision"), "EP runtime source_revision"),
            _string(runtime.get("artifact_digest"), "EP runtime artifact_digest"),
        )
        runtime_identity = "ep-runtime:" + _canonical_digest(runtime)
        executable_identity = "ep-executable:" + _canonical_digest({
            "instance_id": self.target.instance_id,
            "interpreter": runtime.get("interpreter"),
        })
        server_identity = _string(descriptor.get("service_label"), "EP service identity")
        state_value = status.get("state")
        ready = status.get("ready") is True and state_value == "READY"
        state = "ACTIVE" if ready else "UNHEALTHY"
        health = "HEALTHY" if ready else "UNHEALTHY"
        status_ref = "ep-status:" + _canonical_digest(status)
        return ProductInstallationReadback(
            EP_COMPONENT,
            self.target.instance_id,
            state,
            runtime_identity,
            executable_identity,
            server_identity,
            self.target.instance_id,
            correlation,
            health,
            "MACHINE_WIDE",
            "NONE",
            inventory_ref,
            status_ref,
        )

    def assess_update(self, request: ComponentOperationRequest) -> ProductUpdateAssessment:
        self._validate_request(request)
        if request.kind != "update":
            raise EngineeringPlatformAdapterError("EP update assessment requires update kind")
        result = self._run(
            "update-assess",
            "--instance-id", self.target.instance_id,
            *self._release_arguments(request.artifact),
        )
        state_map = {
            "UPDATE_AVAILABLE": "UPDATE_AVAILABLE",
            "NO_CHANGE": "UP_TO_DATE",
            "BLOCKED_DOWNGRADE": "INCOMPATIBLE",
            "BLOCKED_IDENTITY_MISMATCH": "INCOMPATIBLE",
        }
        state = state_map.get(result.get("state"), "UNKNOWN")
        return ProductUpdateAssessment(
            EP_COMPONENT,
            self.target.instance_id,
            request.artifact.correlation,
            state,
            "ep-update-assess:" + _canonical_digest(result),
        )

    def execute(self, request: ComponentOperationRequest) -> ProductOperationReceipt:
        self._validate_request(request)
        if request.kind == "install":
            result = self._run(
                "create",
                *self._target_arguments(),
                "--operation-id", request.operation_id,
                *self._release_arguments(request.artifact),
            )
        elif request.kind == "update":
            result = self._run(
                "update-execute",
                "--instance-id", self.target.instance_id,
                "--operation-id", request.operation_id,
                *self._release_arguments(request.artifact),
            )
        elif request.kind == "repair":
            result = self._run(
                "repair",
                "--instance-id", self.target.instance_id,
                "--operation-id", request.operation_id,
            )
        elif request.kind == "remove":
            result = self._run(
                "remove",
                "--instance-id", self.target.instance_id,
                "--confirm-instance-id", self.target.instance_id,
                "--operation-id", request.operation_id,
            )
        else:
            raise EngineeringPlatformAdapterError("EP operation kind is unsupported")
        return self._receipt(request, result)

    def resume(
        self,
        request: ComponentOperationRequest,
        prior_receipt: ProductOperationReceipt,
    ) -> ProductOperationReceipt:
        self._validate_request(request)
        if request.kind != "update":
            # create/repair/remove are idempotent terminal product commands.
            return self.execute(request)
        if prior_receipt.product_operation_id != request.operation_id:
            raise EngineeringPlatformAdapterError("EP resume receipt operation identity changed")
        result = self._run(
            "update-resume",
            "--instance-id", self.target.instance_id,
            "--operation-id", request.operation_id,
        )
        return self._receipt(request, result)

    def register_provider(
        self,
        *,
        provider: str,
        executable_digest: str,
        version: str,
        auth_reference: str,
        auth_bootstrap_receipt: str,
    ) -> Mapping[str, object]:
        if provider not in {"codex", "github"}:
            raise ValueError("EP provider identity is unsupported")
        return self._run(
            "provider-register",
            "--instance-id", self.target.instance_id,
            "--display-label", self.target.display_label,
            "--service-account", self.target.service_account,
            "--provider", provider,
            "--provider-executable-digest", executable_digest,
            "--provider-version", version,
            "--auth-reference", auth_reference,
            "--auth-bootstrap-receipt", auth_bootstrap_receipt,
        )

    @staticmethod
    def _receipt(
        request: ComponentOperationRequest,
        result: Mapping[str, object],
    ) -> ProductOperationReceipt:
        receipt = result.get("receipt")
        receipt_map = _mapping(receipt, "EP terminal receipt")
        if receipt_map.get("operation_id") != request.operation_id:
            raise EngineeringPlatformAdapterError("EP receipt operation identity mismatch")
        if receipt_map.get("instance_id") != request.installation_identity:
            raise EngineeringPlatformAdapterError("EP receipt instance identity mismatch")
        product_state = result.get("result")
        state_map = {
            "COMPLETE": "COMPLETED",
            "CLEANUP_PENDING": "CLEANUP_PENDING",
            "RECOVERY_PENDING": "RECOVERY_PENDING",
            "FAILED": "FAILED",
        }
        state = state_map.get(product_state)
        if state is None:
            raise EngineeringPlatformAdapterError("EP receipt state is unsupported")
        reference = "ep-receipt:" + _canonical_digest(receipt_map)
        return ProductOperationReceipt(
            request.operation_id,
            request.component,
            request.installation_identity,
            request.artifact.correlation,
            state,
            reference,
            reference if state == "CLEANUP_PENDING" else None,
        )
