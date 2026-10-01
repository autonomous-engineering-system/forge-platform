from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
import unittest

from forge_platform.released_pairing_repair_admission import (
    MAXIMUM_REQUEST_BYTES, REQUEST_SCHEMA, ReleasedPairingRepairAdmissionError,
    admit_repair_request, decode_repair_request,
)
from tests.installer import test_released_pairing_repair_review as review_fixture


canonical = review_fixture.canonical


class ReleasedPairingRepairAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.review = review_fixture.ReleasedRepairReviewTests(
            "test_exact_proposal_is_read_only_and_secret_free"
        )
        self.review.setUp()
        self.addCleanup(self.review.doCleanups)

    def request(self, **changes):
        intent = json.loads(self.review.intent())
        proposal = json.loads(self.review.prepare(self.review.intent()))
        value = {
            "schema": REQUEST_SCHEMA,
            "review_intent": intent,
            "reviewed_revision": proposal["reviewed_revision"],
            "reviewed_deployment_sha256": proposal["reviewed_deployment_sha256"],
            "reviewed_plan_fingerprint": proposal["reviewed_plan_fingerprint"],
            "confirmed": True,
        }
        value.update(changes)
        value["request_fingerprint"] = sha256(canonical(value)).hexdigest()
        return canonical(value)

    def admit(self, raw):
        return admit_repair_request(
            raw, registry=self.review.fixture.registry,
            installed_manifest=self.review.fixture.manifest,
            current_installer_release=self.review.fixture.release,
            routes={"deployment-a": self.review.route},
        )

    def test_exact_confirmed_repair_is_read_only_and_sibling_unchanged(self):
        before = self.review.fixture.registry.load("deployment-a")
        sibling = self.review.fixture.registry.load("deployment-b")
        raw = self.request()
        admitted = self.admit(raw)
        self.assertEqual(admitted.request_fingerprint,
                         decode_repair_request(raw)["request_fingerprint"])
        self.assertEqual(admitted.selection.operation_id, "repair-a")
        self.assertEqual(admitted.selection.plan.component_diffs[1].action, "REPAIR")
        self.assertEqual(self.review.fixture.registry.load("deployment-a"), before)
        self.assertEqual(self.review.fixture.registry.load("deployment-b"), sibling)
        self.assertNotIn(b"keychain", raw)
        self.assertNotIn(str(self.review.route.forge_target.data_root).encode(), raw)

    def test_malformed_confirmation_and_caller_authority_fail_closed(self):
        valid = self.request()
        for raw in (
            valid + b" ", valid + b" " * MAXIMUM_REQUEST_BYTES,
            b"\xff", b'{"schema":NaN}',
            valid.replace(b'"confirmed":true', b'"confirmed":false'),
            valid.replace(b'"schema":', b'"schema":"duplicate","schema":', 1),
            self.request(path="/tmp/credential"),
            self.request(confirmed=False),
            self.request(reviewed_revision=True),
            self.request(reviewed_plan_fingerprint="sha256:invalid"),
            self.request(review_intent={"operation_id": "repair-a"}),
        ):
            with self.subTest(raw=raw[:80]), self.assertRaises(ReleasedPairingRepairAdmissionError):
                self.admit(raw)

    def test_review_drift_release_drift_and_wrong_route_fail_closed(self):
        for raw in (
            self.request(reviewed_revision=2),
            self.request(reviewed_deployment_sha256="0" * 64),
            self.request(reviewed_plan_fingerprint="sha256:" + "0" * 64),
            self.request(review_intent={
                **json.loads(self.review.intent()),
                "installer_release": {
                    **asdict(self.review.fixture.release), "version": "9.9.9",
                },
            }),
        ):
            with self.subTest(raw=raw[:80]), self.assertRaises(ReleasedPairingRepairAdmissionError):
                self.admit(raw)
        valid = self.request()
        current = self.review.fixture.registry.load("deployment-a")
        self.review.fixture.registry.replace(
            replace(current, revision=2), expected_revision=1,
        )
        with self.assertRaises(ReleasedPairingRepairAdmissionError):
            self.admit(valid)

    def test_missing_route_fails_closed(self):
        with self.assertRaises(ReleasedPairingRepairAdmissionError):
            admit_repair_request(
                self.request(), registry=self.review.fixture.registry,
                installed_manifest=self.review.fixture.manifest,
                current_installer_release=self.review.fixture.release,
                routes={},
            )


if __name__ == "__main__":
    unittest.main()
