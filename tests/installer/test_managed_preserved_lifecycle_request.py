#!/usr/bin/env python3
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_preserved_lifecycle_proposal import prepare_native_preserved_lifecycle_review
from forge_platform.managed_preserved_lifecycle_request import (
    ManagedPreservedLifecycleRequestError,
    NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA,
    NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA,
    NATIVE_RESTORE_REQUEST_SCHEMA,
    decode_native_preserved_lifecycle_receipt,
    decode_native_preserved_lifecycle_request,
    encode_native_preserved_lifecycle_receipt,
)
from tests.installer.test_managed_preserved_lifecycle_plan import _fixture
from tests.installer.test_managed_preserved_lifecycle_proposal import _intent, _wire
from tests.installer.test_managed_product_operation_admission import installer_release


def _request(
    manifest, registry, operation="PRESERVE", confirmation=None,
    component=None, instance_id=None,
):
    intent = _intent(manifest, operation=operation)
    if component is not None:
        intent["component"] = component
    if instance_id is not None:
        intent["instance_id"] = instance_id
    if operation in {"PURGE", "RESTORE"}:
        intent["operation_id"] = "purge-a" if operation == "PURGE" else "restore-a"
    intent["intent_fingerprint"] = sha256(_wire({
        key: item for key, item in intent.items()
        if key != "intent_fingerprint"
    })).hexdigest()
    proposal = json.loads(prepare_native_preserved_lifecycle_review(
        _wire(intent), installed_manifest=manifest, registry=registry,
        current_installer_release=installer_release(),
    ))
    request = {
        "schema": (NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA if operation == "PURGE"
                   else NATIVE_RESTORE_REQUEST_SCHEMA if operation == "RESTORE"
                   else NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA),
        "intent": intent, "proposal": proposal,
    }
    if confirmation is not None:
        request["confirmed_instance_id"] = confirmation
    request["request_fingerprint"] = sha256(_wire(request)).hexdigest()
    return request


class ManagedPreservedLifecycleRequestTests(unittest.TestCase):
    def test_restore_requires_exact_preserved_review_and_no_destructive_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, active, preserved = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(active)
            registry._write(preserved)
            value = _request(manifest, registry, "RESTORE")
            request = decode_native_preserved_lifecycle_request(_wire(value))
            self.assertEqual(request.review.preserve_operation_id, "preserve-a")
            self.assertEqual(request.review.preserve_receipt_digest, "sha256:" + "e" * 64)
            self.assertIsNone(request.confirmed_instance_id)
            for changed in (
                {**value, "schema": NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA},
                {**value, "schema": NATIVE_CONFIRMED_PURGE_REQUEST_SCHEMA,
                 "confirmed_instance_id": "forge-a"},
                {**value, "confirmed_instance_id": "forge-a"},
            ):
                changed["request_fingerprint"] = sha256(_wire({
                    key: item for key, item in changed.items()
                    if key != "request_fingerprint"
                })).hexdigest()
                with self.assertRaises(ManagedPreservedLifecycleRequestError):
                    decode_native_preserved_lifecycle_request(_wire(changed))

    def test_purge_requires_exact_reviewed_instance_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, current, _ = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(current)
            value = _request(manifest, registry, "PURGE", "forge-a")
            request = decode_native_preserved_lifecycle_request(_wire(value))
            self.assertEqual(request.intent.operation, "PURGE")
            self.assertEqual(request.confirmed_instance_id, "forge-a")
            self.assertTrue(request.review.destructive_confirmation_required)
            for bad in (
                _request(manifest, registry, "PURGE"),
                _request(manifest, registry, "PURGE", "forge-b"),
                value | {"schema": NATIVE_PRESERVED_LIFECYCLE_REQUEST_SCHEMA},
            ):
                bad["request_fingerprint"] = sha256(_wire({
                    key: item for key, item in bad.items()
                    if key != "request_fingerprint"
                })).hexdigest()
                with self.assertRaises(ManagedPreservedLifecycleRequestError):
                    decode_native_preserved_lifecycle_request(_wire(bad))

    def test_exact_proposal_roundtrip_and_terminal_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, current, _ = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(current)
            request = decode_native_preserved_lifecycle_request(_wire(_request(manifest, registry)))
            self.assertEqual(request.review.deployment_id, current.deployment_id)
            self.assertEqual(request.review.operation, "PRESERVE")
            digest = "sha256:" + "a" * 64
            receipt = encode_native_preserved_lifecycle_receipt(
                request, receipt_digest=digest, registry_revision=2,
            )
            self.assertEqual(decode_native_preserved_lifecycle_receipt(
                receipt, request=request,
            )["receipt_digest"], digest)
            self.assertNotIn(b"data_root", receipt)

    def test_request_rejects_unreviewed_other_lifecycle_and_ambiguity(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, current, _ = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(current)
            value = _request(manifest, registry)
            for bad in (
                _wire(value) + b" ",
                b"x" * 40961,
                _wire(value)[:-1] + b',"schema":"duplicate"}',
                _wire(value).replace(b'"operation":"PRESERVE"', b'"operation":"PURGE"'),
            ):
                with self.subTest(bad=bad[:30]), self.assertRaises(ManagedPreservedLifecycleRequestError):
                    decode_native_preserved_lifecycle_request(bad)
            changed = json.loads(_wire(value))
            changed["proposal"]["review"]["registry_revision"] += 1
            changed["request_fingerprint"] = sha256(_wire({key: val for key, val in changed.items() if key != "request_fingerprint"})).hexdigest()
            with self.assertRaises(ManagedPreservedLifecycleRequestError):
                decode_native_preserved_lifecycle_request(_wire(changed))

    def test_receipt_rejects_wrong_digest_revision_and_target(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, current, _ = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(current)
            request = decode_native_preserved_lifecycle_request(_wire(_request(manifest, registry)))
            valid = json.loads(encode_native_preserved_lifecycle_receipt(
                request, receipt_digest="sha256:" + "a" * 64, registry_revision=2,
            ))
            for field, replacement in (
                ("receipt_digest", "sha256:wrong"),
                ("registry_revision", 3),
                ("operation_id", "foreign"),
                ("instance_id", "other"),
                ("state", "PENDING"),
            ):
                with self.subTest(field=field), self.assertRaises(ManagedPreservedLifecycleRequestError):
                    decode_native_preserved_lifecycle_receipt(
                        _wire(valid | {field: replacement}), request=request,
                    )


if __name__ == "__main__":
    unittest.main()
