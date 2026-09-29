"""Frozen product preserve/restore/purge receipt and independent status evidence."""

from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
import json
import unittest

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.product_preserved_lifecycle import (
    EP_COMPONENT, EP_CONTRACT, FORGE_COMPONENT, FORGE_CONTRACT,
    ProductPreservedLifecycleError, frozen_preserved_release,
    validate_terminal_preserved_lifecycle,
)


_IDENTITIES = {
    FORGE_COMPONENT: (
        "2.7.37", "a78523603d6ea081d07875ea6b557e73b5d4fe63",
        "sha256:b8165e59935a1edf22590cf6378fab3c5b1014aded88eec1e1a294bfa1b94938",
    ),
    EP_COMPONENT: (
        "2.3.106", "7b99b578153ae5d72372a09db194306b49ec9f9c",
        "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694",
    ),
}
_REQUEST = "sha256:" + "a" * 64
_TREE = "sha256:" + "b" * 64


def _artifact(component: str) -> QualifiedArtifact:
    version, source, digest = _IDENTITIES[component]
    return QualifiedArtifact(version, source, "released-wheel", digest, "release-complete")


def _receipt_digest(component: str, value: dict[str, object]) -> str:
    if component == FORGE_COMPONENT:
        encoded = (json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ) + "\n").encode()
    else:
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + sha256(encoded).hexdigest()


def _evidence(component: str, operation: str) -> dict[str, object]:
    state = {
        "PRESERVE": "UNINSTALLED_DATA_PRESERVED",
        "RESTORE": (
            "RESTORE_VALIDATED" if component == FORGE_COMPONENT
            else "RESTORED_REQUIRES_PROVIDER_REVERIFICATION"
        ),
        "PURGE": "PURGED",
    }[operation]
    evidence: dict[str, object] = {
        "lifecycle_state": state,
        "instance_identity": "RETIRED" if operation == "PURGE" else "PRESERVED",
        "mutable_instance_data": "REMOVED" if operation == "PURGE" else "PRESERVED",
        "provider_auth_state": (
            "REMOVED_WITH_INSTANCE_DATA" if operation == "PURGE"
            else "PRESERVED_REQUIRES_REVERIFICATION"
        ),
        "service_state": (
            "DEPLOYMENT_OWNER_REINSTALL_REQUIRED" if component == FORGE_COMPONENT
            and operation == "RESTORE" else
            "REGISTERED_INACTIVE" if component == EP_COMPONENT and operation == "RESTORE"
            else "REMOVED_OR_INACTIVE"
        ),
    }
    if operation != "PURGE":
        evidence["mutable_instance_data_digest"] = _TREE
    if operation == "PRESERVE":
        evidence["restorable"] = True
    elif operation == "PURGE":
        evidence["restorable"] = False
    else:
        evidence["restored_from_preserve_operation"] = "preserve-1"
        evidence["ready"] = False
        if component == EP_COMPONENT:
            evidence["restorable"] = False
    if component == FORGE_COMPONENT:
        evidence["service_definition"] = "DEPLOYMENT_OWNER"
    return evidence


def _terminal(component: str, operation: str) -> tuple[dict[str, object], dict[str, object]]:
    contract = FORGE_CONTRACT if component == FORGE_COMPONENT else EP_CONTRACT
    evidence = _evidence(component, operation)
    receipt: dict[str, object] = {
        "contract": contract, "operation": operation,
        "operation_id": "lifecycle-1", "instance_id": "instance-1",
        "request_digest": _REQUEST, "state": "COMPLETE",
    }
    if component == FORGE_COMPONENT:
        artifact = _artifact(component)
        receipt.update({
            "runtime_id": "instance-1", "installation_id": "install-1",
            "selected_artifact": {
                "version": artifact.version,
                "source_revision": artifact.source_revision,
                "artifact_digest": artifact.digest,
            },
            **evidence,
            "completed_at": "2026-09-28T00:00:00Z",
        })
        key = "receipt_digest"
    else:
        receipt["evidence"] = evidence
        key = "receipt_sha256"
    receipt[key] = _receipt_digest(component, receipt)
    status: dict[str, object] = {
        "contract": contract, "operation": operation,
        "operation_id": "lifecycle-1", "instance_id": "instance-1",
        "phase": "COMPLETE", "state": "COMPLETE",
        "lifecycle_state": evidence["lifecycle_state"],
        "restorable": evidence.get("restorable"),
        key: receipt[key],
    }
    if component == FORGE_COMPONENT:
        status["request_digest"] = _REQUEST
    return receipt, status


def _validate(component: str, operation: str, receipt: dict, status: dict):
    return validate_terminal_preserved_lifecycle(
        component=component, operation=operation,
        operation_id="lifecycle-1", instance_id="instance-1",
        artifact=_artifact(component), request_digest=_REQUEST,
        receipt=receipt, status=status,
        preserve_operation_id="preserve-1" if operation == "RESTORE" else None,
    )


class ProductPreservedLifecycleTests(unittest.TestCase):
    def test_exact_frozen_release_bytes(self) -> None:
        for component in _IDENTITIES:
            artifact = _artifact(component)
            self.assertTrue(frozen_preserved_release(component, artifact))
            self.assertFalse(frozen_preserved_release("foreign", artifact))
            self.assertFalse(frozen_preserved_release(component, None))
            for field, value in (
                ("version", "0.0.0"),
                ("source_revision", "0" * 40),
                ("digest", "sha256:" + "0" * 64),
            ):
                modified = artifact.__dict__ | {field: value}
                self.assertFalse(frozen_preserved_release(
                    component, QualifiedArtifact(**modified)
                ))

    def test_historical_wheels_lack_new_mutation_authority(self) -> None:
        historical = {
            FORGE_COMPONENT: QualifiedArtifact(
                "2.7.36", "ed1e623ef3cedd8c4f720510e0052409b2d5ab1f",
                "released-wheel",
                "sha256:c10e9584649538f2f1547bb09fd3982cc3495dcf34ef807d66463661fdd5cd68",
                "release-complete",
            ),
            EP_COMPONENT: QualifiedArtifact(
                "2.3.103", "9b1b9d49d7c8f6ceb7cae914078f56b475e8f4a2",
                "released-wheel",
                "sha256:0199a7aab3b25260b6cd4ad53f0aecc7e59c9403ef9a3bd4639993ab9e56910c",
                "release-complete",
            ),
        }
        for component, artifact in historical.items():
            self.assertFalse(frozen_preserved_release(component, artifact))

        for version, source, digest in (
            (
                "2.3.104", "cfce69892278ee2b6c14412c171f5f33596acb0e",
                "sha256:3f7822fd081598f81d5c666200787a3b2182d7004c078cc36ec20455269909cb",
            ),
            (
                "2.3.105", "ad44263f6ec87ea018cda11f053fa12521ae9d79",
                "sha256:22dd1e49c263b55dc9eee396810a09fc43509984fe685f3c00d26289d55e8adc",
            ),
        ):
            self.assertFalse(frozen_preserved_release(
                EP_COMPONENT, QualifiedArtifact(
                    version, source, "released-wheel", digest, "release-complete",
                ),
            ))

    def test_all_product_terminal_operations_bind_exact_status(self) -> None:
        for component in _IDENTITIES:
            for operation in ("PRESERVE", "RESTORE", "PURGE"):
                with self.subTest(component=component, operation=operation):
                    receipt, status = _terminal(component, operation)
                    terminal = _validate(component, operation, receipt, status)
                    self.assertEqual(terminal.component, component)
                    self.assertEqual(terminal.operation, operation)
                    self.assertEqual(terminal.instance_id, "instance-1")
                    self.assertEqual(terminal.receipt_digest, status[
                        "receipt_digest" if component == FORGE_COMPONENT else "receipt_sha256"
                    ])
                    self.assertEqual(terminal.preserve_operation_id,
                                     "preserve-1" if operation == "RESTORE" else None)

    def test_receipt_and_status_mismatch_fail_closed(self) -> None:
        for component in _IDENTITIES:
            for operation in ("PRESERVE", "RESTORE", "PURGE"):
                receipt, status = _terminal(component, operation)
                for field, value in (
                    ("operation_id", "other-operation"),
                    ("instance_id", "other-instance"),
                    ("request_digest", "sha256:" + "0" * 64),
                    ("state", "IN_PROGRESS"),
                    ("contract", "legacy-remove/v1"),
                ):
                    changed = deepcopy(receipt)
                    changed[field] = value
                    with self.subTest(component=component, operation=operation, field=field):
                        with self.assertRaises(ProductPreservedLifecycleError):
                            _validate(component, operation, changed, status)
                for field, value in (
                    ("phase", "VERIFIED"),
                    ("state", "IN_PROGRESS"),
                    ("lifecycle_state", "PURGED" if operation != "PURGE" else "PRESERVED"),
                    ("instance_id", "other-instance"),
                    ("restorable", "unknown"),
                ):
                    changed_status = status | {field: value}
                    with self.assertRaises(ProductPreservedLifecycleError):
                        _validate(component, operation, receipt, changed_status)

    def test_digest_valid_but_semantically_wrong_product_evidence_fails(self) -> None:
        for component in _IDENTITIES:
            for operation in ("PRESERVE", "RESTORE", "PURGE"):
                receipt, status = _terminal(component, operation)
                key = "receipt_digest" if component == FORGE_COMPONENT else "receipt_sha256"
                changed = deepcopy(receipt)
                evidence = changed if component == FORGE_COMPONENT else changed["evidence"]
                evidence["provider_auth_state"] = "READY"
                changed[key] = _receipt_digest(component, {k: v for k, v in changed.items() if k != key})
                status[key] = changed[key]
                with self.assertRaises(ProductPreservedLifecycleError):
                    _validate(component, operation, changed, status)

    def test_restore_requires_original_preserve_operation(self) -> None:
        for component in _IDENTITIES:
            receipt, status = _terminal(component, "RESTORE")
            with self.assertRaises(ProductPreservedLifecycleError):
                validate_terminal_preserved_lifecycle(
                    component=component, operation="RESTORE", operation_id="lifecycle-1",
                    instance_id="instance-1", artifact=_artifact(component),
                    request_digest=_REQUEST, receipt=receipt, status=status,
                )
            with self.assertRaises(ProductPreservedLifecycleError):
                validate_terminal_preserved_lifecycle(
                    component=component, operation="PRESERVE", operation_id="lifecycle-1",
                    instance_id="instance-1", artifact=_artifact(component),
                    request_digest=_REQUEST, receipt=receipt, status=status,
                    preserve_operation_id="preserve-1",
                )

    def test_invalid_target_and_non_json_receipt_fail_closed(self) -> None:
        receipt, status = _terminal(FORGE_COMPONENT, "PRESERVE")
        for wrong in ("../foreign", "", "other/instance"):
            with self.assertRaises(ProductPreservedLifecycleError):
                validate_terminal_preserved_lifecycle(
                    component=FORGE_COMPONENT, operation="PRESERVE",
                    operation_id="lifecycle-1", instance_id=wrong,
                    artifact=_artifact(FORGE_COMPONENT), request_digest=_REQUEST,
                    receipt=receipt, status=status,
                )
        changed = receipt | {"non_json": float("nan")}
        with self.assertRaises(ProductPreservedLifecycleError):
            _validate(FORGE_COMPONENT, "PRESERVE", changed, status)
