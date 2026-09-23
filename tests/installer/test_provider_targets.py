#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import ArtifactCorrelation, ProductInstallationReadback, QualifiedArtifact
from forge_platform.universal_installer import (
    CompositionComponent,
    CompositionPlanner,
    DownloadIdentity,
    ProviderReadback,
    ProviderRequirement,
    ProviderSelection,
    PythonRuntimeQualification,
    SemanticVersion,
    SystemServiceContract,
    evaluate_provider_gate,
)


ROOT = Path(__file__).resolve().parents[2]
DIGEST = "sha256:" + "a" * 64
RUNTIME = "sha256:" + "b" * 64


def requirement(
    provider: str,
    owner: str,
    target: str,
    *,
    scope: str = "component",
) -> ProviderRequirement:
    return ProviderRequirement(
        provider,
        True,
        SemanticVersion.parse("1.0.0"),
        scope,
        owner,
        target,
    )


def readback(requirement: ProviderRequirement, *, state: str = "VERIFIED") -> ProviderReadback:
    return ProviderReadback(
        requirement.identity,
        state,
        SemanticVersion.parse("1.1.0") if state == "VERIFIED" else None,
        f"{requirement.key}-executable" if state == "VERIFIED" else None,
        f"evidence:{requirement.target_identity}",
        requirement.owner_component,
        requirement.target_identity,
    )


class ProviderTargetTests(unittest.TestCase):
    def test_same_human_provider_can_back_two_isolated_server_targets(self) -> None:
        forge = requirement("codex", "forge-runtime", "forge-prod")
        ep = requirement("codex", "engineering-platform-server", "ep-prod")
        selections = {
            forge.key: ProviderSelection("codex", True, "forge-runtime", "forge-prod"),
            ep.key: ProviderSelection("codex", True, "engineering-platform-server", "ep-prod"),
        }
        gate = evaluate_provider_gate(
            (forge, ep),
            selections,
            {forge.key: readback(forge), ep.key: readback(ep)},
        )
        self.assertEqual(gate.required, (ep.key, forge.key))
        self.assertEqual({action.key for action in gate.actions}, {forge.key, ep.key})
        self.assertTrue(gate.permits_platform_mutation)

    def test_target_verification_is_independent_even_after_one_human_login(self) -> None:
        forge = requirement("codex", "forge-runtime", "forge-prod")
        ep = requirement("codex", "engineering-platform-server", "ep-prod")
        gate = evaluate_provider_gate(
            (forge, ep),
            {
                forge.key: ProviderSelection("codex", True, "forge-runtime", "forge-prod"),
                ep.key: ProviderSelection("codex", True, "engineering-platform-server", "ep-prod"),
            },
            {forge.key: readback(forge)},
        )
        self.assertFalse(gate.permits_platform_mutation)
        self.assertEqual(gate.blocking_providers, (ep.key,))
        action = next(item for item in gate.actions if item.key == ep.key)
        self.assertEqual(action.action, "INSTALL")

    def test_server_and_project_agent_credential_scope_cannot_cross(self) -> None:
        with self.assertRaisesRegex(ValueError, "component-owned"):
            requirement("codex", "forge-runtime", "forge-prod", scope="user")
        with self.assertRaisesRegex(ValueError, "user-owned"):
            requirement(
                "codex",
                "engineering-platform-project-agent",
                "user-501-agent",
                scope="component",
            )
        agent = requirement(
            "codex",
            "engineering-platform-project-agent",
            "user-501-agent",
            scope="user",
        )
        self.assertEqual(agent.credential_scope, "user")

    def test_legacy_v1_provider_remains_user_scoped_and_targetless(self) -> None:
        legacy = ProviderRequirement("codex", True, None)
        self.assertEqual(legacy.key, "codex")
        self.assertEqual(legacy.credential_scope, "user")
        with self.assertRaisesRegex(ValueError, "user-scoped"):
            ProviderRequirement("codex", True, None, "component")

    def test_duplicate_target_binding_fails_but_duplicate_provider_identity_does_not(self) -> None:
        forge = requirement("codex", "forge-runtime", "forge-prod")
        duplicate = requirement("codex", "forge-runtime", "forge-prod")
        with self.assertRaisesRegex(ValueError, "duplicate target"):
            evaluate_provider_gate((forge, duplicate), {}, {})

    def test_v2_schema_requires_exact_owner_target_and_scope(self) -> None:
        schema = json.loads(
            (ROOT / "schemas/universal-installer-composition-v2.schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(schema["properties"]["schema"]["const"], "forge-platform.composition/v2")
        provider = schema["$defs"]["provider"]
        self.assertEqual(
            set(provider["required"]),
            {
                "identity", "required", "minimum_version", "credential_scope",
                "owner_component", "target_identity",
            },
        )
        self.assertIn("component", provider["properties"]["credential_scope"]["enum"])
        self.assertIn("user", provider["properties"]["credential_scope"]["enum"])

    def test_managed_deployment_ep_selection_does_not_require_singleton_claim(self) -> None:
        artifact = QualifiedArtifact(
            "2.3.102",
            "c" * 40,
            "https://registry.example.invalid/engineering-platform-2.3.102.whl",
            DIGEST,
            "https://evidence.example.invalid/ep-2.3.102",
        )
        evidence = DownloadIdentity(
            "https://evidence.example.invalid/python.json",
            "sha256:" + "d" * 64,
        )
        component = CompositionComponent(
            "engineering-platform-server",
            "server",
            artifact,
            PythonRuntimeQualification(RUNTIME, evidence, evidence),
            SystemServiceContract("launchd", "system", "LaunchDaemon", "ep-system-v1"),
        )
        observation = ProductInstallationReadback(
            "engineering-platform-server",
            "ep-prod",
            "ACTIVE",
            "ep-runtime",
            "ep-executable",
            "ep-server",
            "ep-instance-prod",
            artifact.correlation,
            "HEALTHY",
            "PARTIAL",
            "NONE",
            "evidence:inventory",
            "evidence:health",
        )
        legacy = CompositionPlanner._selected_diff(component, observation, {})
        managed = CompositionPlanner._selected_diff(
            component, observation, {}, managed_deployment_scope=True
        )
        self.assertEqual(legacy.action, "BLOCKED")
        self.assertEqual(managed.action, "NO_CHANGE")


if __name__ == "__main__":
    unittest.main()
