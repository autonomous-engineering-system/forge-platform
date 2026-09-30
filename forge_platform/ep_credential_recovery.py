"""Secret-free EP credential inventory and exact product-owned revocation.

Credential issuance is deliberately outside this boundary. Its status and
revoke operations let a later durable issuer resolve an uncertain response
without creating a second active grant or handling credential material here.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import re

from .ep_consumer_revocation import EPConsumerRevocationAdapter


_CREDENTIAL_ID = re.compile(r"^production-[0-9a-f]{32}$")
_FINGERPRINT = re.compile(r"^[0-9a-f]{64}$")


class EPCredentialRecoveryError(RuntimeError):
    """EP credential state cannot be safely inventoried or revoked."""


@dataclass(frozen=True)
class EPCredentialMetadata:
    credential_id: str
    fingerprint: str
    created_at: str
    expires_at: str | None
    revoked_at: str | None
    active: bool


class EPCredentialRecoveryAdapter:
    """Read and revoke exact credential IDs in one frozen EP consumer scope."""

    def __init__(self, consumer: EPConsumerRevocationAdapter) -> None:
        if not isinstance(consumer, EPConsumerRevocationAdapter):
            raise TypeError("exact EP product consumer adapter is required")
        self.consumer = consumer

    def status(self) -> tuple[EPCredentialMetadata, ...]:
        consumer = self.consumer.status()
        if consumer.get("status") != "ACTIVE":
            raise EPCredentialRecoveryError("EP consumer is not active")
        records = self.consumer._command("credential-status")
        if not isinstance(records, list):
            raise EPCredentialRecoveryError("EP credential status is invalid")
        result = []
        seen = set()
        for record in records:
            if (
                not isinstance(record, dict)
                or set(record) != {
                    "credential_id", "fingerprint", "purpose", "created_at",
                    "expires_at", "revoked_at", "active",
                }
                or not isinstance(record.get("credential_id"), str)
                or _CREDENTIAL_ID.fullmatch(record["credential_id"]) is None
                or record["credential_id"] in seen
                or not isinstance(record.get("fingerprint"), str)
                or _FINGERPRINT.fullmatch(record["fingerprint"]) is None
                or record.get("purpose") != "PRODUCTION_CONSUMER"
                or not isinstance(record.get("created_at"), str)
                or not record["created_at"]
                or not (record.get("expires_at") is None or isinstance(record["expires_at"], str))
                or not (record.get("revoked_at") is None or isinstance(record["revoked_at"], str))
                or not isinstance(record.get("active"), bool)
                or record["active"] and record["revoked_at"] is not None
            ):
                raise EPCredentialRecoveryError("EP credential metadata is ambiguous")
            seen.add(record["credential_id"])
            result.append(EPCredentialMetadata(
                record["credential_id"], record["fingerprint"],
                record["created_at"], record["expires_at"],
                record["revoked_at"], record["active"],
            ))
        if sum(record.active for record in result) != consumer.get("active_production_credentials"):
            raise EPCredentialRecoveryError("EP active credential count changed")
        return tuple(sorted(result, key=lambda record: record.credential_id))

    def revoke_exact(self, credential_id: str) -> EPCredentialMetadata:
        if not isinstance(credential_id, str) or _CREDENTIAL_ID.fullmatch(credential_id) is None:
            raise ValueError("exact production credential ID is required")
        before = self.status()
        selected = next((record for record in before if record.credential_id == credential_id), None)
        if selected is None:
            raise EPCredentialRecoveryError("credential is absent from exact consumer scope")
        if selected.revoked_at is None:
            interpreter, database, uid, gid = self.consumer._authority()
            response = self.consumer.runner.run(
                (
                    str(interpreter), "-I", "-m", "engineering_platform.ep_consumer_credentials",
                    "credential-revoke", "--repo", str(database.parent),
                    "--credential-id", credential_id,
                ),
                database=database, uid=uid, gid=gid,
            )
            try:
                receipt = json.loads(response.stdout) if response.returncode == 0 else None
            except (TypeError, ValueError):
                receipt = None
            if receipt != {"credential_id": credential_id, "revoked": True, "changed": True}:
                raise EPCredentialRecoveryError("EP credential revoke receipt is invalid")
        after = self.status()
        terminal = next((record for record in after if record.credential_id == credential_id), None)
        if (
            terminal is None or terminal.active or not terminal.revoked_at
            or terminal.fingerprint != selected.fingerprint
            or terminal.created_at != selected.created_at
            or any(
                old != new for old, new in zip(
                    (item for item in before if item.credential_id != credential_id),
                    (item for item in after if item.credential_id != credential_id),
                )
            )
            or len(before) != len(after)
        ):
            raise EPCredentialRecoveryError("EP credential revocation readback changed")
        return terminal
