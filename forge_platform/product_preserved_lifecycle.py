"""Read-only terminal evidence for frozen product-owned preserved lifecycles.

This module grants no mutation authority. The older Forge uninstall and EP
remove receipts retain their destructive meaning; they cannot satisfy a
PRESERVE, RESTORE or PURGE decision here.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import re
from typing import Mapping

from .component_operations import QualifiedArtifact
from .qualified_forge_lifecycle import qualified_forge_lifecycle_artifact


FORGE_COMPONENT = "forge-runtime"
EP_COMPONENT = "engineering-platform-server"
FORGE_CONTRACT = "forge-server-instance-lifecycle/v1"
EP_CONTRACT = "engineering-platform.system-instance-lifecycle/v1"
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_FROZEN_RELEASES = {
    EP_COMPONENT: (
        "2.3.104",
        "cfce69892278ee2b6c14412c171f5f33596acb0e",
        "sha256:3f7822fd081598f81d5c666200787a3b2182d7004c078cc36ec20455269909cb",
    ),
}


class ProductPreservedLifecycleError(RuntimeError):
    """Owning lifecycle evidence is absent, conflicting or outside the release."""


@dataclass(frozen=True)
class ProductPreservedLifecycleTerminal:
    component: str
    operation: str
    operation_id: str
    instance_id: str
    lifecycle_state: str
    receipt_digest: str
    restorable: bool | None
    preserve_operation_id: str | None


def frozen_preserved_release(component: str, artifact: QualifiedArtifact) -> bool:
    """Require exact released wheel bytes as well as version and source."""
    if not isinstance(artifact, QualifiedArtifact):
        return False
    if component == FORGE_COMPONENT:
        return qualified_forge_lifecycle_artifact(artifact)
    identity = _FROZEN_RELEASES.get(component)
    return identity is not None and (
        artifact.version, artifact.source_revision, artifact.digest
    ) == identity


def _digest_of(component: str, value: Mapping[str, object]) -> str:
    try:
        if component == FORGE_COMPONENT:
            data = (
                json.dumps(value, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=False, allow_nan=False) + "\n"
            ).encode("utf-8")
        else:
            data = json.dumps(
                value, sort_keys=True, separators=(",", ":"), allow_nan=False
            ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise ProductPreservedLifecycleError("lifecycle receipt is not canonical JSON") from error
    return "sha256:" + sha256(data).hexdigest()


def validate_terminal_preserved_lifecycle(
    *, component: str, operation: str, operation_id: str,
    instance_id: str, artifact: QualifiedArtifact, request_digest: str,
    receipt: Mapping[str, object], status: Mapping[str, object],
    preserve_operation_id: str | None = None,
) -> ProductPreservedLifecycleTerminal:
    """Cross-check one exact product receipt with independent operation status."""
    if (
        not frozen_preserved_release(component, artifact)
        or operation not in {"PRESERVE", "RESTORE", "PURGE"}
        or not isinstance(operation_id, str) or _ID.fullmatch(operation_id) is None
        or not isinstance(instance_id, str) or _ID.fullmatch(instance_id) is None
        or not isinstance(request_digest, str) or _DIGEST.fullmatch(request_digest) is None
        or not isinstance(receipt, Mapping) or not isinstance(status, Mapping)
    ):
        raise ProductPreservedLifecycleError("lifecycle target or release is invalid")
    if operation == "RESTORE":
        if (
            not isinstance(preserve_operation_id, str)
            or _ID.fullmatch(preserve_operation_id) is None
        ):
            raise ProductPreservedLifecycleError("exact preserve operation is required")
    elif preserve_operation_id is not None:
        raise ProductPreservedLifecycleError("non-restore lifecycle carries preserve authority")

    contract = FORGE_CONTRACT if component == FORGE_COMPONENT else EP_CONTRACT
    receipt_digest_key = "receipt_digest" if component == FORGE_COMPONENT else "receipt_sha256"
    digest = receipt.get(receipt_digest_key)
    unsigned = {key: value for key, value in receipt.items() if key != receipt_digest_key}
    if (
        not isinstance(digest, str) or _DIGEST.fullmatch(digest) is None
        or _digest_of(component, unsigned) != digest
        or receipt.get("contract") != contract
        or receipt.get("operation") != operation
        or receipt.get("operation_id") != operation_id
        or receipt.get("instance_id") != instance_id
        or receipt.get("request_digest") != request_digest
        or receipt.get("state") != "COMPLETE"
    ):
        raise ProductPreservedLifecycleError("terminal lifecycle receipt is invalid")
    if component == FORGE_COMPONENT:
        if (
            receipt.get("runtime_id") != instance_id
            or not isinstance(receipt.get("installation_id"), str)
            or _ID.fullmatch(receipt["installation_id"]) is None
            or receipt.get("selected_artifact") != {
                "version": artifact.version,
                "source_revision": artifact.source_revision,
                "artifact_digest": artifact.digest,
            }
        ):
            raise ProductPreservedLifecycleError("Forge lifecycle artifact or target changed")
        evidence = receipt
    else:
        evidence = receipt.get("evidence")
        if not isinstance(evidence, Mapping):
            raise ProductPreservedLifecycleError("EP lifecycle evidence is unavailable")

    states = {
        "PRESERVE": "UNINSTALLED_DATA_PRESERVED",
        "RESTORE": (
            "RESTORE_VALIDATED" if component == FORGE_COMPONENT
            else "RESTORED_REQUIRES_PROVIDER_REVERIFICATION"
        ),
        "PURGE": "PURGED",
    }
    lifecycle_state = states[operation]
    restorable = evidence.get("restorable")
    if (
        evidence.get("lifecycle_state") != lifecycle_state
        or evidence.get("instance_identity") != ("RETIRED" if operation == "PURGE" else "PRESERVED")
        or evidence.get("mutable_instance_data") != ("REMOVED" if operation == "PURGE" else "PRESERVED")
        or evidence.get("provider_auth_state") != (
            "REMOVED_WITH_INSTANCE_DATA" if operation == "PURGE"
            else "PRESERVED_REQUIRES_REVERIFICATION"
        )
        or operation == "PRESERVE" and restorable is not True
        or operation == "PURGE" and restorable is not False
        or operation == "RESTORE" and evidence.get("ready") is not False
        or operation == "RESTORE" and evidence.get("restored_from_preserve_operation")
            != preserve_operation_id
    ):
        raise ProductPreservedLifecycleError("lifecycle terminal state contradicts product contract")
    if operation != "PURGE":
        tree_digest = evidence.get("mutable_instance_data_digest")
        if not isinstance(tree_digest, str) or _DIGEST.fullmatch(tree_digest) is None:
            raise ProductPreservedLifecycleError("preserved data evidence is unavailable")
    if component == FORGE_COMPONENT:
        if evidence.get("service_definition") != "DEPLOYMENT_OWNER":
            raise ProductPreservedLifecycleError("Forge service ownership changed")
        if operation == "RESTORE" and evidence.get("service_state") != "DEPLOYMENT_OWNER_REINSTALL_REQUIRED":
            raise ProductPreservedLifecycleError("Forge restore still needs service installation")
    elif operation == "RESTORE" and evidence.get("service_state") != "REGISTERED_INACTIVE":
        raise ProductPreservedLifecycleError("EP restore service must remain inactive")

    if (
        status.get("contract") != contract
        or status.get("operation") != operation
        or status.get("operation_id") != operation_id
        or status.get("instance_id") != instance_id
        or status.get("phase") != "COMPLETE"
        or status.get("state") != "COMPLETE"
        or status.get("lifecycle_state") != lifecycle_state
        or status.get("restorable") != restorable
        or status.get(receipt_digest_key) != digest
    ):
        raise ProductPreservedLifecycleError("independent lifecycle status disagrees with receipt")
    if component == FORGE_COMPONENT and status.get("request_digest") != request_digest:
        raise ProductPreservedLifecycleError("Forge lifecycle status request changed")
    return ProductPreservedLifecycleTerminal(
        component, operation, operation_id, instance_id,
        lifecycle_state, digest, restorable, preserve_operation_id,
    )
