from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
from io import BytesIO
import unittest

from forge_platform.released_pairing_repair_review import (
    INTENT_SCHEMA, PROPOSAL_SCHEMA, ReleasedPairingRepairReviewError,
    decode_repair_review_intent, prepare_repair_review,
    decode_repair_review_proposal,
)
from forge_platform.installer_product_worker import execute_repair_review_intent, run
from forge_platform.managed_product_operation_dispatch import ManagedProductOperationDispatcher
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService, ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from tests.installer.test_managed_product_removal_admission import (
    ManagedProductRemovalAdmissionTests,
)
from tests.installer.test_released_pairing_repair_selection import (
    ReleasedRepairSelectionTests,
)
from tests.installer.test_managed_product_operation_dispatch import coordinator, route
from tests.installer.test_managed_product_operation_service import RouteResolver


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode()


class ReleasedRepairReviewTests(unittest.TestCase):
    def setUp(self):
        self.fixture = ManagedProductRemovalAdmissionTests(
            "test_exact_paired_component_removal_retains_ep_and_other_deployment"
        )
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        selection = ReleasedRepairSelectionTests("test_exact_read_only_selection_is_deterministic_and_secret_free")
        selection.setUp()
        self.addCleanup(selection.temporary.cleanup)
        _, self.route = selection.target("a", "deployment-a")

    def intent(self, **changes):
        payload = {
            "schema": INTENT_SCHEMA,
            "operation_id": "repair-a",
            "deployment_id": "deployment-a",
            "forge_instance_id": "forge-a",
            "engineering_platform_instance_id": "ep-a",
            "installed_composition_identity": self.fixture.manifest.composition_id,
            "installed_manifest_sha256": self.fixture.manifest.manifest_digest,
            "installer_release": asdict(self.fixture.release),
        }
        payload.update(changes)
        payload["intent_fingerprint"] = sha256(canonical(payload)).hexdigest()
        return canonical(payload)

    def prepare(self, raw):
        return prepare_repair_review(
            raw, registry=self.fixture.registry,
            installed_manifest=self.fixture.manifest,
            current_installer_release=self.fixture.release,
            routes={"deployment-a": self.route},
        )

    def test_exact_proposal_is_read_only_and_secret_free(self):
        before = self.fixture.registry.load("deployment-a")
        sibling = self.fixture.registry.load("deployment-b")
        first = self.prepare(self.intent())
        self.assertEqual(first, self.prepare(self.intent()))
        result = json.loads(first)
        self.assertEqual(result["schema"], PROPOSAL_SCHEMA)
        self.assertEqual(result["reviewed_revision"], 1)
        self.assertTrue(result["confirmation_required"])
        self.assertEqual([(x["component"], x["action"]) for x in result["component_diffs"]],
                         [("engineering-platform-server", "NO_CHANGE"), ("forge-runtime", "REPAIR")])
        self.assertNotIn(b"keychain", first)
        self.assertNotIn(str(self.route.forge_target.data_root).encode(), first)
        self.assertEqual(self.fixture.registry.load("deployment-a"), before)
        self.assertEqual(self.fixture.registry.load("deployment-b"), sibling)
        self.assertEqual(decode_repair_review_proposal(
            first, intent=decode_repair_review_intent(self.intent()),
        ), result)

    def test_malformed_or_stale_intent_fails_closed(self):
        valid = self.intent()
        for raw in (valid + b" ", valid.replace(b'"repair-a"', b'"repair-b"'),
                    self.intent(deployment_id="deployment-b"),
                    self.intent(forge_instance_id="forge-b"),
                    self.intent(installed_manifest_sha256="sha256:" + "0" * 64),
                    self.intent(operation_id="bad id")):
            with self.subTest(raw=raw[:80]), self.assertRaises(ReleasedPairingRepairReviewError):
                self.prepare(raw)
        with self.assertRaises(ReleasedPairingRepairReviewError):
            decode_repair_review_intent(valid.replace(b'"operation_id":', b'"operation_id":"x","operation_id":'))

    def test_missing_or_changed_sealed_route_fails_closed(self):
        with self.assertRaises(ReleasedPairingRepairReviewError):
            prepare_repair_review(
                self.intent(), registry=self.fixture.registry,
                installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
                routes={},
            )
        changed = replace(self.route, deployment_id="deployment-b")
        with self.assertRaises(ReleasedPairingRepairReviewError):
            prepare_repair_review(
                self.intent(), registry=self.fixture.registry,
                installed_manifest=self.fixture.manifest,
                current_installer_release=self.fixture.release,
                routes={"deployment-a": changed},
            )

    def test_closed_service_uses_same_registry_and_pinned_manifest(self):
        resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=self.fixture.release,
            manifests=(self.fixture.manifest,),
        )
        dispatcher = ManagedProductOperationDispatcher(
            coordinator=coordinator(self.fixture.root, self.fixture.registry),
            resolver=RouteResolver(route()),
        )
        service = ManagedProductOperationHelperService(
            authority_resolver=resolver, dispatcher=dispatcher,
            repair_route_configurations={"deployment-a": self.route},
        )
        self.assertEqual(json.loads(service.prepare_repair_review(self.intent()))["schema"],
                         PROPOSAL_SCHEMA)
        with self.assertRaises(ManagedProductOperationServiceError):
            service.prepare_repair_review(
                self.intent(installed_manifest_sha256="sha256:" + "0" * 64)
            )
        raw = execute_repair_review_intent(self.intent(), service_loader=lambda: service)
        self.assertEqual(json.loads(raw)["schema"], PROPOSAL_SCHEMA)
        output = BytesIO()
        self.assertEqual(run(BytesIO(self.intent()), output, service_loader=lambda: service), 0)
        self.assertEqual(output.getvalue(), raw)

    def test_worker_rejects_substituted_proposal(self):
        original = json.loads(self.prepare(self.intent()))
        for change in (
            {"operation_id": "repair-b"},
            {"confirmation_required": False},
            {"component_diffs": []},
            {"reviewed_plan_fingerprint": "sha256:invalid"},
        ):
            with self.subTest(change=change), self.assertRaises(ReleasedPairingRepairReviewError):
                decode_repair_review_proposal(
                    canonical(original | change),
                    intent=decode_repair_review_intent(self.intent()),
                )


if __name__ == "__main__":
    unittest.main()
