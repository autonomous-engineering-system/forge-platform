from __future__ import annotations

from dataclasses import asdict, replace
from hashlib import sha256
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from forge_platform.ep_consumer_revocation import EPConsumerScope
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedDeploymentPlanner,
    ManagedPeerBinding,
)
from forge_platform.managed_ep_credential_issuance import ManagedEPCredentialIssuanceCoordinator
from forge_platform.managed_pairing_repair_credential import (
    ManagedPairingRepairCredentialCoordinator, ManagedPairingRepairCredentialError,
)
from forge_platform.managed_pairing_revocation import ManagedPairingRepairRevocationCoordinator


def digest(value):
    return "sha256:" + sha256(json.dumps(
        asdict(value), sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode()).hexdigest()


class RepairCredentialTests(unittest.TestCase):
    def setUp(self):
        self.current = ManagedDeployment(
            "deployment-a", 1, "Paired A", (
                ManagedComponentBinding("forge-runtime", "forge-a", "receipt:forge"),
                ManagedComponentBinding("engineering-platform-server", "ep-a", "receipt:ep"),
            ), ManagedPeerBinding("forge-a", "ep-a", "receipt:old"),
        )
        self.desired = replace(
            self.current, revision=2,
            peer_binding=ManagedPeerBinding("forge-a", "ep-a", "receipt:new"),
        )
        self.plan = ManagedDeploymentPlanner.plan(
            self.current, self.desired,
            product_actions={"forge-runtime": "REPAIR", "engineering-platform-server": "NO_CHANGE"},
        )
        self.old_scope = EPConsumerScope("consumer-old", "project-a")
        self.new_scope = EPConsumerScope("consumer-new", "project-a")
        self.reference = "keychain://forge.ep/deployment-a-new"
        self.registry = object()
        self.guard = object()
        self.revocation = Mock(spec=ManagedPairingRepairRevocationCoordinator)
        self.revocation.registry = self.registry
        self.revocation.currency_guard = self.guard
        self.revocation.operations_root = Path("/private/tmp/revoke")
        self.revocation.scope_claims = {"deployment-a": self.old_scope}
        self.issuance = Mock(spec=ManagedEPCredentialIssuanceCoordinator)
        self.issuance.registry = self.registry
        self.issuance.currency_guard = self.guard
        self.issuance.operations_root = Path("/private/tmp/issue")
        self.issuance.scope_claims = {"deployment-a": self.new_scope}
        self.issuance.reference_claims = {"deployment-a": self.reference}
        self.issuance.registration = SimpleNamespace(
            old=SimpleNamespace(scope=self.old_scope),
            new=SimpleNamespace(
                scope=self.new_scope,
                provisioner=SimpleNamespace(target=SimpleNamespace(instance_id="ep-a")),
            ),
        )
        self.revoker = SimpleNamespace(scope=self.old_scope)
        self.binding = SimpleNamespace(consumer_id="consumer-old")
        self.terminal = SimpleNamespace(
            state="COMPLETE", receipt_reference="ep-consumer-revoke:sha256:" + "a" * 64,
            operation_id="repair-a", deployment_id="deployment-a",
            plan_fingerprint=digest(self.plan), reviewed_fingerprint=digest(self.current),
            forge_instance_id="forge-a", ep_instance_id="ep-a",
            consumer_id="consumer-old", project_id="project-a",
        )
        self.revocation.repair_revoke.return_value = self.terminal
        self.issuance.issue.return_value = SimpleNamespace(state="COMPLETE")
        self.coordinator = ManagedPairingRepairCredentialCoordinator(
            revocation=self.revocation, issuance=self.issuance,
        )

    def run_issue(self, **changes):
        arguments = dict(
            operation_id="repair-a", plan=self.plan, reviewed_current=self.current,
            revoker=self.revoker, detach_coordinator=object(), forge_adapter=object(),
            old_binding=self.binding, credential_reference=self.reference,
        )
        return self.coordinator.issue_after_revoke(**(arguments | changes))

    def test_exact_terminal_revocation_precedes_new_issue(self):
        result = self.run_issue()
        self.assertEqual(result.state, "COMPLETE")
        self.revocation.repair_revoke.assert_called_once()
        self.issuance.issue.assert_called_once_with(
            operation_id="repair-a", reviewed_current=self.current,
            reviewed_fingerprint=digest(self.current),
            credential_reference=self.reference,
        )
        self.assertEqual(self.run_issue(), result)
        self.assertEqual(self.issuance.issue.call_count, 2)

    def test_authority_must_be_shared_and_journals_distinct(self):
        for attr, value in (
            ("registry", object()), ("currency_guard", object()),
            ("operations_root", self.revocation.operations_root),
        ):
            with self.subTest(attr=attr):
                original = getattr(self.issuance, attr)
                setattr(self.issuance, attr, value)
                with self.assertRaises(TypeError):
                    ManagedPairingRepairCredentialCoordinator(
                        revocation=self.revocation, issuance=self.issuance,
                    )
                setattr(self.issuance, attr, original)

    def test_wrong_review_or_cross_deployment_claim_blocks_all_mutation(self):
        wrong = replace(self.current, deployment_id="deployment-b")
        for change in (
            {"reviewed_current": wrong},
            {"credential_reference": "keychain://forge.ep/other"},
            {"old_binding": SimpleNamespace(consumer_id="other")},
            {"revoker": SimpleNamespace(scope=self.new_scope)},
        ):
            with self.subTest(change=change), self.assertRaises(ManagedPairingRepairCredentialError):
                self.run_issue(**change)
        self.revocation.repair_revoke.assert_not_called()
        self.issuance.issue.assert_not_called()

    def test_changed_new_scope_or_instance_blocks_before_revocation(self):
        self.issuance.scope_claims["deployment-a"] = EPConsumerScope("other", "project-a")
        with self.assertRaises(ManagedPairingRepairCredentialError):
            self.run_issue()
        self.issuance.scope_claims["deployment-a"] = self.new_scope
        self.issuance.registration.new.provisioner.target.instance_id = "ep-b"
        with self.assertRaises(ManagedPairingRepairCredentialError):
            self.run_issue()
        self.revocation.repair_revoke.assert_not_called()

    def test_no_issue_on_missing_or_cross_target_terminal_receipt(self):
        for alteration in (
            {"state": "PREPARED"}, {"receipt_reference": None},
            {"operation_id": "other"}, {"deployment_id": "deployment-b"},
            {"plan_fingerprint": "sha256:" + "0" * 64},
            {"forge_instance_id": "forge-b"}, {"ep_instance_id": "ep-b"},
            {"consumer_id": "other"}, {"project_id": "other"},
            {"reviewed_fingerprint": "sha256:" + "0" * 64},
        ):
            with self.subTest(alteration=alteration):
                self.revocation.repair_revoke.return_value = SimpleNamespace(
                    **(vars(self.terminal) | alteration),
                )
                with self.assertRaises(ManagedPairingRepairCredentialError):
                    self.run_issue()
        self.issuance.issue.assert_not_called()

    def test_product_revoke_failure_cannot_issue(self):
        self.revocation.repair_revoke.side_effect = RuntimeError("product unavailable")
        with self.assertRaisesRegex(RuntimeError, "product unavailable"):
            self.run_issue()
        self.issuance.issue.assert_not_called()


if __name__ == "__main__":
    unittest.main()
