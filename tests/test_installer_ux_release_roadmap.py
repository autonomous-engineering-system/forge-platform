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


class InstallerFeatureTestMatrixTests(unittest.TestCase):
    def setUp(self):
        self.path = ROOT / "docs/roadmap/installer-feature-test-matrix-v1.json"
        self.matrix = json.loads(self.path.read_text())

    def test_documentary_authority_and_historical_overlay_are_explicit(self):
        matrix = self.matrix
        self.assertEqual(matrix["authority"], "DOCUMENTARY")
        self.assertEqual(matrix["version_change"], "NO_BUMP")
        self.assertFalse(matrix["authorizes_execution"])
        self.assertFalse(matrix["automatically_runs_tests"])
        self.assertEqual(matrix["scope"]["products"], ["forge-runtime", "engineering-platform-server"])
        self.assertTrue(matrix["scope"]["no_project_registration_required"])
        self.assertFalse(matrix["scope"]["forge_github_provider"])
        graph = json.loads((ROOT / "docs/roadmap/installer-ux-release-v1.json").read_text())
        self.assertEqual(graph["snapshot_kind"], "HISTORICAL_BROADER_IUR_BASELINE")
        overlay = graph["current_lane1_overlay"]
        self.assertEqual(overlay["increment"], matrix["increment"])
        self.assertFalse(overlay["changes_historical_node_statuses"])
        self.assertFalse(overlay["authorizes_execution"])
        for key in ["document", "case_inventory"]:
            self.assertTrue((ROOT / overlay[key]).is_file())
        for doc in ["docs/roadmap/README.md", "docs/roadmap/INSTALLER_UX_AND_RELEASE_QUALIFICATION_V1.md",
                    "docs/architecture/MANAGED_INSTALLER_V1.md", "docs/architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md",
                    "docs/installer-first-run-acceptance.md", "docs/installer-codex-single-login-proposal.md"]:
            self.assertIn("INSTALLER_FEATURE_TEST_MATRIX_V1.md", (ROOT / doc).read_text())

    def test_all_requested_features_targets_and_interfaces_have_concrete_cases(self):
        expected = {"INSTALL", "ADD", "REMOTE", "UPGRADE", "UPGRADE_NOOP", "REPAIR", "REMOVE_KEEP",
                    "REMOVE_PURGE", "RESTORE", "REINSTALL", "PROVIDER_AUTH", "PROVIDER_REAUTH", "PROVIDER_REPAIR",
                    "PROVIDER_TOOL_UPGRADE", "PROVIDER_STATE", "PAIR_CONNECT", "PAIR_DETACH", "PAIR_REPAIR", "SELF_UPDATE", "HELPER",
                    "BOOT", "RECOVERY", "ISOLATION", "USER", "CACHE", "NEGATIVE", "GUI"}
        families = {family["id"]: family for family in self.matrix["families"]}
        self.assertEqual(set(families), expected)
        cases = self.matrix["cases"]
        self.assertEqual(len({case["id"] for case in cases}), len(cases))
        actual = {(case["family"], case["variant"], case["interface"]) for case in cases}
        required = {(family["id"], variant, surface) for family in families.values()
                    for variant in family["variants"] for surface in ["CLI", "GUI"]}
        self.assertEqual(actual, required)
        self.assertEqual(len(actual), len(cases))
        for family in families.values():
            for key in ["precondition", "procedure", "expected", "source_references"]:
                self.assertTrue(family[key], (family["id"], key))
            for source in family["source_references"]:
                self.assertTrue((ROOT / source).is_file(), source)
        for name in ["INSTALL", "RESTORE", "REINSTALL", "BOOT"]:
            self.assertEqual(set(families[name]["variants"]), {"FORGE", "EP", "BOTH"})
        for name in ["UPGRADE", "REMOVE_KEEP", "REMOVE_PURGE"]:
            self.assertEqual(set(families[name]["variants"]), {"FORGE_ONLY", "EP_ONLY", "FORGE_IN_PAIR", "EP_IN_PAIR", "BOTH"})
        self.assertEqual(set(families["ADD"]["variants"]), {"EP_TO_FORGE", "FORGE_TO_EP"})
        for name in ["PROVIDER_AUTH", "PROVIDER_REAUTH", "PROVIDER_REPAIR", "PROVIDER_TOOL_UPGRADE"]:
            self.assertEqual(set(families[name]["variants"]), {"CODEX_FORGE", "CODEX_EP", "CODEX_BOTH", "GITHUB_EP"})

    def test_live_result_evidence_and_applicability_cannot_be_confused_with_source(self):
        matrix = self.matrix
        evidence = {item["id"]: item for item in matrix["evidence_inventory"]}
        self.assertEqual(len(evidence), len(matrix["evidence_inventory"]))
        applicable = []
        for case in matrix["cases"]:
            self.assertIn(case["implementation"], matrix["status_semantics"])
            self.assertTrue(set(case["blockers"]) <= set(matrix["blockers"]))
            self.assertIn(case["public_0410_result"], {"NOT_RUN", "BLOCKED", "FAIL", "LIVE_PASS", "NOT_APPLICABLE"})
            if case["applicable"]:
                applicable.append(case)
                self.assertIsNone(case["not_applicable_reason"])
                self.assertNotEqual(case["public_0410_result"], "NOT_APPLICABLE")
                self.assertTrue(case["required_checks"])
            else:
                self.assertEqual(case["family"], "GUI")
                self.assertEqual(case["interface"], "CLI")
                self.assertTrue(case["not_applicable_reason"])
                self.assertEqual(case["public_0410_result"], "NOT_APPLICABLE")
            if case["public_0410_result"] == "NOT_RUN":
                self.assertEqual(case["result_evidence"], [])
            if case["public_0410_result"] == "LIVE_PASS":
                self.assertTrue(case["result_evidence"])
                for reference in case["result_evidence"]:
                    record = evidence[reference]
                    self.assertEqual(record["kind"], "PUBLIC_RUNTIME")
                    self.assertEqual(record["case_id"], case["id"])
                    self.assertEqual(record["interface"], case["interface"])
                    self.assertTrue(record["receipt_digest"])
                    self.assertTrue(record["independent_readback_digest"])
        if matrix["completion"]["full_matrix_currently_complete"]:
            self.assertTrue(all(case["public_0410_result"] == "LIVE_PASS" for case in applicable))
        else:
            self.assertTrue(any(case["public_0410_result"] != "LIVE_PASS" for case in applicable))
        mvp_gates = matrix["completion"]["mvp_gate_results"]
        self.assertEqual(set(mvp_gates), {"PUBLIC_CLI_INSTALL_PAIRING_READINESS", "PUBLIC_GUI_CLEAN_INSTALL_PAIRING_READINESS", "AUTHORIZED_COMPACT_141_RECEIPT"})
        expected_mvp = {"PUBLIC_CLI_INSTALL_PAIRING_READINESS": "LIVE_PASS", "PUBLIC_GUI_CLEAN_INSTALL_PAIRING_READINESS": "LIVE_PASS", "AUTHORIZED_COMPACT_141_RECEIPT": "ACCEPTED"}
        for gate, result in mvp_gates.items():
            self.assertIn(result, {"NOT_RUN", "BLOCKED", "FAIL", expected_mvp[gate]})
        if matrix["completion"]["mvp_currently_complete"]:
            self.assertEqual(mvp_gates, expected_mvp)
        else:
            self.assertNotEqual(mvp_gates, expected_mvp)
        for record in evidence.values():
            if record["visibility"] == "PRIVATE":
                self.assertIsNone(record["locator"])

    def test_current_artifact_pins_and_real_source_gaps_remain_distinct(self):
        matrix = self.matrix
        self.assertEqual(matrix["baseline"]["installer_version"], "0.4.10")
        self.assertNotEqual(matrix["baseline"]["artifact_source"], matrix["baseline"]["producer_source"])
        families = {family["id"]: family for family in matrix["families"]}
        self.assertEqual(families["PROVIDER_TOOL_UPGRADE"]["implementation"], "DEDICATED_ROUTE_NOT_CONFIRMED")
        for key in ["REMOVE_KEEP", "REMOVE_PURGE", "RESTORE"]:
            self.assertEqual(families[key]["implementation"], "BLOCKED_CURRENT_PRODUCT_CONTRACT")
        self.assertIn("FORGE_CLI_RESTORE", matrix["blockers"])
        cli = (ROOT / "macos/ForgePlatformInstaller/Sources/ForgePlatformInstallerCore/InstallerCLI.swift").read_text()
        restore = cli.split('case ["deployment", "lifecycle", "restore"]:', 1)[1].split('case ["deployment", "lifecycle", "purge"]:', 1)[0]
        self.assertIn('component == "engineering-platform-server"', restore)
        markdown = (ROOT / "docs/roadmap/INSTALLER_FEATURE_TEST_MATRIX_V1.md").read_text()
        for key in families:
            self.assertIn("`" + key + "`", markdown)
        self.assertIn("0.4.10", markdown)
        self.assertTrue(matrix["completion"]["public_cli_and_gui_proof_required"])
        self.assertTrue(matrix["completion"]["authorized_compact_141_receipt_required"])
        self.assertTrue(matrix["completion"]["unsupported_required_case_blocks_full_matrix_completion"])


if __name__ == "__main__":
    unittest.main()
