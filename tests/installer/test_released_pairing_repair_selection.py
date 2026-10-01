from __future__ import annotations

from dataclasses import asdict, replace
from pathlib import Path
import json
import tempfile
import unittest

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import EPSystemInstanceTarget
from forge_platform.forge_ep_pairing_executor import ForgeEPProductPairingBinding
from forge_platform.forge_server_adapter import ForgeServerTarget
from forge_platform.managed_deployments import (
    ManagedComponentBinding, ManagedDeployment, ManagedPeerBinding,
)
from forge_platform.released_pairing_repair_selection import (
    ReleasedPairingRepairSelection, ReleasedPairingRepairSelectionError,
)
from forge_platform.released_product_routes import ReleasedManagedProductRouteConfiguration


FORGE = QualifiedArtifact(
    "2.7.39", "ebc43dc12da27353f85c991a26da9852aa790f05",
    "released-wheel",
    "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
    "release-complete",
)
EP = QualifiedArtifact(
    "2.3.106", "7b99b578153ae5d72372a09db194306b49ec9f9c",
    "released-wheel",
    "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694",
    "release-complete",
)


class ReleasedRepairSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.current, self.route = self.target("a", "deployment-a")

    def target(self, suffix, deployment_id):
        forge_id = "forge-" + suffix
        ep_id = "ep-" + suffix
        port = 8900 if suffix == "a" else 8901
        binding = ForgeEPProductPairingBinding(
            "binding-" + suffix, f"http://127.0.0.1:{port}", ep_id,
            "consumer-" + suffix, "host-" + suffix, "project-" + suffix,
            "repo-" + suffix, "owner:repo", "keychain://forge.ep/old-" + suffix,
            "operator-" + suffix, True,
        )
        route = ReleasedManagedProductRouteConfiguration(
            deployment_id=deployment_id,
            forge_executable=self.root / "venvs/forge/bin/forge",
            forge_target=ForgeServerTarget(
                forge_id, self.root / "instances" / forge_id,
                self.root / "instances", "_forge_" + suffix, 8800,
                self.root / "credentials/forge.token",
            ),
            forge_installed_artifact=FORGE,
            engineering_platform_installed_artifact=EP,
            engineering_platform_provisioner=self.root / "venvs/ep/bin/provisioner",
            engineering_platform_product_root=self.root / "products/ep",
            engineering_platform_target=EPSystemInstanceTarget(
                ep_id, "EP " + suffix, "_ep_" + suffix, port,
            ),
            staged_artifacts={
                FORGE.digest: self.root / "staged/forge.whl",
                EP.digest: self.root / "staged/ep.whl",
            },
            pairing_binding=binding,
        )
        current = ManagedDeployment(
            deployment_id, 2, "Paired " + suffix, (
                ManagedComponentBinding("forge-runtime", forge_id, "receipt:forge"),
                ManagedComponentBinding("engineering-platform-server", ep_id, "receipt:ep"),
            ), ManagedPeerBinding(forge_id, ep_id, "receipt:old-pair"),
        )
        return current, route

    def derive(self, **changes):
        values = dict(operation_id="repair-a", reviewed_current=self.current, route=self.route)
        return ReleasedPairingRepairSelection.derive(**(values | changes))

    def test_exact_read_only_selection_is_deterministic_and_secret_free(self):
        first = self.derive()
        self.assertEqual(self.derive(), first)
        self.assertEqual(first.plan.current_revision, 2)
        self.assertEqual(first.plan.desired.revision, 3)
        self.assertEqual(first.plan.desired.components, self.current.components)
        self.assertEqual({d.component: d.action for d in first.plan.component_diffs}, {
            "forge-runtime": "REPAIR", "engineering-platform-server": "NO_CHANGE",
        })
        self.assertNotEqual(first.plan.desired.peer_binding.receipt_reference,
                            self.current.peer_binding.receipt_reference)
        self.assertNotEqual(first.old_scope.consumer_id, first.new_scope.consumer_id)
        self.assertEqual(first.old_scope.project_id, first.new_scope.project_id)
        self.assertEqual(first.new_binding.credential_reference,
                         "keychain://forge.ep/" + first.new_scope.consumer_id)
        self.assertEqual(first.new_binding.endpoint, first.old_binding.endpoint)
        raw = json.dumps(asdict(first))
        self.assertNotIn(str(self.root), raw)
        self.assertNotIn("password", raw.lower())

    def test_new_operation_and_other_deployment_get_distinct_scope(self):
        first = self.derive()
        next_operation = self.derive(operation_id="repair-a-next")
        other, other_route = self.target("b", "deployment-b")
        sibling = self.derive(
            operation_id="repair-a", reviewed_current=other, route=other_route,
        )
        for candidate in (next_operation, sibling):
            self.assertNotEqual(first.new_scope, candidate.new_scope)
            self.assertNotEqual(first.new_binding.credential_reference,
                                candidate.new_binding.credential_reference)
            self.assertNotEqual(first.reviewed_plan_fingerprint,
                                candidate.reviewed_plan_fingerprint)
        self.assertEqual(other_route.pairing_binding.consumer_id, "consumer-b")

    def test_wrong_release_route_or_review_fails_closed(self):
        for values in (
            {"operation_id": "bad id"},
            {"reviewed_current": replace(self.current, deployment_id="deployment-b")},
            {"reviewed_current": replace(
                self.current,
                components=(
                    ManagedComponentBinding("forge-runtime", "forge-b", "receipt:forge"),
                    self.current.by_component["engineering-platform-server"],
                ),
                peer_binding=ManagedPeerBinding("forge-b", "ep-a", "receipt:wrong"),
            )},
            {"route": replace(self.route, forge_installed_artifact=replace(FORGE, version="2.7.38"))},
            {"route": replace(self.route, engineering_platform_installed_artifact=replace(EP, version="2.3.105"))},
        ):
            with self.subTest(values=values), self.assertRaises(ReleasedPairingRepairSelectionError):
                self.derive(**values)


if __name__ == "__main__":
    unittest.main()
