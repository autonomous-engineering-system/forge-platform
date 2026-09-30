"""Documentary integrity only; not native UI, coverage or release proof."""
from decimal import Decimal
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerUXReleaseRoadmapTests(unittest.TestCase):
    def setUp(self):
        self.graph = json.loads((ROOT / "docs/roadmap/installer-ux-release-v1.json").read_text())

    def test_scope_preserves_parked_clean_install(self):
        self.assertEqual(self.graph["authority"], "DOCUMENTARY")
        self.assertEqual(self.graph["version_change"], "NO_BUMP")
        self.assertTrue(self.graph["narrow_clean_install_scope_unchanged"])
        for key in ("executable", "authorizes_execution", "first_canary_prerequisite"):
            self.assertFalse(self.graph[key])

    def test_dag_is_resolvable_and_acyclic(self):
        seen = set()
        for node in self.graph["nodes"]:
            self.assertNotIn(node["id"], seen)
            self.assertTrue(set(node["depends_on"]) <= seen)
            self.assertIn(node["status"], {"PLANNED", "DESIGNED", "QUALIFIED"})
            if node["status"] == "QUALIFIED":
                self.assertTrue(node["qualification_evidence"])
            else:
                self.assertEqual(node["qualification_evidence"], [])
            seen.add(node["id"])
        self.assertEqual(len(seen), 22)
        self.assertTrue(set(self.graph["external_evidence_gates"]) <= seen)
        self.assertFalse(seen & set(self.graph["parent_lanes"]))

    def test_lifecycle_producer_evidence_and_consumer_status_are_separate(self):
        baselines = self.graph["lifecycle_producer_baselines"]
        self.assertEqual(baselines["forge"]["version"], "2.7.38")
        self.assertEqual(baselines["forge"]["source_revision"],
                         "0a3d6e35b01da93bb5a674ae7795558655c16c7d")
        self.assertEqual(baselines["forge"]["wheel_sha256"],
                         "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8")
        self.assertEqual(baselines["forge"]["contract"],
                         "forge-server-instance-lifecycle/v1")
        self.assertEqual(baselines["engineering-platform"]["version"], "2.3.106")
        self.assertEqual(baselines["engineering-platform"]["wheel_sha256"],
                         "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694")
        self.assertEqual(baselines["engineering-platform"]["contract"],
                         "engineering-platform.system-instance-lifecycle/v1")
        self.assertTrue(all(item["status"] == "QUALIFIED" for item in baselines.values()))

        nodes = {node["id"]: node for node in self.graph["nodes"]}
        qualified = {
            "IUR-LC-FORGE-CONTRACT", "IUR-LC-FORGE-RELEASE",
            "IUR-LC-EP-CONTRACT", "IUR-LC-EP-RELEASE",
            "IUR-LC-PRODUCER-REBASELINE",
        }
        designed = {
            "IUR-LC-PRESERVED-INVENTORY",
            "IUR-LC-RESTORE-PLAN", "IUR-LC-PURGE-PLAN",
        }
        self.assertTrue(all(nodes[node_id]["status"] == "QUALIFIED" for node_id in qualified))
        self.assertTrue(all(nodes[node_id]["status"] == "DESIGNED" for node_id in designed))
        self.assertEqual(nodes["IUR-LC-HELPER-PRODUCT-ADAPTERS"]["status"], "PLANNED")
        self.assertEqual(nodes["IUR-LC-FRESH-MAC-ACCEPTANCE"]["status"], "PLANNED")
        self.assertEqual(nodes["IUR-LC-TERMINAL-HANDOFF"]["status"], "PLANNED")

    def test_lifecycle_safety_invariants(self):
        lifecycle = self.graph["lifecycle"]
        self.assertEqual(lifecycle["states"], [
            "INSTALLED", "UNINSTALLED_DATA_PRESERVED", "PURGED_OR_ABSENT",
        ])
        self.assertEqual(lifecycle["operations"], ["PRESERVE", "PURGE", "RESTORE"])
        self.assertEqual(lifecycle["safe_remove_default"], "PRESERVE")
        self.assertEqual(lifecycle["identity_after_restore"],
                         "SAME_OPAQUE_PRODUCT_INSTANCE_ID")
        rules = self.graph["invariants"]
        for key in ("preserve_falls_back_to_purge", "preserved_auth_is_verified",
                    "preserved_instance_is_absent", "legacy_remove_receipt_is_preserve_evidence",
                    "purge_mutates_unrelated_deployments"):
            self.assertFalse(rules[key])

    def test_presets_preserve_five_existing_roles(self):
        profiles = self.graph["profiles"]
        self.assertEqual(profiles["Server install"],
                         ["EP Server", "Forge Server", "Workspace Server"])
        self.assertEqual(profiles["Client install"],
                         ["Workspace Client", "EP Project Agent"])
        roles = profiles["Server install"] + profiles["Client install"]
        self.assertEqual(len(roles), len(set(roles)))
        self.assertTrue(self.graph["ep_client_is_project_agent_ux_label"])

    def test_strict_per_file_threshold_not_rounded(self):
        coverage = self.graph["coverage"]
        self.assertEqual(coverage["operator"], ">")
        self.assertEqual(Decimal(coverage["percent"]), Decimal("80.2"))
        self.assertEqual(coverage["scope"], "per_production_source_file")
        self.assertEqual(coverage["metric"], "executable_line")
        self.assertEqual(coverage["missing_evidence"], "FAIL")
        self.assertFalse(coverage["rounding_for_pass"])

    def test_ui_and_signer_boundaries(self):
        self.assertEqual(self.graph["locales"], ["en", "nl", "de", "fr", "es"])
        self.assertEqual(self.graph["backing_scales"], [1, 2])
        self.assertEqual(self.graph["installer_distribution"], "GITHUB_RELEASES")
        rules = self.graph["invariants"]
        self.assertTrue(rules["screenshots_are_real_app_captures"])
        for key in ("separate_mock_wizard", "readonly_product_mutation", "readonly_self_update",
                    "readonly_is_real_install_proof", "untrusted_pr_on_signer",
                    "gui_signing_implies_runner_ready", "selection_is_uninstall_authority",
                    "server_install_requires_user_login"):
            self.assertFalse(rules[key])

    def test_complete_scenario_inventory_and_roadmap_link(self):
        scenarios = self.graph["required_scenarios"]
        self.assertEqual([s["id"] for s in scenarios], [f"IUR-T{i:02d}" for i in range(1, 21)])
        self.assertTrue(all(s["status"] == "PLANNED" and s["requirement"] for s in scenarios))
        self.assertTrue((ROOT / self.graph["roadmap"]).is_file())
        parent = (ROOT / "docs/roadmap/README.md").read_text()
        self.assertIn(Path(self.graph["roadmap"]).name, parent)
        self.assertIn("installer-ux-release-v1.json", parent)


if __name__ == "__main__":
    unittest.main()
