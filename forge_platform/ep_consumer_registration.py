"""Product-owned registration of a new EP consumer after exact old revocation.

This boundary never issues or transports a credential. The caller supplies the
reviewed new consumer identity; EP owns registration and status readback.
"""

from __future__ import annotations

from hashlib import sha256
import json
from typing import Mapping

from .ep_consumer_revocation import EPConsumerRevocationAdapter


class EPConsumerRegistrationError(RuntimeError):
    """The new product consumer could not be bound to the revoked old scope."""


class EPInitialConsumerRegistrationAdapter:
    """Register the exact first consumer using EP's idempotent product boundary.

    A fresh call rejects an already registered scope. Only a caller holding a
    durable PREPARED record may allow an idempotent replay after a lost reply.
    The adapter never issues a credential or accepts a database path.
    """

    def __init__(self, consumer: EPConsumerRevocationAdapter) -> None:
        if not isinstance(consumer, EPConsumerRevocationAdapter):
            raise TypeError("exact EP consumer authority is required")
        self.consumer = consumer

    def register(self, *, recovering: bool = False) -> str:
        if type(recovering) is not bool:
            raise TypeError("EP registration recovery authority must be boolean")
        scope = self.consumer.scope
        registered = self.consumer._command("consumer-register")
        if (
            not isinstance(registered, Mapping)
            or set(registered) != {
                "consumer_id", "project_id", "status", "created_at",
                "updated_at", "idempotent",
            }
            or registered.get("consumer_id") != scope.consumer_id
            or registered.get("project_id") != scope.project_id
            or registered.get("status") != "ACTIVE"
            or not isinstance(registered.get("created_at"), str)
            or not registered["created_at"]
            or not isinstance(registered.get("updated_at"), str)
            or not registered["updated_at"]
            or type(registered.get("idempotent")) is not bool
            or registered["idempotent"] and not recovering
        ):
            raise EPConsumerRegistrationError("initial EP registration receipt is unsafe")
        observed = self.consumer.status()
        if (
            observed.get("status") != "ACTIVE"
            or observed.get("consumer_id") != scope.consumer_id
            or observed.get("project_id") != scope.project_id
            or observed.get("created_at") != registered["created_at"]
            or observed.get("updated_at") != registered["updated_at"]
            or observed.get("disabled_at") is not None
            or observed.get("revoked_at") is not None
            or observed.get("active_production_credentials") != 0
        ):
            raise EPConsumerRegistrationError("initial EP consumer readback changed")
        evidence = {
            "instance_id": self.consumer.provisioner.target.instance_id,
            "consumer_id": scope.consumer_id,
            "project_id": scope.project_id,
            "created_at": registered["created_at"],
            "updated_at": registered["updated_at"],
        }
        return "ep-consumer-register:sha256:" + sha256(json.dumps(
            evidence, sort_keys=True, separators=(",", ":"),
        ).encode()).hexdigest()


class EPConsumerRegistrationAdapter:
    """Register one distinct new consumer in the same exact EP instance/scope."""

    def __init__(
        self, *, old: EPConsumerRevocationAdapter,
        new: EPConsumerRevocationAdapter,
    ) -> None:
        if not isinstance(old, EPConsumerRevocationAdapter) or not isinstance(
            new, EPConsumerRevocationAdapter
        ):
            raise TypeError("exact EP product consumer adapters are required")
        if (
            old.provisioner is not new.provisioner
            or old.expected_artifact != new.expected_artifact
            or old.scope.project_id != new.scope.project_id
            or old.scope.consumer_id == new.scope.consumer_id
        ):
            raise ValueError("new EP consumer must retain the exact product and project scope")
        self.old = old
        self.new = new

    def register(self) -> str:
        before = self.old.status()
        if before.get("status") != "REVOKED" or not before.get("revoked_at"):
            raise EPConsumerRegistrationError("old EP consumer is not terminally revoked")
        registered = self.new._command("consumer-register")
        if (
            not isinstance(registered, Mapping)
            or set(registered) != {
                "consumer_id", "project_id", "status", "created_at",
                "updated_at", "idempotent",
            }
            or registered.get("consumer_id") != self.new.scope.consumer_id
            or registered.get("project_id") != self.new.scope.project_id
            or registered.get("status") != "ACTIVE"
            or not isinstance(registered.get("created_at"), str)
            or not registered["created_at"]
            or not isinstance(registered.get("updated_at"), str)
            or not registered["updated_at"]
            or not isinstance(registered.get("idempotent"), bool)
        ):
            raise EPConsumerRegistrationError("EP registration receipt changed")
        after = self.new.status()
        old_after = self.old.status()
        if (
            after.get("status") != "ACTIVE"
            or after.get("created_at") != registered["created_at"]
            or after.get("updated_at") != registered["updated_at"]
            or after.get("disabled_at") is not None
            or after.get("revoked_at") is not None
            or after.get("active_production_credentials") != 0
            or old_after.get("status") != "REVOKED"
            or old_after.get("revoked_at") != before["revoked_at"]
        ):
            raise EPConsumerRegistrationError("EP new/old consumer readback changed")
        evidence = {
            "instance_id": self.new.provisioner.target.instance_id,
            "old_consumer_id": self.old.scope.consumer_id,
            "old_revoked_at": old_after["revoked_at"],
            "new_consumer_id": self.new.scope.consumer_id,
            "project_id": self.new.scope.project_id,
            "new_created_at": after["created_at"],
            "new_updated_at": after["updated_at"],
        }
        return "ep-consumer-register:sha256:" + sha256(
            json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
