#!/usr/bin/env python3
"""Offline checks for the repository foundation; no installer behavior is tested."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

REQUIRED = (
    "README.md",
    "BOOTSTRAP.md",
    "HANDOFF.md",
    "SECURITY.md",
    ".github/workflows/foundation-validation.yml",
    "docs/architecture/README.md",
    "docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md",
    "docs/architecture/KNOWLEDGE_LEARNING_LOOP.md",
    "docs/architecture/OWNERSHIP_MATRIX.md",
    "docs/architecture/adr/README.md",
    "docs/architecture/adr/ADR-0001-first-class-product-boundaries.md",
    "docs/architecture/adr/ADR-0002-project-repository-host-agent-model.md",
    "docs/architecture/adr/ADR-0003-deployment-and-trust-boundaries.md",
    "docs/architecture/adr/ADR-0004-universal-installer-artifact-composition.md",
    "docs/architecture/adr/ADR-0005-governed-engineering-learning-loop.md",
    "docs/architecture/COMPONENT_MANIFEST_CONTRACT.md",
    "docs/architecture/COMPONENT_OPERATION_DELEGATION_CONTRACT.md",
    "docs/architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md",
    "docs/architecture/MANAGED_PYTHON_RUNTIME_EXECUTION_CONTRACT.md",
    "docs/architecture/COMPATIBILITY.md",
    "docs/architecture/ROLES_AND_PRESETS.md",
    "docs/roadmap/README.md",
    "docs/roadmap/MVP_1_0.md",
    "docs/roadmap/MIGRATION_REGISTER.md",
    "docs/development/AI_DEVELOPMENT_PROFILE_STATUS.md",
    "docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md",
    "docs/development/TDE_INTEGRATION.md",
    "docs/ai-development/GENERATED_PROJECTION.md",
    "docs/ai-development/projection-manifest.json",
    "docs/ai-development/validate_projection.py",
    "docs/governance/FAMILY_MIGRATION_HANDOFF.md",
    "docs/governance/AI_DEVELOPMENT_CONTRACT_SEMANTIC_EQUIVALENCE_RECEIPT.md",
    "scripts/validate.sh",
    "provenance/FOUNDATION_RECEIPT.md",
    "schemas/component-manifest.schema.json",
    "schemas/universal-installer-release.schema.json",
    "schemas/universal-installer-release-provenance.schema.json",
    "schemas/universal-installer-composition-catalog.schema.json",
    "schemas/universal-installer-composition-catalog-trust.schema.json",
    "schemas/universal-installer-composition.schema.json",
    "macos/ForgePlatformInstaller/Package.swift",
    "macos/ForgePlatformInstaller/Sources/ForgePlatformInstaller/ForgePlatformInstallerApp.swift",
    "macos/ForgePlatformInstaller/Sources/ForgePlatformInstallerCore/InstallerDomain.swift",
    "macos/ForgePlatformInstaller/Tests/ForgePlatformInstallerCoreTests/InstallerDomainTests.swift",
    ".github/workflows/macos-installer-validation.yml",
    ".github/workflows/forge-platform-installer-release.yml",
    "installer-version.json",
    "installer-release-identity.json",
    "scripts/validate_installer_version.py",
    "scripts/validate_installer_release_identity.py",
    "scripts/advance_installer_version.py",
    "tests/installer/test_installer_version_preparation.py",
    "scripts/package_macos_installer_app.py",
    "scripts/verify_installer_release_evidence.py",
    "forge_platform/macos_platform_contract.py",
    "forge_platform/managed_python_runtime_executor.py",
    "forge_platform/installer_release_operation.py",
    "tests/installer/test_installer_release_operation.py",
    "tests/installer/test_installer_release_identity.py",
    "tests/installer/test_package_macos_installer_app.py",
    "tests/installer/test_verify_installer_release_evidence.py",
    "tests/installer/test_managed_python_runtime_executor.py",
    "tests/installer/test_installer_release_workflow.py",
    "macos/ForgePlatformInstaller/Sources/ForgePlatformInstallerCore/MacOSInstallerExecutableArchitecture.swift",
    "macos/ForgePlatformInstaller/Tests/ForgePlatformInstallerCoreTests/MacOSInstallerExecutableArchitectureTests.swift",
)


def main() -> None:
    missing = [path for path in REQUIRED if not (ROOT / path).is_file()]
    if missing:
        raise SystemExit(f"missing foundation files: {', '.join(missing)}")

    schema = json.loads((ROOT / "schemas/component-manifest.schema.json").read_text())
    if schema["title"] != "Forge Platform component manifest":
        raise SystemExit("component-manifest schema identity is invalid")
    identities = schema["$defs"]["component"]["properties"]["identity"]["enum"]
    if len(identities) != 5:
        raise SystemExit("component-manifest schema must identify five installable components")
    installer_release = json.loads((ROOT / "schemas/universal-installer-release.schema.json").read_text())
    if installer_release["title"] != "Forge Platform universal installer release descriptor":
        raise SystemExit("universal installer release schema identity is invalid")
    if "policy_revision" not in installer_release["properties"]["installer"]["required"]:
        raise SystemExit("universal installer release descriptor must bind its policy revision")
    for field in ("github_release",):
        if field not in installer_release["required"]:
            raise SystemExit("universal installer release descriptor must bind canonical GitHub release identity")
    for field in ("release_trust_configuration_sha256", "provenance_sha256"):
        if field not in installer_release["properties"]["installer"]["required"]:
            raise SystemExit("universal installer release descriptor must bind sealed trust and provenance identity")
    installer_asset = installer_release["$defs"]["installer_asset"]
    for field in ("asset_name", "code_directory_sha256", "notarization_receipt_reference"):
        if field not in installer_asset["required"]:
            raise SystemExit("universal installer release asset must bind GitHub name and signed archive identity")
    release_assets = installer_release["properties"]["installer"]["properties"]["assets"]
    if release_assets.get("minItems") != 1 or release_assets.get("maxItems") != 1:
        raise SystemExit("universal installer release must contain exactly one platform asset")
    if installer_asset["properties"]["architecture"] != {"const": "arm64"}:
        raise SystemExit("universal installer release architecture must be arm64 only")
    if installer_asset["properties"]["minimum_macos_version"] != {"const": "26.0.0"}:
        raise SystemExit("universal installer release asset must declare the exact macOS 26 floor")
    release_signature = installer_release["$defs"]["public_signature_envelope"]
    if release_signature["required"] != ["algorithm", "key_id", "signature"]:
        raise SystemExit("universal installer release descriptor must use a strict public signature envelope")
    provenance = json.loads((ROOT / "schemas/universal-installer-release-provenance.schema.json").read_text())
    if provenance["title"] != "Forge Platform installer release provenance":
        raise SystemExit("universal installer provenance schema identity is invalid")
    if provenance["required"] != [
        "schema_version", "provenance_sha256", "installer_version", "channel", "release_sequence",
        "source_revision", "policy_revision", "capabilities", "release_trust_configuration_sha256",
    ]:
        raise SystemExit("universal installer provenance schema must retain its strict public fields")
    catalog = json.loads((ROOT / "schemas/universal-installer-composition-catalog.schema.json").read_text())
    if catalog["title"] != "Forge Platform universal installer composition catalog":
        raise SystemExit("universal installer catalog schema identity is invalid")
    catalog_signature = catalog["$defs"]["public_signature_envelope"]
    if catalog_signature["required"] != ["algorithm", "key_id", "signature"]:
        raise SystemExit("universal installer catalog must use a strict public signature envelope")
    catalog_trust = json.loads((ROOT / "schemas/universal-installer-composition-catalog-trust.schema.json").read_text())
    if catalog_trust["title"] != "Forge Platform installer composition catalog trust":
        raise SystemExit("universal installer catalog trust schema identity is invalid")
    if catalog_trust["required"] != [
        "schema_version", "configuration_sha256", "installer_release_trust_configuration_sha256",
        "signature_threshold", "ed25519_public_keys",
    ]:
        raise SystemExit("universal installer catalog trust schema must retain its strict public fields")
    installer_composition = json.loads((ROOT / "schemas/universal-installer-composition.schema.json").read_text())
    if installer_composition["title"] != "Forge Platform universal installer composition":
        raise SystemExit("universal installer composition schema identity is invalid")
    host_requirement = installer_composition["$defs"]["host_requirement"]["properties"]
    if host_requirement["supported_architectures"] != {"const": ["arm64"]}:
        raise SystemExit("universal installer composition architecture must be arm64 only")
    if "2[6-9]" not in host_requirement["minimum_macos_version"].get("pattern", ""):
        raise SystemExit("universal installer composition must require macOS 26 or newer")
    python_runtime = installer_composition["$defs"]["managed_python_runtime"]["properties"]
    if python_runtime["architecture"] != {"const": "arm64"}:
        raise SystemExit("managed Python runtime artifact must be arm64 only")
    if python_runtime["managed_root_identity"] != {"const": "forge-platform-managed-python-v1"}:
        raise SystemExit("managed Python runtime must remain installer-owned")
    if installer_composition["$defs"]["managed_tool"]["properties"]["identity"] != {"const": "git"}:
        raise SystemExit("Python must not regress to generic managed-tool or PATH selection")
    installer_catalog = json.loads(
        (ROOT / "schemas/universal-installer-composition-catalog.schema.json").read_text()
    )
    if "approved_python_runtime_identity" not in installer_catalog["required"]:
        raise SystemExit("signed composition catalog must approve one exact Python runtime")
    package_manifest = (ROOT / "macos/ForgePlatformInstaller/Package.swift").read_text()
    if 'platforms: [.macOS("26.0")]' not in package_manifest:
        raise SystemExit("native installer package must target macOS 26")
    installer_version = json.loads((ROOT / "installer-version.json").read_text())
    if installer_version.get("product") != "forge-platform-installer":
        raise SystemExit("installer version authority is invalid")
    required_installer_capabilities = {
        "composition/v1",
        "composition/v2",
        "managed-deployment/v1",
        "managed-python-runtime/v1",
        "provider-fanout/v1",
        "provider-gate/v1",
        "provider-targets/v1",
        "system-launchdaemon/v1",
    }
    if not required_installer_capabilities.issubset(set(installer_version.get("capabilities", []))):
        raise SystemExit("installer version authority omits managed-installer capabilities")
    canonical_versioning = (ROOT / ".github/workflows/canonical-versioning.yml").read_text()
    for required_command in (
        "scripts/validate_installer_version.py",
        "scripts/advance_installer_version.py --check",
        "scripts/advance_installer_version.py --verify-operation",
    ):
        if required_command not in canonical_versioning:
            raise SystemExit(f"canonical versioning omits installer authority validation: {required_command}")

    extension = (ROOT / "docs/development/FORGE_PLATFORM_DEVELOPMENT_EXTENSION.md").read_text()
    if "generic branch" not in extension:
        raise SystemExit("local extension must preserve the generic-contract boundary")
    architecture = (ROOT / "docs/architecture/FORGE_PLATFORM_ARCHITECTURE.md").read_text()
    for required_term in (
        "Canonical Project Authority Repository",
        "Engineering Platform Project Agent",
        "at most one mutating Execution Lane per Repository at a time",
        "source checkouts develop, test, and build; published/installed artifacts run",
    ):
        if required_term not in architecture:
            raise SystemExit(f"architecture is missing canonical term: {required_term}")
    for required_term in (
        "EP-owned provisioner",
        "never selects an EP runtime through `PATH`",
        "parallel EP operational environment",
    ):
        if required_term not in architecture:
            raise SystemExit(f"architecture is missing EP installation boundary: {required_term}")
    universal_installer = (ROOT / "docs/architecture/UNIVERSAL_MACOS_INSTALLER_CONTRACT.md").read_text()
    for required_term in (
        "One installer can consume many immutable compositions",
        "Mandatory self-update",
        "system-domain `LaunchDaemon`",
        "Codex CLI and GitHub CLI",
        "SINGLE_OPERATIONAL_INSTALLATION_VERIFIED",
        "EP-owned resolver/provisioner",
        "Forge Platform must not add a second EP provisioner",
        "installer-release identity policy",
        "structured public signature envelopes",
        "ForgePlatformInstallerReleaseProvenance.json",
    ):
        if required_term not in universal_installer:
            raise SystemExit(f"universal installer contract is missing canonical term: {required_term}")
    learning_loop = (ROOT / "docs/architecture/KNOWLEDGE_LEARNING_LOOP.md").read_text()
    for required_term in (
        "KB CURRENTLY CLI/REPOSITORY CAPABILITY",
        "no system becomes authoritative merely because it produced evidence about itself",
        "Knowledge integration is additive",
    ):
        if required_term not in learning_loop:
            raise SystemExit(f"learning-loop architecture is missing canonical term: {required_term}")
    roadmap = (ROOT / "docs/roadmap/MVP_1_0.md").read_text()
    for required_term in (
        "Forge Platform MVP 1.0",
        "MVP 1.0 release gate",
        "Production action for this roadmap consolidation is **NONE**",
        "MULTI_PROJECT_CONSOLE_QUALIFIED",
        "EP_EXTRACTION_CUTOVER_COMPLETE",
        "EP_SELF_HOSTING_QUALIFIED",
        "MVP_1_0_RELEASE_READY",
        "B8C_PASS",
        "B8D_PASS",
        "CANONICAL_SUBMISSION_INGRESS_READY",
        "zero-live-duplicate audit",
    ):
        if required_term not in roadmap:
            raise SystemExit(f"MVP roadmap is missing required term: {required_term}")
    manifest = json.loads((ROOT / "docs/ai-development/projection-manifest.json").read_text())
    if manifest["profile"] != "forge-platform":
        raise SystemExit("projection profile is invalid")
    if manifest["extension_identity"] != "FORGE_PLATFORM_DEVELOPMENT_EXTENSION":
        raise SystemExit("projection extension identity is invalid")
    if len(manifest["contracts"]) != 8:
        raise SystemExit("projection must contain all eight generic contracts")
    print("Foundation validation: PASS")


if __name__ == "__main__":
    main()
