#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
import unittest

from forge_platform.managed_product_removal_admission import (
    decode_native_product_removal_request,
)
from forge_platform.managed_product_removal_proposal import (
    MAXIMUM_NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_BYTES,
    NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_SCHEMA,
    NATIVE_PRODUCT_REMOVAL_REVIEW_PROPOSAL_SCHEMA,
    ManagedProductRemovalProposalError,
    decode_native_product_removal_review_intent,
    decode_native_product_removal_review_proposal,
    prepare_native_product_removal_review,
)
import tests.installer.test_managed_product_removal_admission as fixtures


def canonical(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
    ).encode("utf-8")


def digest(value: object) -> str:
    return sha256(canonical(value)).hexdigest()


class ManagedProductRemovalProposalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = fixtures.ManagedProductRemovalAdmissionTests(
            "test_exact_paired_component_removal_retains_ep_and_other_deployment"
        )
        self.fixture.setUp()

    def tearDown(self) -> None:
        self.fixture.tearDown()

    def intent(self, *, current=None, action="REMOVE_COMPONENT", **changes):
        current = current or self.fixture.paired
        by_component = current.by_component
        intent = {
            "schema": NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_SCHEMA,
            "operation_id": "remove-reviewed-a",
            "deployment_id": current.deployment_id,
            "action": action,
            "target_component": "forge-runtime" if action == "REMOVE_COMPONENT" else None,
            "forge_instance_id": by_component["forge-runtime"].instance_id,
            "engineering_platform_instance_id": (
                by_component["engineering-platform-server"].instance_id
                if "engineering-platform-server" in by_component else None
            ),
            "installed_composition_identity": self.fixture.manifest.composition_id,
            "installed_manifest_sha256": self.fixture.manifest.manifest_digest,
            "installer_release": asdict(self.fixture.release),
        }
        intent.update(changes)
        intent["intent_fingerprint"] = digest(intent)
        return intent

    def prepare(self, intent):
        return prepare_native_product_removal_review(
            canonical(intent), installed_manifest=self.fixture.manifest,
            registry=self.fixture.registry,
            current_installer_release=self.fixture.release,
        )

    def test_paired_forge_component_review_is_read_only_and_exact(self) -> None:
        current = self.fixture.paired
        other = self.fixture.other
        before = (
            (self.fixture.registry.root / "deployment-a.json").read_bytes(),
            (self.fixture.registry.root / "deployment-b.json").read_bytes(),
        )
        intent = self.intent()

        raw = self.prepare(intent)

        proposal = json.loads(raw)
        self.assertEqual(proposal["schema"], NATIVE_PRODUCT_REMOVAL_REVIEW_PROPOSAL_SCHEMA)
        self.assertEqual(proposal["intent_fingerprint"], intent["intent_fingerprint"])
        self.assertEqual(proposal["deployment_action"], "CREATE_OR_UPDATE")
        self.assertEqual(proposal["resulting_components"], ["engineering-platform-server"])
        self.assertEqual(
            [(item["component"], item["action"]) for item in proposal["component_diffs"]],
            [("engineering-platform-server", "NO_CHANGE"), ("forge-runtime", "REMOVE_COMPONENT")],
        )
        request = decode_native_product_removal_request(canonical(proposal["request"]))
        self.assertEqual(request.forge_instance_id, "forge-a")
        self.assertEqual(request.engineering_platform_instance_id, "ep-a")
        self.assertEqual(request.reviewed_revision, current.revision)
        self.assertEqual(self.fixture.registry.load("deployment-a"), current)
        self.assertEqual(self.fixture.registry.load("deployment-b"), other)
        self.assertEqual(before, (
            (self.fixture.registry.root / "deployment-a.json").read_bytes(),
            (self.fixture.registry.root / "deployment-b.json").read_bytes(),
        ))
        self.assertNotIn(b"receipt:forge-a", raw)
        self.assertNotIn(b"credential", raw)

    def test_full_removal_reviews_only_selected_deployment(self) -> None:
        for current in (self.fixture.paired, self.fixture.other):
            with self.subTest(deployment=current.deployment_id):
                proposal = json.loads(self.prepare(self.intent(
                    current=current, action="REMOVE_DEPLOYMENT"
                )))
                self.assertEqual(proposal["deployment_action"], "REMOVE_DEPLOYMENT")
                self.assertEqual(proposal["resulting_components"], [])
                self.assertEqual(
                    {item["component"] for item in proposal["component_diffs"]},
                    set(current.by_component),
                )
                self.assertEqual(proposal["request"]["deployment_id"], current.deployment_id)

    def test_malformed_and_stale_target_fail_closed(self) -> None:
        intent = self.intent()
        for change in (
            {"forge_instance_id": "forge-other"},
            {"engineering_platform_instance_id": "ep-other"},
            {"installed_manifest_sha256": "sha256:" + "0" * 64},
            {"target_component": "engineering-platform-server"},
            {"action": "UPDATE"},
            {"deployment_id": "deployment-missing"},
            {"installer_release": {**intent["installer_release"], "version": "0.0.0"}},
        ):
            with self.subTest(change=change), self.assertRaises(ManagedProductRemovalProposalError):
                self.prepare(self.intent(**change))
        stale = self.intent()
        current = self.fixture.registry.load("deployment-a")
        self.fixture.registry.replace(replace(current, revision=2), expected_revision=1)
        # A fresh review is allowed, and binds the new exact revision. The old
        # reviewed request remains stale at execution admission.
        proposal = json.loads(self.prepare(stale))
        self.assertEqual(proposal["request"]["reviewed_revision"], 2)

    def test_strict_intent_decoder_rejects_duplicate_noncanonical_and_size(self) -> None:
        intent = self.intent()
        raw = canonical(intent)
        self.assertEqual(
            decode_native_product_removal_review_intent(raw).intent_fingerprint,
            intent["intent_fingerprint"],
        )
        for changed in (
            b" " + raw,
            raw.replace(b'"operation_id":', b'"operation_id":"duplicate","operation_id":'),
            raw.replace(b"forge-a", b"forge-b"),
            b"",
            b"x" * (MAXIMUM_NATIVE_PRODUCT_REMOVAL_REVIEW_INTENT_BYTES + 1),
        ):
            with self.subTest(changed=changed[:30]), self.assertRaises(
                ManagedProductRemovalProposalError
            ):
                decode_native_product_removal_review_intent(changed)

    def test_worker_decoder_rejects_review_target_and_diff_substitution(self) -> None:
        intent_payload = self.intent()
        intent = decode_native_product_removal_review_intent(canonical(intent_payload))
        raw = self.prepare(intent_payload)
        proposal = decode_native_product_removal_review_proposal(raw, intent=intent)
        self.assertEqual(proposal["request"]["forge_instance_id"], "forge-a")
        for changes in (
            {"intent_fingerprint": "0" * 64},
            {"deployment_action": "REMOVE_DEPLOYMENT"},
            {"resulting_components": []},
            {"component_diffs": []},
            {"request": {**proposal["request"], "forge_instance_id": "forge-b"}},
        ):
            with self.subTest(changes=changes), self.assertRaises(
                ManagedProductRemovalProposalError
            ):
                decode_native_product_removal_review_proposal(
                    canonical({**proposal, **changes}), intent=intent,
                )
        with self.assertRaises(ManagedProductRemovalProposalError):
            decode_native_product_removal_review_proposal(b" " + raw, intent=intent)


if __name__ == "__main__":
    unittest.main()
