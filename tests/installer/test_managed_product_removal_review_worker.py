#!/usr/bin/env python3
from __future__ import annotations

import io
import json
from types import SimpleNamespace
import unittest

from forge_platform.installer_product_worker import (
    InstallerProductWorkerUnavailable,
    execute_removal_review_intent,
    run,
)
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService,
    ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from forge_platform.managed_product_removal_dispatch import ManagedProductRemovalDispatcher
import tests.installer.test_managed_product_removal_proposal as proposal_fixtures


class ManagedProductRemovalReviewWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = proposal_fixtures.ManagedProductRemovalProposalTests(
            "test_paired_forge_component_review_is_read_only_and_exact"
        )
        self.fixture.setUp()
        product = self.fixture.fixture
        service = object.__new__(ManagedProductOperationHelperService)
        service.authority_resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=product.release,
            manifests=(product.manifest,),
            installed_manifests=(product.manifest,),
        )
        removal = object.__new__(ManagedProductRemovalDispatcher)
        removal.coordinator = SimpleNamespace(registry=product.registry)
        service.removal_dispatcher = removal
        self.service = service

    def tearDown(self) -> None:
        self.fixture.tearDown()

    def test_released_service_and_worker_return_one_read_only_review(self) -> None:
        intent = proposal_fixtures.canonical(self.fixture.intent())
        expected = self.fixture.prepare(json.loads(intent))

        response = self.service.prepare_removal_review(intent)
        worker = execute_removal_review_intent(intent, service_loader=lambda: self.service)
        output = io.BytesIO()
        status = run(io.BytesIO(intent), output, service_loader=lambda: self.service)

        self.assertEqual(response, expected)
        self.assertEqual(worker, expected)
        self.assertEqual(status, 0)
        self.assertEqual(output.getvalue(), expected)
        self.assertEqual(
            self.fixture.fixture.registry.load("deployment-a"), self.fixture.fixture.paired,
        )
        self.assertEqual(
            self.fixture.fixture.registry.load("deployment-b"), self.fixture.fixture.other,
        )
        self.assertNotIn(b"receipt:forge-a", worker)

    def test_service_and_worker_reject_wrong_target_or_substituted_proposal(self) -> None:
        intent = proposal_fixtures.canonical(self.fixture.intent())
        valid = json.loads(self.service.prepare_removal_review(intent))
        changed_intent = proposal_fixtures.canonical(
            self.fixture.intent(forge_instance_id="forge-other")
        )
        with self.assertRaises(ManagedProductOperationServiceError):
            self.service.prepare_removal_review(changed_intent)
        for changed in (
            {"intent_fingerprint": "0" * 64},
            {"component_diffs": []},
            {"secret": "private"},
        ):
            with self.subTest(changed=changed), self.assertRaises(
                InstallerProductWorkerUnavailable
            ):
                fake = object.__new__(ManagedProductOperationHelperService)
                fake.prepare_removal_review = lambda _request, changed=changed: (
                    proposal_fixtures.canonical({**valid, **changed})
                )
                execute_removal_review_intent(intent, service_loader=lambda: fake)
        self.assertEqual(
            run(io.BytesIO(changed_intent), io.BytesIO(), service_loader=lambda: self.service),
            1,
        )
        with self.assertRaises(InstallerProductWorkerUnavailable):
            execute_removal_review_intent(intent, service_loader=lambda: object())


if __name__ == "__main__":
    unittest.main()
