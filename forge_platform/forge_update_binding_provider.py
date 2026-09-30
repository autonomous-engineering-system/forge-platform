"""Helper-owned, request-bound authority for the published Forge 2.7.39 updater.

The signed worker supplies the only code resource paths. The canonical product
route supplies the installation and instance identities. Forge's own status
CLI supplies peer state; its updater still performs the decisive read-only
UPDATE_AVAILABLE assessment immediately before any mutation.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import stat

from .component_operations import ComponentOperationRequest, QualifiedArtifact
from .forge_server_adapter import (
    ForgeCommandRunner, ForgeServerAdapterError, ForgeServerProductAdapter,
    ForgeServerTarget, ForgeUpdateBinding, SubprocessForgeCommandRunner,
    _FORGE_239_CONTROLLER_SHA256, _FORGE_239_CONTROLLER_SOURCE,
    _FORGE_239_RELEASE_RECEIPT_SHA256,
)
from .forge_update_intent import ForgeUpdateIntentStore
from .forge_update_resources import _read_stable, read_forge_239_update_resources
from .qualified_forge_lifecycle import qualified_forge_239_update_selection


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate Forge status field")
        result[key] = value
    return result


def _digest(value: bytes) -> str:
    return "sha256:" + sha256(value).hexdigest()


def _private_directory(path: Path, owner: int) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise ForgeServerAdapterError("Forge updater runtime path is unsafe")
    try:
        details = os.lstat(path)
    except OSError as error:
        raise ForgeServerAdapterError("Forge updater runtime directory is unavailable") from error
    if (
        not stat.S_ISDIR(details.st_mode) or details.st_uid != owner
        or stat.S_IMODE(details.st_mode) != 0o700
    ):
        raise ForgeServerAdapterError("Forge updater runtime directory is unsafe")


@dataclass(frozen=True)
class ReleasedForge239UpdateBindingProvider:
    """Resolve only one helper-pinned installed 2.7.38 Forge instance."""

    root: Path
    worker: Path
    forge_executable: Path
    target: ForgeServerTarget
    installed_artifact: QualifiedArtifact
    installation_id: str
    base_python: Path
    expected_owner_uid: int = 0
    expected_pairing_binding_id: str | None = None
    expected_ep_consumer_id: str | None = None
    runner: ForgeCommandRunner | None = None

    def __post_init__(self) -> None:
        if any(
            not isinstance(path, Path) or not path.is_absolute()
            for path in (self.root, self.worker, self.forge_executable, self.base_python)
        ) or not isinstance(self.target, ForgeServerTarget) or not isinstance(
            self.installed_artifact, QualifiedArtifact
        ) or not isinstance(self.installation_id, str) or not self.installation_id:
            raise ValueError("Forge update provider authority is invalid")
        if (self.expected_pairing_binding_id is None) != (self.expected_ep_consumer_id is None):
            raise ValueError("Forge update provider pairing authority is incomplete")

    def _peer_digest(self, installed_version: str, executable: Path) -> str:
        if self.expected_pairing_binding_id is not None:
            assert self.expected_ep_consumer_id is not None
            return ForgeServerProductAdapter.read_peer_configuration_digest(
                forge_executable=executable, target=self.target,
                installed_version=installed_version,
                expected_binding_id=self.expected_pairing_binding_id,
                expected_ep_consumer_id=self.expected_ep_consumer_id,
                runner=self.runner,
            )
        result = (self.runner or SubprocessForgeCommandRunner()).run((
            str(executable), "--data-root", str(self.target.data_root),
            "server", "status",
        ))
        if result.returncode != 0 or result.stderr.strip() or not 0 < len(result.stdout) <= 64 * 1_024:
            raise ForgeServerAdapterError("Forge unpaired status is unavailable")
        try:
            status = json.loads(result.stdout, object_pairs_hook=_unique,
                                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
        except (ValueError, TypeError) as error:
            raise ForgeServerAdapterError("Forge unpaired status is invalid") from error
        if (
            not isinstance(status, dict)
            or status.get("product_version") != installed_version
            or status.get("data_root") != str(self.target.data_root)
            or status.get("initialized") is not True
            or status.get("instance_id") != self.target.instance_id
            or not isinstance(status.get("runtime_status"), str)
            or status["runtime_status"] in {"", "unavailable", "uninitialized"}
            or status.get("execution_host_peer") != {
                "status": "NOT_CONFIGURED", "live_status": "NOT_VERIFIED",
            }
        ):
            raise ForgeServerAdapterError("Forge unpaired instance is unavailable or ambiguous")
        return _digest((json.dumps(
            {"state": "NOT_CONFIGURED", "runtime_id": self.target.instance_id},
            sort_keys=True, separators=(",", ":"), ensure_ascii=False,
        ) + "\n").encode("utf-8"))

    def resolve(self, request: ComponentOperationRequest) -> ForgeUpdateBinding:
        if (
            os.geteuid() != self.expected_owner_uid
            or request.component != "forge-runtime" or request.kind != "update"
            or request.installation_identity != self.target.instance_id
            or not qualified_forge_239_update_selection(
                self.installed_artifact, request.artifact,
            )
        ):
            raise ForgeServerAdapterError("Forge 2.7.39 update selection is unavailable")
        runtime_parent = self.root / "products/forge"
        runtime_root = runtime_parent / self.target.instance_id
        intent_root = self.root / "state/forge-update-intents"
        for path in (self.root, self.root / "products", runtime_parent,
                     runtime_root, self.root / "state", intent_root):
            _private_directory(path, self.expected_owner_uid)
        resources = read_forge_239_update_resources(self.worker)
        intent = ForgeUpdateIntentStore(intent_root).read(request.operation_id)
        if intent is not None and (
            intent.instance_id != self.target.instance_id
            or intent.request_fingerprint != request.fingerprint()
            or intent.installed_artifact != self.installed_artifact.digest
            or intent.candidate_artifact != request.artifact.digest
            or intent.binding_snapshot is None
        ):
            raise ForgeServerAdapterError("Forge durable update intent changed its selection")
        previous = dict(intent.binding_snapshot) if intent is not None else None
        status_executable = self.forge_executable
        if self.forge_executable.is_symlink():
            if previous is None or intent is None or intent.phase == "PREPARED":
                raise ForgeServerAdapterError("Forge resolver was adopted without an invoked intent")
            stable = runtime_root / "bin/forge"
            if os.readlink(self.forge_executable) != str(stable):
                raise ForgeServerAdapterError("Forge adopted resolver changed")
            digest = previous["resolver_sha256"]
            legacy = runtime_root / "legacy" / (digest.removeprefix("sha256:")[:16] + "-forge")
            if _digest(_read_stable(legacy, 512 * 1_024)) != digest:
                raise ForgeServerAdapterError("Forge legacy resolver changed")
            if intent.phase == "UPDATER_INVOKED":
                status_executable = legacy
        else:
            digest = _digest(_read_stable(self.forge_executable, 512 * 1_024))
            if previous is not None and previous.get("resolver_sha256") != digest:
                raise ForgeServerAdapterError("Forge resolver changed on resume")
        peer_version = (
            request.artifact.version if intent is not None and intent.phase in {
                "PRODUCT_COMPLETE", "COMPLETE"
            } else self.installed_artifact.version
        )
        try:
            peer_digest = self._peer_digest(peer_version, status_executable)
        except ForgeServerAdapterError:
            if intent is None or intent.phase != "UPDATER_INVOKED":
                raise
            peer_digest = self._peer_digest(request.artifact.version, status_executable)
        pinned = {
            "updater_executable": str(resources.controller),
            "qualification_receipt": str(resources.release_receipt),
            "qualification_receipt_sha256": _FORGE_239_RELEASE_RECEIPT_SHA256,
            "controller_source": _FORGE_239_CONTROLLER_SOURCE,
            "controller_sha256": _FORGE_239_CONTROLLER_SHA256,
            "resolver": str(self.forge_executable),
            "runtime_root": str(runtime_root),
            "runtime_id": self.target.instance_id,
            "installation_id": self.installation_id,
            "peer_configuration_digest": peer_digest,
            "existing_interpreter": str(self.forge_executable.parent / "python3"),
            "existing_version": self.installed_artifact.version,
            "base_python": str(self.base_python),
            "intent_root": str(intent_root),
        }
        if previous is not None and any(previous.get(key) != value for key, value in pinned.items()):
            raise ForgeServerAdapterError("Forge durable update binding changed on resume")
        return ForgeUpdateBinding(
            updater_executable=resources.controller,
            qualification_receipt=resources.release_receipt,
            qualification_receipt_sha256=_FORGE_239_RELEASE_RECEIPT_SHA256,
            controller_source=_FORGE_239_CONTROLLER_SOURCE,
            controller_sha256=_FORGE_239_CONTROLLER_SHA256,
            resolver=self.forge_executable, resolver_sha256=digest,
            runtime_root=runtime_root, runtime_id=self.target.instance_id,
            installation_id=self.installation_id, peer_configuration_digest=peer_digest,
            existing_interpreter=self.forge_executable.parent / "python3",
            existing_version=self.installed_artifact.version,
            base_python=self.base_python, intent_root=intent_root,
        )
