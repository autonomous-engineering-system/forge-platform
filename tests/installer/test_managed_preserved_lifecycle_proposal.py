#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_product_worker import (
    InstallerProductWorkerUnavailable,
    execute_preserved_lifecycle_review_intent,
    run,
)
from forge_platform.managed_deployments import ManagedDeploymentRegistry
from forge_platform.managed_preserved_lifecycle_proposal import (
    ManagedPreservedLifecycleProposalError,
    NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_SCHEMA,
    NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_SCHEMA,
    decode_native_preserved_lifecycle_review_intent,
    decode_native_preserved_lifecycle_review_proposal,
    prepare_native_preserved_lifecycle_review,
)
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService,
    ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from forge_platform.product_preserved_lifecycle import FORGE_COMPONENT
from tests.installer.test_managed_preserved_lifecycle_plan import _fixture
from tests.installer.test_managed_product_operation_admission import installer_release


def _wire(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ).encode("utf-8")


def _intent(manifest, operation="PRESERVE", operation_id="preserve-a"):
    payload = {
        "schema": NATIVE_PRESERVED_LIFECYCLE_REVIEW_INTENT_SCHEMA,
        "operation_id": operation_id,
        "deployment_id": "reviewed-pair",
        "operation": operation,
        "component": FORGE_COMPONENT,
        "instance_id": "forge-a",
        "installed_composition_identity": manifest.composition_id,
        "installed_manifest_sha256": manifest.manifest_digest,
        "installer_release": asdict(installer_release()),
    }
    payload["intent_fingerprint"] = sha256(_wire(payload)).hexdigest()
    return payload


class ManagedPreservedLifecycleProposalTests(unittest.TestCase):
    def test_helper_prepares_exact_read_only_proposals_for_all_transitions(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, active, preserved = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(active)
            for operation, record in (
                ("PRESERVE", active), ("PURGE", active),
                ("RESTORE", preserved), ("PURGE", preserved),
            ):
                with self.subTest(operation=operation):
                    registry._write(record)
                    payload = _intent(manifest, operation, operation.lower() + "-a")
                    intent = decode_native_preserved_lifecycle_review_intent(_wire(payload))
                    proposal_bytes = prepare_native_preserved_lifecycle_review(
                        _wire(payload), installed_manifest=manifest, registry=registry,
                        current_installer_release=installer_release(),
                    )
                    proposal = decode_native_preserved_lifecycle_review_proposal(
                        proposal_bytes, intent=intent,
                    )
                    self.assertEqual(
                        proposal["schema"],
                        NATIVE_PRESERVED_LIFECYCLE_REVIEW_PROPOSAL_SCHEMA,
                    )
                    self.assertEqual(proposal["review"]["registry_revision"], record.revision)
                    self.assertEqual(proposal["review"]["operation"], operation)
                    self.assertEqual(
                        proposal["review"]["destructive_confirmation_required"],
                        operation == "PURGE",
                    )
                    if operation == "RESTORE":
                        self.assertEqual(
                            proposal["review"]["preserve_operation_id"], "preserve-a",
                        )

    def test_intent_and_proposal_reject_tamper_ambiguity_and_stale_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, active, _ = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(active)
            payload = _intent(manifest)
            raw = _wire(payload)
            intent = decode_native_preserved_lifecycle_review_intent(raw)
            proposal = prepare_native_preserved_lifecycle_review(
                raw, installed_manifest=manifest, registry=registry,
                current_installer_release=installer_release(),
            )
            for invalid in (
                raw + b" ",
                raw.replace(b'"operation":"PRESERVE"', b'"operation":"PURGE"'),
                raw[:-1] + b',"operation":"PRESERVE"}',
                b"x" * 8193,
            ):
                with self.subTest(invalid=invalid[:40]), self.assertRaises(
                    ManagedPreservedLifecycleProposalError
                ):
                    decode_native_preserved_lifecycle_review_intent(invalid)
            with self.assertRaisesRegex(ManagedPreservedLifecycleProposalError, "unavailable"):
                prepare_native_preserved_lifecycle_review(
                    raw, installed_manifest=replace(
                        manifest, manifest_digest="sha256:" + "f" * 64,
                    ), registry=registry, current_installer_release=installer_release(),
                )
            changed = json.loads(proposal)
            changed["review"]["registry_revision"] += 1
            with self.assertRaisesRegex(ManagedPreservedLifecycleProposalError, "rejected"):
                decode_native_preserved_lifecycle_review_proposal(
                    _wire(changed), intent=intent,
                )
            changed = json.loads(proposal)
            changed["review"]["destructive_confirmation_required"] = True
            with self.assertRaisesRegex(ManagedPreservedLifecycleProposalError, "rejected"):
                decode_native_preserved_lifecycle_review_proposal(
                    _wire(changed), intent=intent,
                )
            changed = json.loads(proposal)
            changed["review"]["artifact"]["version"] = "2.7.99"
            unsigned = dict(changed["review"])
            unsigned.pop("review_fingerprint")
            changed["review"]["review_fingerprint"] = "sha256:" + sha256(
                _wire(unsigned),
            ).hexdigest()
            with self.assertRaisesRegex(ManagedPreservedLifecycleProposalError, "rejected"):
                decode_native_preserved_lifecycle_review_proposal(
                    _wire(changed), intent=intent,
                )

    def test_recomputed_review_fingerprint_cannot_change_preserve_state(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, active, preserved = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(active)
            cases = (
                ("PRESERVE", active, "preserve_operation_id", "preserve-old"),
                ("RESTORE", preserved, "preserve_receipt_digest", None),
                ("PURGE", preserved, "preserve_operation_id", None),
                ("PURGE", active, "preserve_receipt_digest", "sha256:" + "f" * 64),
            )
            for operation, record, field, value in cases:
                with self.subTest(operation=operation, field=field, value=value):
                    registry._write(record)
                    payload = _intent(manifest, operation, operation.lower() + "-state")
                    intent = decode_native_preserved_lifecycle_review_intent(_wire(payload))
                    proposal = json.loads(prepare_native_preserved_lifecycle_review(
                        _wire(payload), installed_manifest=manifest, registry=registry,
                        current_installer_release=installer_release(),
                    ))
                    proposal["review"][field] = value
                    unsigned = dict(proposal["review"])
                    unsigned.pop("review_fingerprint")
                    proposal["review"]["review_fingerprint"] = "sha256:" + sha256(
                        _wire(unsigned),
                    ).hexdigest()
                    with self.assertRaises(ManagedPreservedLifecycleProposalError):
                        decode_native_preserved_lifecycle_review_proposal(
                            _wire(proposal), intent=intent,
                        )

    def test_released_service_and_worker_emit_only_valid_correlated_review(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, active, _ = _fixture()
            registry = ManagedDeploymentRegistry(Path(directory).resolve())
            registry.create(active)
            resolver = PinnedManagedProductOperationAuthorityResolver(
                current_installer_release=installer_release(),
                manifests=(manifest,),
            )
            service = object.__new__(ManagedProductOperationHelperService)
            service.authority_resolver = resolver
            service.dispatcher = SimpleNamespace(
                coordinator=SimpleNamespace(registry=registry),
            )
            raw = _wire(_intent(manifest))
            response = service.prepare_preserved_lifecycle_review(raw)
            self.assertEqual(
                execute_preserved_lifecycle_review_intent(
                    raw, service_loader=lambda: service,
                ), response,
            )
            output = io.BytesIO()
            self.assertEqual(run(io.BytesIO(raw), output, service_loader=lambda: service), 0)
            self.assertEqual(output.getvalue(), response)
            with self.assertRaisesRegex(ManagedProductOperationServiceError, "rejected"):
                service.prepare_preserved_lifecycle_review(
                    _wire(_intent(manifest) | {"instance_id": "forge-other"}),
                )
            original = service.prepare_preserved_lifecycle_review
            service.prepare_preserved_lifecycle_review = lambda _raw: b'{"bad":true}'
            try:
                with self.assertRaisesRegex(InstallerProductWorkerUnavailable, "rejected"):
                    execute_preserved_lifecycle_review_intent(
                        raw, service_loader=lambda: service,
                    )
                self.assertEqual(run(io.BytesIO(raw), io.BytesIO(), service_loader=lambda: service), 1)
            finally:
                service.prepare_preserved_lifecycle_review = original


if __name__ == "__main__":
    unittest.main()
