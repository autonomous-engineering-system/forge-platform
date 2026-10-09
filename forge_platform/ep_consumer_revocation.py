"""Exact EP 2.3.106 product-owned consumer revocation boundary.

The frozen product command is run as the selected instance's service account.
Its CENTRAL database authority is explicitly pinned to that instance's existing
Server database; no caller supplied path, credential, or cleanup is accepted.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
from typing import Mapping, Protocol, Sequence

from .component_operations import QualifiedArtifact
from .engineering_platform_system_adapter import (
    EngineeringPlatformSystemProvisionerAdapter,
    ProductCommandResult,
)
from .qualified_ep_lifecycle import qualified_ep_lifecycle_artifact


class EPConsumerRevocationError(RuntimeError):
    """The selected EP consumer scope cannot be revoked safely."""


class EPConsumerCommandRunner(Protocol):
    def run(
        self, argv: Sequence[str], *, database: Path, uid: int, gid: int,
    ) -> ProductCommandResult: ...


class SubprocessEPConsumerCommandRunner:
    def run(
        self, argv: Sequence[str], *, database: Path, uid: int, gid: int,
    ) -> ProductCommandResult:
        result = subprocess.run(
            tuple(argv), capture_output=True, text=True, check=False,
            user=uid, group=gid, extra_groups=(),
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PYTHONNOUSERSITE": "1",
                "PYTHONSAFEPATH": "1",
                "EP_CENTRAL_OPERATIONAL_DATABASE": str(database),
            },
        )
        return ProductCommandResult(result.returncode, result.stdout, result.stderr)


@dataclass(frozen=True)
class EPConsumerScope:
    consumer_id: str
    project_id: str

    def __post_init__(self) -> None:
        for value in (self.consumer_id, self.project_id):
            if not isinstance(value, str) or not value or len(value) > 128 or any(
                character in value for character in ("\x00", "\n", "\r")
            ):
                raise ValueError("EP consumer scope is invalid")


class EPConsumerRevocationAdapter:
    """Invoke only the frozen EP module for one already registered scope."""

    def __init__(
        self, *, provisioner: EngineeringPlatformSystemProvisionerAdapter,
        scope: EPConsumerScope, expected_artifact: QualifiedArtifact,
        runner: EPConsumerCommandRunner | None = None,
        expected_owner_uid: int = 0,
    ) -> None:
        if not isinstance(provisioner, EngineeringPlatformSystemProvisionerAdapter):
            raise TypeError("exact EP provisioner binding is required")
        if not isinstance(scope, EPConsumerScope):
            raise TypeError("exact EP consumer scope is required")
        if not qualified_ep_lifecycle_artifact(expected_artifact):
            raise ValueError("frozen EP release authority is required")
        if isinstance(expected_owner_uid, bool) or not isinstance(expected_owner_uid, int) or expected_owner_uid < 0:
            raise ValueError("EP product root owner is invalid")
        self.provisioner = provisioner
        self.scope = scope
        self.expected_artifact = expected_artifact
        self.runner = runner or SubprocessEPConsumerCommandRunner()
        self.expected_owner_uid = expected_owner_uid

    def _authority(self) -> tuple[Path, Path, int, int]:
        return _exact_ep_instance_runtime(self.provisioner,self.expected_artifact,self.expected_owner_uid)

    def _command(self, action: str) -> object:
        interpreter, database, uid, gid = self._authority()
        result = self.runner.run(
            (
                str(interpreter), "-I", "-m", "engineering_platform.ep_consumer_credentials",
                action, "--repo", str(database.parent),
                "--consumer-id", self.scope.consumer_id,
                "--project-id", self.scope.project_id,
            ),
            database=database, uid=uid, gid=gid,
        )
        if result.returncode != 0:
            raise EPConsumerRevocationError("EP product consumer operation failed")
        try:
            return json.loads(result.stdout)
        except (TypeError, ValueError) as error:
            raise EPConsumerRevocationError("EP consumer evidence is invalid") from error

    def status(self) -> Mapping[str, object]:
        result = self._command("consumer-status")
        if (
            not isinstance(result, dict)
            or result.get("consumer_id") != self.scope.consumer_id
            or result.get("project_id") != self.scope.project_id
            or result.get("status") not in {"ACTIVE", "REVOKED"}
            or not isinstance(result.get("active_production_credentials"), int)
            or isinstance(result.get("active_production_credentials"), bool)
            or result["active_production_credentials"] < 0
        ):
            raise EPConsumerRevocationError("EP consumer readback contradicts exact scope")
        return result

    def revoke(self) -> str:
        before = self.status()
        if before["status"] == "ACTIVE":
            result = self._command("consumer-revoke")
            if result is not True:
                raise EPConsumerRevocationError("EP consumer revocation was not acknowledged")
        after = self.status()
        if after["status"] != "REVOKED" or not after.get("revoked_at"):
            raise EPConsumerRevocationError("EP consumer revocation lacks terminal readback")
        evidence = {
            "instance_id": self.provisioner.target.instance_id,
            "consumer_id": self.scope.consumer_id,
            "project_id": self.scope.project_id,
            "status": after["status"],
            "revoked_at": after["revoked_at"],
        }
        return "ep-consumer-revoke:sha256:" + sha256(
            json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()


def _exact_ep_instance_runtime(provisioner, expected_artifact, expected_owner_uid):
    """Shared exact topology readback; each caller separately admits its release."""
    target = provisioner.target
    root = provisioner.product_root
    entry, inventory = provisioner._inventory_entry()
    if entry is None or inventory.get("state") == "AMBIGUOUS":
        raise EPConsumerRevocationError("exact EP instance inventory is unavailable")
    status = provisioner._run("status", "--instance-id", target.instance_id)
    descriptor = status.get("descriptor")
    runtime = descriptor.get("selected_runtime") if isinstance(descriptor, Mapping) else None
    if (
        status.get("instance_id") != target.instance_id
        or status.get("state") != "READY"
        or status.get("ready") is not True
        or not isinstance(descriptor, Mapping)
        or descriptor.get("instance_id") != target.instance_id
        or not isinstance(runtime, Mapping)
        or not isinstance(entry, Mapping)
        or entry.get("instance_id") != target.instance_id
    ):
        raise EPConsumerRevocationError("EP instance status is not exact and ready")
    data = root / "instances" / target.instance_id / "data"
    database = data / "epdata.sqlite"
    interpreter = runtime.get("interpreter")
    if (
        descriptor.get("data_root") != str(data)
        or descriptor.get("service_account") != target.service_account
        or entry.get("status") != "READY"
        or entry.get("data_root") != str(data)
        or entry.get("service_account") != target.service_account
        or entry.get("selected_runtime") != runtime
        or not isinstance(interpreter, str)
        or not Path(interpreter).is_absolute()
        or Path(interpreter).name != "python"
        or Path(interpreter).parent.name != "bin"
        or not Path(interpreter).parent.resolve(strict=False).is_relative_to(root / "runtimes")
        or runtime.get("version") != expected_artifact.version
        or runtime.get("source_revision") != expected_artifact.source_revision
        or runtime.get("artifact_digest") != expected_artifact.digest
    ):
        raise EPConsumerRevocationError("EP instance runtime authority is unsupported")
    for directory in (root, root / "instances", root / "instances" / target.instance_id, data):
        try:
            info = os.lstat(directory)
        except OSError as error:
            raise EPConsumerRevocationError("EP instance-owned data root is unavailable") from error
        if not stat.S_ISDIR(info.st_mode):
            raise EPConsumerRevocationError("EP instance-owned data root is unsafe")
        if directory != data and (
            info.st_uid != expected_owner_uid
            or stat.S_IMODE(info.st_mode) & 0o022
        ):
            raise EPConsumerRevocationError("EP product topology is not root controlled")
    try:
        info = os.lstat(database)
    except OSError as error:
        raise EPConsumerRevocationError("EP CENTRAL database is unavailable") from error
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise EPConsumerRevocationError("EP CENTRAL database is unsafe")
    try:
        account = pwd.getpwnam(target.service_account)
    except KeyError as error:
        raise EPConsumerRevocationError("EP service account is unavailable") from error
    identity = (account.pw_uid, account.pw_gid)
    if identity[0] == 0 or info.st_uid not in {0, identity[0]}:
        raise EPConsumerRevocationError("EP CENTRAL database ownership is unsafe")
    return Path(interpreter), database, *identity
