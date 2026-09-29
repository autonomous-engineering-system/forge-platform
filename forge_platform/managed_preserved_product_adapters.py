"""Sealed Forge/EP product CLI boundary for exact preserved lifecycle work.

Only the privileged worker may construct these adapters from fixed released
routes. Callers provide a reviewed operation, never a command, path or secret.
Service, provider, pairing and registry continuation remain separate gates.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from pathlib import Path
import re
from typing import Mapping

from .component_operations import QualifiedArtifact
from .engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    ProductCommandRunner,
    SubprocessProductCommandRunner,
)
from .forge_server_adapter import (
    ForgeCommandRunner,
    ForgeServerTarget,
    SubprocessForgeCommandRunner,
    _forge_product_digest,
)
from .managed_deployments import ManagedDeploymentRegistry
from .managed_preserved_lifecycle_plan import (
    ManagedPreservedLifecycleReview,
    require_current_preserved_lifecycle_review,
)
from .product_preserved_lifecycle import (
    EP_COMPONENT,
    EP_CONTRACT,
    FORGE_COMPONENT,
    ProductPreservedLifecycleError,
    ProductPreservedLifecycleTerminal,
    frozen_preserved_release,
    validate_terminal_preserved_lifecycle,
)
from .universal_installer import CompositionManifest


_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_MAX_PRODUCT_JSON_BYTES = 128 * 1024


class ManagedPreservedProductAdapterError(RuntimeError):
    """An exact product lifecycle invocation lacks owning terminal evidence."""


@dataclass(frozen=True)
class ProductPreservedLifecycleInvocation:
    """Ephemeral owning evidence for guarded service and registry continuation."""

    terminal: ProductPreservedLifecycleTerminal
    receipt: Mapping[str, object]
    status: Mapping[str, object]


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate product lifecycle field")
        result[key] = value
    return result


def _product_json(returncode: int, stdout: str) -> Mapping[str, object]:
    if (
        returncode != 0 or not isinstance(stdout, str)
        or not stdout or len(stdout.encode("utf-8")) > _MAX_PRODUCT_JSON_BYTES
    ):
        raise ManagedPreservedProductAdapterError("product lifecycle command failed")
    try:
        value = json.loads(
            stdout, object_pairs_hook=_unique_object,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON")),
        )
    except (UnicodeError, ValueError, TypeError) as error:
        raise ManagedPreservedProductAdapterError("product lifecycle JSON is invalid") from error
    if not isinstance(value, dict):
        raise ManagedPreservedProductAdapterError("product lifecycle result is not an object")
    return value


def _fresh_review(
    review: ManagedPreservedLifecycleReview, *, component: str,
    instance_id: str, artifact: QualifiedArtifact,
    registry: ManagedDeploymentRegistry, installed_manifest: CompositionManifest,
) -> None:
    if (
        not isinstance(review, ManagedPreservedLifecycleReview)
        or not isinstance(registry, ManagedDeploymentRegistry)
        or not frozen_preserved_release(component, artifact)
        or review.component != component or review.instance_id != instance_id
        or review.artifact.correlation != artifact.correlation
    ):
        raise ManagedPreservedProductAdapterError("sealed product target changed")
    try:
        current = registry.load(review.deployment_id)
    except Exception as error:
        raise ManagedPreservedProductAdapterError("reviewed inventory is unavailable") from error
    if current is None:
        raise ManagedPreservedProductAdapterError("reviewed deployment is unavailable")
    try:
        require_current_preserved_lifecycle_review(
            review, current=current, installed_manifest=installed_manifest,
        )
    except Exception as error:
        raise ManagedPreservedProductAdapterError("product lifecycle review is stale") from error


class ForgePreservedProductAdapter:
    """Invoke only an exact qualified released Forge instance-lifecycle CLI."""

    def __init__(
        self, *, lifecycle_executable: Path, target: ForgeServerTarget,
        installation_id: str, artifact: QualifiedArtifact,
        runner: ForgeCommandRunner | None = None,
    ) -> None:
        if (
            not isinstance(lifecycle_executable, Path)
            or not lifecycle_executable.is_absolute()
            or not isinstance(target, ForgeServerTarget)
            or not isinstance(installation_id, str)
            or _ID.fullmatch(installation_id) is None
            or target.data_root.parent != target.instances_root
            or target.data_root.name != target.instance_id
            or not frozen_preserved_release(FORGE_COMPONENT, artifact)
        ):
            raise ValueError("sealed Forge lifecycle route is invalid")
        self.lifecycle_executable = lifecycle_executable
        self.target = target
        self.installation_id = installation_id
        self.artifact = artifact
        self.runner = runner or SubprocessForgeCommandRunner()

    def invoke(
        self, review: ManagedPreservedLifecycleReview, *,
        registry: ManagedDeploymentRegistry, installed_manifest: CompositionManifest,
    ) -> ProductPreservedLifecycleInvocation:
        _fresh_review(
            review, component=FORGE_COMPONENT, instance_id=self.target.instance_id,
            artifact=self.artifact, registry=registry,
            installed_manifest=installed_manifest,
        )
        request: dict[str, str] = {
            "operation_id": review.operation_id,
            "instance_id": self.target.instance_id,
            "runtime_id": self.target.instance_id,
            "installation_id": self.installation_id,
            "installed_version": self.artifact.version,
            "installed_source": self.artifact.source_revision,
            "installed_artifact_digest": self.artifact.digest,
            "data_root": str(self.target.data_root),
            "instances_root": str(self.target.instances_root),
        }
        if review.operation == "RESTORE":
            if not review.preserve_operation_id:
                raise ManagedPreservedProductAdapterError("Forge preserve authority is unavailable")
            request["preserve_operation_id"] = review.preserve_operation_id
        arguments = (
            str(self.lifecycle_executable), "--data-root", request["data_root"],
            "server", review.operation.lower(),
            "--operation-id", request["operation_id"],
            "--instances-root", request["instances_root"],
            "--instance-id", request["instance_id"],
            "--runtime-id", request["runtime_id"],
            "--installation-id", request["installation_id"],
            "--installed-version", request["installed_version"],
            "--installed-source", request["installed_source"],
            "--installed-artifact-digest", request["installed_artifact_digest"],
            *(("--preserve-operation-id", request["preserve_operation_id"])
              if review.operation == "RESTORE" else ()),
        )
        executed = self.runner.run(arguments)
        receipt = _product_json(executed.returncode, executed.stdout)
        status_result = self.runner.run((
            str(self.lifecycle_executable), "server", "lifecycle-status",
            "--operation-id", review.operation_id,
            "--instances-root", str(self.target.instances_root),
            "--instance-id", self.target.instance_id,
        ))
        status = _product_json(status_result.returncode, status_result.stdout)
        try:
            terminal = validate_terminal_preserved_lifecycle(
                component=FORGE_COMPONENT, operation=review.operation,
                operation_id=review.operation_id, instance_id=self.target.instance_id,
                artifact=self.artifact, request_digest=_forge_product_digest(request),
                receipt=receipt, status=status,
                preserve_operation_id=review.preserve_operation_id,
            )
            return ProductPreservedLifecycleInvocation(terminal, receipt, status)
        except ProductPreservedLifecycleError as error:
            raise ManagedPreservedProductAdapterError(
                "Forge product lifecycle terminal evidence is invalid"
            ) from error


class EPPreservedProductAdapter:
    """Invoke the selected exact released EP system-instance CLI."""

    def __init__(
        self, *, provisioner_executable: Path, product_root: Path,
        target: EPSystemInstanceTarget, artifact: QualifiedArtifact,
        staged_wheel: Path, launch_daemons_directory: Path,
        runner: ProductCommandRunner | None = None,
    ) -> None:
        if (
            any(not isinstance(path, Path) or not path.is_absolute() for path in (
                provisioner_executable, product_root, staged_wheel,
                launch_daemons_directory,
            ))
            or not isinstance(target, EPSystemInstanceTarget)
            or not frozen_preserved_release(EP_COMPONENT, artifact)
        ):
            raise ValueError("sealed EP lifecycle route is invalid")
        self.provisioner_executable = provisioner_executable
        self.product_root = product_root
        self.target = target
        self.artifact = artifact
        self.staged_wheel = staged_wheel
        self.launch_daemons_directory = launch_daemons_directory
        self.runner = runner or SubprocessProductCommandRunner()

    def invoke(
        self, review: ManagedPreservedLifecycleReview, *,
        registry: ManagedDeploymentRegistry, installed_manifest: CompositionManifest,
    ) -> ProductPreservedLifecycleInvocation:
        _fresh_review(
            review, component=EP_COMPONENT, instance_id=self.target.instance_id,
            artifact=self.artifact, registry=registry,
            installed_manifest=installed_manifest,
        )
        if review.operation == "RESTORE":
            if not review.preserve_operation_id:
                raise ManagedPreservedProductAdapterError("EP preserve authority is unavailable")
            if not self.staged_wheel.is_file() or self.staged_wheel.is_symlink():
                raise ManagedPreservedProductAdapterError("EP released wheel is unavailable")
            if "sha256:" + sha256(self.staged_wheel.read_bytes()).hexdigest() != self.artifact.digest:
                raise ManagedPreservedProductAdapterError("EP released wheel bytes changed")
        arguments = [
            str(self.provisioner_executable), review.operation.lower(),
            "--product-root", str(self.product_root),
            "--launch-daemons-dir", str(self.launch_daemons_directory),
            "--instance-id", self.target.instance_id,
            "--operation-id", review.operation_id,
        ]
        if review.operation in {"PRESERVE", "PURGE"}:
            arguments.extend(("--confirm-instance-id", self.target.instance_id))
        else:
            arguments.extend((
                "--preserve-operation-id", review.preserve_operation_id,
                "--version", self.artifact.version,
                "--artifact", str(self.staged_wheel),
                "--artifact-digest", self.artifact.digest,
                "--source-revision", self.artifact.source_revision,
            ))
        executed = self.runner.run(tuple(arguments))
        outer = _product_json(executed.returncode, executed.stdout)
        receipt = outer.get("receipt")
        if (
            outer.get("contract") != EP_CONTRACT
            or outer.get("result") != "COMPLETE"
            or outer.get("instance_id") != self.target.instance_id
            or not isinstance(receipt, Mapping)
        ):
            raise ManagedPreservedProductAdapterError("EP lifecycle receipt envelope is invalid")
        status_result = self.runner.run((
            str(self.provisioner_executable), "lifecycle-status",
            "--product-root", str(self.product_root),
            "--launch-daemons-dir", str(self.launch_daemons_directory),
            "--instance-id", self.target.instance_id,
            "--operation-id", review.operation_id,
        ))
        status = _product_json(status_result.returncode, status_result.stdout)
        digest = receipt.get("request_digest")
        if not isinstance(digest, str) or _DIGEST.fullmatch(digest) is None:
            raise ManagedPreservedProductAdapterError("EP owning request digest is unavailable")
        try:
            terminal = validate_terminal_preserved_lifecycle(
                component=EP_COMPONENT, operation=review.operation,
                operation_id=review.operation_id, instance_id=self.target.instance_id,
                artifact=self.artifact, request_digest=digest,
                receipt=receipt, status=status,
                preserve_operation_id=review.preserve_operation_id,
            )
            return ProductPreservedLifecycleInvocation(terminal, receipt, status)
        except ProductPreservedLifecycleError as error:
            raise ManagedPreservedProductAdapterError(
                "EP product lifecycle terminal evidence is invalid"
            ) from error
