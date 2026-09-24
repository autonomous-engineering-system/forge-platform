#!/usr/bin/env python3
"""Behavioral checks for the fail-closed universal-installer policy kernel."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from dataclasses import replace
from hashlib import sha256
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import (  # noqa: E402
    ArtifactCorrelation,
    ProductInstallationReadback,
    ProductUpdateAssessment,
    QualifiedArtifact,
)
from forge_platform.composition_catalog import (  # noqa: E402
    CatalogInstallerContext,
    CatalogPublicationBinding,
)
from forge_platform.universal_installer import (  # noqa: E402
    AcceptedCatalogIdentity,
    CatalogAcceptanceScope,
    COMPOSITION_CATALOG_SCHEMA,
    COMPOSITION_SCHEMA,
    MAXIMUM_CANONICAL_HTTPS_URL_LENGTH,
    MAXIMUM_COMPOSITION_CATALOG_BYTES,
    MAXIMUM_COMPOSITION_CATALOG_JSON_NESTING_DEPTH,
    MAXIMUM_COMPOSITION_CATALOG_JSON_NODES,
    MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES,
    CompositionCatalog,
    CompositionCatalogEntry,
    INSTALLER_RELEASE_SCHEMA,
    CompositionComponent,
    CompositionManifest,
    CompositionPlanner,
    DiscoveredInstallation,
    DownloadIdentity,
    HostFacts,
    GitHubInstallerReleaseIdentity,
    InstalledCompositionIdentity,
    InstalledInstallerIdentity,
    InstallerRelease,
    InstallerRequirement,
    InstallerOperationRecord,
    ManagedPythonRuntimeIdentity,
    ManagedPythonRuntimeReadback,
    ManagedToolReadback,
    ProviderReadback,
    ProviderSelection,
    PublicSignatureEnvelope,
    ReleaseFeedReadback,
    SemanticVersion,
    SealedInstallerReleaseTrustExpectation,
    SignatureThresholdPolicy,
    StandaloneInstallerJournal,
    SystemServiceContract,
    UniversalInstallerError,
    VerifiedCompositionSelection,
    VerifiedInstallerContext,
    evaluate_provider_gate,
    canonical_https_url,
    plan_managed_python_runtime,
    plan_managed_tools,
    preflight_host,
    provider_command,
    select_self_update,
)
from forge_platform.managed_python_runtime_executor import (  # noqa: E402
    ManagedPythonRuntimeExecutionReceipt,
    ManagedPythonRuntimeExecutionRequest,
)


NOW = datetime(2026, 9, 9, 12, 0, tzinfo=timezone.utc)
OLD_DIGEST = "sha256:" + "1" * 64
NEW_DIGEST = "sha256:" + "2" * 64
EP_DIGEST = "sha256:" + "3" * 64
OLD_EP_DIGEST = "sha256:" + "4" * 64
GIT_DIGEST = "sha256:" + "5" * 64
PYTHON_DIGEST = "sha256:" + "6" * 64
PYTHON_SOURCE_DIGEST = "sha256:" + "c" * 64
PYTHON_SOURCE_PROVENANCE_DIGEST = "sha256:" + "d" * 64
PYTHON_BUILD_PROVENANCE_DIGEST = "sha256:" + "e" * 64
PYTHON_BUILD_EVIDENCE_DIGEST = "sha256:" + "a" * 64
PYTHON_TEST_EVIDENCE_DIGEST = "sha256:" + "b" * 64
MANIFEST_DIGEST = "sha256:" + "7" * 64
RELEASE_TRUST_CONFIGURATION_SHA256 = "8" * 64
PROVENANCE_SHA256 = "9" * 64
CODE_DIRECTORY_SHA256 = "a" * 64
NOTARIZATION_RECEIPT_REFERENCE = "receipt:fixture-notarization-arm64"
INSTALLER_CAPABILITIES = (
    "composition/v1",
    "managed-python-runtime/v1",
    "provider-gate/v1",
    "system-launchdaemon/v1",
)
CATALOG_URL = "https://github.example.invalid/forge-platform-installer/stable/composition-catalog.json"
FIXTURE_SIGNATURE_ENVELOPE = {
    "algorithm": "ed25519",
    "key_id": "fixture-key-001",
    "signature": "A" * 86,
}
FIXTURE_SIGNATURE = PublicSignatureEnvelope.from_mapping(FIXTURE_SIGNATURE_ENVELOPE)
SECOND_FIXTURE_SIGNATURE_ENVELOPE = {
    "algorithm": "ed25519",
    "key_id": "fixture-key-002",
    "signature": "B" * 86,
}
SECOND_FIXTURE_SIGNATURE = PublicSignatureEnvelope.from_mapping(SECOND_FIXTURE_SIGNATURE_ENVELOPE)
FIXTURE_SIGNATURE_POLICY = SignatureThresholdPolicy(
    algorithm="ed25519",
    trusted_key_ids=frozenset({"fixture-key-001"}),
    threshold=1,
)
SEALED_RELEASE_TRUST = SealedInstallerReleaseTrustExpectation(
    repository="example/forge-platform",
    descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
    expected_bundle_identifier="com.example.ForgePlatformInstaller",
    expected_team_identifier="ABCDE12345",
    configuration_sha256=RELEASE_TRUST_CONFIGURATION_SHA256,
)


def python_runtime_payload(**changes: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "schema": "forge-platform.managed-python-runtime/v1",
        "implementation": "cpython",
        "version": "3.14.7",
        "operating_system": "macos",
        "architecture": "arm64",
        "minimum_macos_version": "26.0.0",
        "build_variant": "standard-gil",
        "python_tag": "cp314",
        "abi_tag": "cp314",
        "platform_tag": "macosx_26_0_arm64",
        "artifact_kind": "forge-platform-managed-python-runtime-archive-v1",
        "managed_root_identity": "forge-platform-managed-python-v1",
        "artifact": {
            "url": "https://artifacts.example.invalid/python-3.14.7-macos26-arm64.tar.zst",
            "digest": PYTHON_DIGEST,
        },
        "source": {
            "url": "https://artifacts.example.invalid/Python-3.14.7.tar.xz",
            "digest": PYTHON_SOURCE_DIGEST,
        },
        "source_provenance": {
            "url": "https://evidence.example.invalid/python-3.14.7-source-sigstore.json",
            "digest": PYTHON_SOURCE_PROVENANCE_DIGEST,
        },
        "build_provenance": {
            "url": "https://evidence.example.invalid/python-3.14.7-macos26-arm64-build.json",
            "digest": PYTHON_BUILD_PROVENANCE_DIGEST,
        },
        "policy_revision": "forge-platform-managed-python-v1",
    }
    payload.update(changes)
    identity_material = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    payload["identity_digest"] = "sha256:" + sha256(identity_material).hexdigest()
    return payload


PYTHON_RUNTIME_IDENTITY = python_runtime_payload()["identity_digest"]


class FixtureVerifier:
    def __init__(
        self,
        accepted: bool = True,
        *,
        expected_policy: SignatureThresholdPolicy = FIXTURE_SIGNATURE_POLICY,
        expected_signatures: tuple[PublicSignatureEnvelope, ...] = (FIXTURE_SIGNATURE,),
    ) -> None:
        self.accepted = accepted
        self.expected_policy = expected_policy
        self.expected_signatures = expected_signatures
        self.payloads: list[bytes] = []
        self.policies: list[SignatureThresholdPolicy] = []

    def verify(
        self,
        canonical_payload: bytes,
        signatures: tuple[PublicSignatureEnvelope, ...],
        *,
        policy: SignatureThresholdPolicy,
    ) -> bool:
        self.payloads.append(canonical_payload)
        self.policies.append(policy)
        return self.accepted and policy == self.expected_policy and signatures == self.expected_signatures


def release_metadata(
    *,
    version: str = "1.1.0",
    source_revision: str = "b" * 40,
    policy_revision: str = "forge-platform-installer-release-v1",
    digest: str = NEW_DIGEST,
    sequence: int = 2,
    channel: str = "stable",
    capabilities: tuple[str, ...] = INSTALLER_CAPABILITIES,
    catalog_url: str = CATALOG_URL,
    release_trust_configuration_sha256: str = RELEASE_TRUST_CONFIGURATION_SHA256,
    provenance_sha256: str = PROVENANCE_SHA256,
    code_directory_sha256: str = CODE_DIRECTORY_SHA256,
    release_tag: str | None = None,
    descriptor_asset_name: str = "ForgePlatformInstallerReleaseDescriptor.json",
    asset_name: str = "ForgePlatformInstaller-macos-arm64.zip",
    architecture: str = "arm64",
    minimum_macos_version: str = "26.0.0",
    notarization_receipt_reference: str = NOTARIZATION_RECEIPT_REFERENCE,
    expires_at: datetime | None = None,
) -> dict[str, object]:
    return {
        "schema": INSTALLER_RELEASE_SCHEMA,
        "sequence": sequence,
        "channel": channel,
        "published_at": "2026-09-01T00:00:00Z",
        "expires_at": (expires_at or (NOW + timedelta(days=30))).isoformat().replace("+00:00", "Z"),
        "github_release": {
            "repository": "example/forge-platform",
            "tag": release_tag or f"forge-platform-installer-v{version}",
            "descriptor_asset_name": descriptor_asset_name,
        },
        "installer": {
            "version": version,
            "source_revision": source_revision,
            "policy_revision": policy_revision,
            "release_trust_configuration_sha256": release_trust_configuration_sha256,
            "provenance_sha256": provenance_sha256,
            "capabilities": list(capabilities),
            "assets": [{
                "operating_system": "macos",
                "architecture": architecture,
                "minimum_macos_version": minimum_macos_version,
                "asset_name": asset_name,
                "digest": digest,
                "bundle_identifier": "com.example.ForgePlatformInstaller",
                "team_identifier": "ABCDE12345",
                "code_directory_sha256": code_directory_sha256,
                "notarization_receipt_reference": notarization_receipt_reference,
            }],
        },
        "composition_catalog": {
            "url": catalog_url,
        },
        "signatures": [dict(FIXTURE_SIGNATURE_ENVELOPE)],
    }


def trusted_release(**changes: object) -> InstallerRelease:
    payload = release_metadata(**changes)
    return InstallerRelease.from_signed_metadata(
        payload,
        FixtureVerifier(),
        signature_policy=FIXTURE_SIGNATURE_POLICY,
        sealed_release_trust=SEALED_RELEASE_TRUST,
    )


def installed(
    *,
    version: str = "1.0.0",
    source_revision: str = "a" * 40,
    policy_revision: str = "forge-platform-installer-release-v1",
    digest: str = OLD_DIGEST,
    channel: str = "stable",
    accepted_sequence: int = 1,
    capabilities: tuple[str, ...] = INSTALLER_CAPABILITIES,
    code_directory_sha256: str = CODE_DIRECTORY_SHA256,
    notarization_receipt_reference: str = NOTARIZATION_RECEIPT_REFERENCE,
    release_trust_configuration_sha256: str = RELEASE_TRUST_CONFIGURATION_SHA256,
    provenance_sha256: str = PROVENANCE_SHA256,
) -> InstalledInstallerIdentity:
    return InstalledInstallerIdentity(
        version=SemanticVersion.parse(version),
        source_revision=source_revision,
        accepted_policy_revision=policy_revision,
        bundle_digest=digest,
        bundle_identifier="com.example.ForgePlatformInstaller",
        team_identifier="ABCDE12345",
        code_directory_sha256=code_directory_sha256,
        notarization_receipt_reference=notarization_receipt_reference,
        accepted_channel=channel,
        accepted_sequence=accepted_sequence,
        accepted_release_trust_configuration_sha256=release_trust_configuration_sha256,
        accepted_provenance_sha256=provenance_sha256,
        accepted_capabilities=frozenset(capabilities),
    )


def fresh_release_feed(*, trusted_clock: bool = True, fresh_until: datetime | None = None) -> ReleaseFeedReadback:
    return ReleaseFeedReadback(
        "https://api.github.example.invalid/repos/pcvantol/forge-platform/releases",
        NOW - timedelta(seconds=30),
        fresh_until or (NOW + timedelta(minutes=5)),
        trusted_clock,
    )


EP_ARTIFACT = QualifiedArtifact(
    version="2.3.1",
    source_revision="e" * 40,
    source="https://registry.example.invalid/engineering-platform-2.3.1.whl",
    digest=EP_DIGEST,
    qualification="https://evidence.example.invalid/ep-2.3.1",
)
OLD_EP_ARTIFACT = QualifiedArtifact(
    version="2.3.0",
    source_revision="f" * 40,
    source="https://registry.example.invalid/engineering-platform-2.3.0.whl",
    digest=OLD_EP_DIGEST,
    qualification="https://evidence.example.invalid/ep-2.3.0",
)


def absent_readback(
    *,
    identity: str = "ep-primary",
    component: str = "engineering-platform-server",
    inventory_coverage: str = "MACHINE_WIDE",
) -> ProductInstallationReadback:
    return ProductInstallationReadback(
        component=component,
        installation_identity=identity,
        state="ABSENT",
        selected_runtime_identity=None,
        selected_executable_identity=None,
        selected_server_identity=None,
        selected_instance_identity=None,
        artifact=None,
        health_state="UNKNOWN",
        inventory_coverage=inventory_coverage,
        conflict_state="NONE",
        evidence_reference="https://evidence.example.invalid/product-absent",
    )


def active_readback(
    *,
    artifact: ArtifactCorrelation = EP_ARTIFACT.correlation,
    identity: str = "ep-primary",
    component: str = "engineering-platform-server",
    conflict_state: str = "NONE",
) -> ProductInstallationReadback:
    return ProductInstallationReadback(
        component=component,
        installation_identity=identity,
        state="ACTIVE",
        selected_runtime_identity="opaque-runtime-identity",
        selected_executable_identity="opaque-executable-identity",
        selected_server_identity="opaque-server-identity",
        selected_instance_identity="opaque-instance-identity",
        artifact=artifact,
        health_state="HEALTHY",
        inventory_coverage="MACHINE_WIDE",
        conflict_state=conflict_state,
        evidence_reference="https://evidence.example.invalid/product-active",
        health_evidence_reference="https://evidence.example.invalid/product-health",
        conflict_evidence_reference=(
            "https://evidence.example.invalid/product-conflict" if conflict_state == "CONFLICTING" else None
        ),
    )


def manifest_payload(
    *,
    composition_id: str = "forge-ep-workspace-stable-001",
    upgrade_from: tuple[str, ...] = ("forge-ep-workspace-stable-000",),
    capabilities: tuple[str, ...] = INSTALLER_CAPABILITIES,
    providers: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "schema": COMPOSITION_SCHEMA,
        "composition_id": composition_id,
        "channel": "stable",
        "requires_installer": {"minimum_version": "1.0.0", "capabilities": list(capabilities)},
        "host_requirements": {
            "minimum_macos_version": "26.0.0",
            "supported_architectures": ["arm64"],
            "minimum_available_disk_bytes": 100,
            "backup_reserve_bytes": 25,
            "minimum_memory_bytes": 50,
            "requires_administrator": True,
            "requires_network": True,
            "requires_trusted_clock": True,
        },
        "managed_tools": [
            {"identity": "git", "version": "2.45.0", "url": "https://artifacts.example.invalid/git.pkg", "digest": GIT_DIGEST},
        ],
        "python_runtime": python_runtime_payload(),
        "product_venvs": [{
            "component_identity": "engineering-platform-server",
            "venv_identity": "engineering-platform-server-primary",
            "python_runtime_identity": PYTHON_RUNTIME_IDENTITY,
        }],
        "providers": providers if providers is not None else [
            {"identity": "codex", "required": True, "minimum_version": "1.0.0", "credential_scope": "user"},
            {"identity": "github-cli", "required": True, "minimum_version": "2.0.0", "credential_scope": "user"},
        ],
        "components": [
            {
                "identity": "engineering-platform-server",
                "role": "server",
                "artifact": {
                    "version": "2.3.1",
                    "source_revision": "e" * 40,
                    "source": "https://registry.example.invalid/engineering-platform-2.3.1.whl",
                    "digest": EP_DIGEST,
                    "qualification": "https://evidence.example.invalid/ep-2.3.1",
                },
                "python_runtime_qualification": {
                    "runtime_identity_digest": PYTHON_RUNTIME_IDENTITY,
                    "build_evidence": {
                        "url": "https://evidence.example.invalid/ep-2.3.1-python-build.json",
                        "digest": PYTHON_BUILD_EVIDENCE_DIGEST,
                    },
                    "test_evidence": {
                        "url": "https://evidence.example.invalid/ep-2.3.1-python-tests.json",
                        "digest": PYTHON_TEST_EVIDENCE_DIGEST,
                    },
                },
                "service": {"manager": "launchd", "domain": "system", "kind": "LaunchDaemon", "product_service_reference": "ep-server-service-v1"},
            },
        ],
        "upgrade_from": list(upgrade_from),
    }


def manifest_raw(**changes: object) -> bytes:
    payload = manifest_payload(**changes)
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def manifest() -> CompositionManifest:
    raw = manifest_raw()
    entry = CompositionCatalogEntry(
        "forge-ep-workspace-stable-001",
        "stable",
        DownloadIdentity("https://github.example.invalid/releases/forge-ep-workspace-stable-001.json", "sha256:" + sha256(raw).hexdigest()),
        InstallerRequirement(SemanticVersion.parse("1.0.0"), frozenset(INSTALLER_CAPABILITIES)),
    )
    return CompositionManifest.from_catalog_bytes(entry, raw)


def host_facts(
    *,
    administrator: bool = True,
    disk: int = 1000,
    macos_version: str = "26.0.0",
    architecture: str = "arm64",
    hardware_architecture: str = "arm64",
    is_rosetta_translated: bool = False,
) -> HostFacts:
    return HostFacts(
        "macos",
        SemanticVersion.parse(macos_version),
        architecture,
        disk,
        1000,
        administrator,
        True,
        True,
        hardware_architecture=hardware_architecture,
        is_rosetta_translated=is_rosetta_translated,
    )


def tool_readbacks() -> dict[str, ManagedToolReadback]:
    return {
        "git": ManagedToolReadback("git", "ACTIVE", SemanticVersion.parse("2.45.0"), GIT_DIGEST, "managed-git-root", "evidence:git"),
    }


def python_runtime_readback(
    *,
    state: str = "ACTIVE",
    runtime_identity: str | None = PYTHON_RUNTIME_IDENTITY,
) -> ManagedPythonRuntimeReadback:
    if state != "ACTIVE":
        return ManagedPythonRuntimeReadback(state, None, None, None, (), f"evidence:python-{state.lower()}")
    assert runtime_identity is not None
    return ManagedPythonRuntimeReadback(
        "ACTIVE",
        runtime_identity,
        "forge-platform-managed-python-v1",
        "sha256-" + runtime_identity.removeprefix("sha256:"),
        (),
        "evidence:python-active",
    )


def managed_python_execution_receipt(
    request: ManagedPythonRuntimeExecutionRequest,
) -> ManagedPythonRuntimeExecutionReceipt:
    return ManagedPythonRuntimeExecutionReceipt(
        request.operation_id,
        request.fingerprint(),
        request.target.identity_digest,
        request.runtime_slot_identity,
        request.rollback_runtime_identity,
        (
            "receipt:asset-runtime",
            "receipt:asset-source",
            "receipt:asset-source-provenance",
            "receipt:asset-build-provenance",
        ),
        "receipt:archive-inspection",
        "receipt:runtime-slot",
        tuple(
            (requirement.component_identity, f"receipt:venv-{index}")
            for index, requirement in enumerate(request.product_venvs, start=1)
        ),
        "receipt:runtime-activation",
        "receipt:runtime-final-readback",
        f"receipt:managed-python-{request.operation_id}",
        "COMPLETE",
    )


def provider_readbacks(*, github_state: str = "VERIFIED") -> dict[str, ProviderReadback]:
    return {
        "codex": ProviderReadback("codex", "VERIFIED", SemanticVersion.parse("1.2.0"), "codex-user-executable", "evidence:codex"),
        "github-cli": ProviderReadback(
            "github-cli",
            github_state,
            SemanticVersion.parse("2.5.0") if github_state == "VERIFIED" else None,
            "gh-user-executable" if github_state != "ABSENT" else None,
            "evidence:github-cli",
        ),
    }


def current_context() -> VerifiedInstallerContext:
    return VerifiedInstallerContext.establish(
        installed(
            version="1.1.0",
            source_revision="b" * 40,
            digest=NEW_DIGEST,
            accepted_sequence=2,
        ),
        [trusted_release()],
        channel="stable",
        architecture="arm64",
        now=NOW,
        release_feed=fresh_release_feed(),
        sealed_release_trust=SEALED_RELEASE_TRUST,
    )


def selection(
    *,
    context: VerifiedInstallerContext | None = None,
    composition_id: str = "forge-ep-workspace-stable-001",
    sequence: int = 4,
    accepted_catalog: AcceptedCatalogIdentity | None = None,
    manifest_changes: dict[str, object] | None = None,
    approved_python_runtime_identity: str | None = None,
    trusted_clock: bool = True,
) -> VerifiedCompositionSelection:
    context = context or current_context()
    changes = manifest_changes or {}
    raw_manifest = manifest_raw(composition_id=composition_id, **changes)
    catalog = {
        "schema": COMPOSITION_CATALOG_SCHEMA,
        "sequence": sequence,
        "channel": "stable",
        "published_at": "2026-09-01T00:00:00Z",
        "expires_at": "2026-10-01T00:00:00Z",
        "approved_python_runtime_identity": (
            approved_python_runtime_identity
            or json.loads(raw_manifest)["python_runtime"]["identity_digest"]
        ),
        "compositions": [{
            "composition_id": composition_id,
            "channel": "stable",
            "url": f"https://github.example.invalid/releases/{composition_id}.json",
            "digest": "sha256:" + sha256(raw_manifest).hexdigest(),
            "requires_installer": {"minimum_version": "1.0.0", "capabilities": list(INSTALLER_CAPABILITIES)},
        }],
        "signatures": [dict(FIXTURE_SIGNATURE_ENVELOPE)],
    }
    raw_catalog = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return VerifiedCompositionSelection.establish(
        context,
        catalog_source_url=CATALOG_URL,
        catalog_raw_bytes=raw_catalog,
        catalog_verifier=FixtureVerifier(),
        catalog_signature_policy=FIXTURE_SIGNATURE_POLICY,
        accepted_catalog=accepted_catalog,
        composition_id=composition_id,
        manifest_raw_bytes=raw_manifest,
        now=NOW,
        trusted_clock=trusted_clock,
    )


class UniversalInstallerTests(unittest.TestCase):
    def test_canonical_https_urls_match_the_native_descriptor_admission_profile(self) -> None:
        accepted = "https://CATALOG.example.invalid:443/releases/catalog%20stable.json?sequence=%7E1"
        self.assertEqual(canonical_https_url(accepted, "catalog URL"), accepted)
        trailing_query_character = "https://catalog.example.invalid/catalog.json?cursor?"
        self.assertEqual(canonical_https_url(trailing_query_character, "catalog URL"), trailing_query_character)

        for rejected in (
            "http://catalog.example.invalid/catalog.json",
            "https://user@catalog.example.invalid/catalog.json",
            "https://catalog.example.invalid:444/catalog.json",
            "https://catalog.example.invalid/catalog.json#fragment",
            "https://catalog.example.invalid/catalog space.json",
            "https://catalog.example.invalid/catalog%zz.json",
            "https://cátalog.example.invalid/catalog.json",
            "https://catalog.example.invalid?",
            "https://catalog.example.invalid:" + "a" * (MAXIMUM_CANONICAL_HTTPS_URL_LENGTH + 1),
        ):
            with self.assertRaisesRegex(ValueError, "bounded canonical HTTPS URL"):
                canonical_https_url(rejected, "catalog URL")

    def test_signed_descriptor_bytes_are_bounded_before_json_or_signature_processing(self) -> None:
        oversized = b"{" + b" " * MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES + b"}"
        with self.assertRaisesRegex(UniversalInstallerError, "accepted byte bound"):
            InstallerRelease.from_signed_bytes(
                oversized,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

    def test_catalog_bytes_and_capabilities_match_native_admission_limits(self) -> None:
        # This is deliberately malformed: the public raw-bytes entrypoint
        # must reject the size before attempting UTF-8/JSON parsing.
        oversized = b"!" * (MAXIMUM_COMPOSITION_CATALOG_BYTES + 1)
        with self.assertRaisesRegex(UniversalInstallerError, "native admission limit"):
            CompositionCatalog.from_signed_bytes(
                oversized,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )

        too_deep = (
            b'{"nested":'
            + b"[" * MAXIMUM_COMPOSITION_CATALOG_JSON_NESTING_DEPTH
            + b"0"
            + b"]" * MAXIMUM_COMPOSITION_CATALOG_JSON_NESTING_DEPTH
            + b"}"
        )
        with self.assertRaisesRegex(UniversalInstallerError, "native JSON nesting limit"):
            CompositionCatalog.from_signed_bytes(
                too_deep,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )

        too_many_nodes = b'{"values":[' + b",".join(
            b"0" for _ in range(MAXIMUM_COMPOSITION_CATALOG_JSON_NODES)
        ) + b"]}"
        with self.assertRaisesRegex(UniversalInstallerError, "native JSON node limit"):
            CompositionCatalog.from_signed_bytes(
                too_many_nodes,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )

        catalog = {
            "schema": COMPOSITION_CATALOG_SCHEMA,
            "sequence": 4,
            "channel": "stable",
            "published_at": "2026-09-01T00:00:00Z",
            "expires_at": "2026-10-01T00:00:00Z",
            "approved_python_runtime_identity": PYTHON_RUNTIME_IDENTITY,
            "compositions": [{
                "composition_id": "stable-001",
                "channel": "stable",
                "url": "https://github.example.invalid/releases/stable-001.json",
                "digest": MANIFEST_DIGEST,
                "requires_installer": {
                    "minimum_version": "1.0.0",
                    "capabilities": ["composition/v1", "composition/v1"],
                },
            }],
            "signatures": [dict(FIXTURE_SIGNATURE_ENVELOPE)],
        }
        raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
        with self.assertRaisesRegex(ValueError, "capabilities must be unique"):
            CompositionCatalog.from_signed_bytes(
                raw,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )

        catalog["compositions"][0]["requires_installer"]["capabilities"] = ["composition/v1"]
        raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.assertEqual(
            CompositionCatalog.from_signed_bytes(
                raw,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            ).entries[0].composition_id,
            "stable-001",
        )
        missing_python_approval = dict(catalog)
        missing_python_approval.pop("approved_python_runtime_identity")
        with self.assertRaisesRegex(ValueError, "fields are invalid"):
            CompositionCatalog.from_signed_bytes(
                json.dumps(missing_python_approval, sort_keys=True, separators=(",", ":")).encode("utf-8"),
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )
        invalid_python_approval = dict(catalog)
        invalid_python_approval["approved_python_runtime_identity"] = "sha256:" + "A" * 64
        with self.assertRaisesRegex(ValueError, "lowercase sha256"):
            CompositionCatalog.from_signed_bytes(
                json.dumps(invalid_python_approval, sort_keys=True, separators=(",", ":")).encode("utf-8"),
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )
        for identity in ("stable 001", " stable-001", "stable-001 ", "stable\x00-001", "x" * 257):
            catalog["compositions"][0]["composition_id"] = identity
            boundary_raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
            with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
                CompositionCatalog.from_signed_bytes(
                    boundary_raw,
                    FixtureVerifier(),
                    signature_policy=FIXTURE_SIGNATURE_POLICY,
                )
        catalog["compositions"][0]["composition_id"] = "forge-é-🚀"
        unicode_raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.assertEqual(
            CompositionCatalog.from_signed_bytes(
                unicode_raw,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            ).entries[0].composition_id,
            "forge-é-🚀",
        )
        catalog["compositions"][0]["composition_id"] = "é"
        decomposed_entry = dict(catalog["compositions"][0])
        decomposed_entry["composition_id"] = "e\u0301"
        catalog["compositions"].append(decomposed_entry)
        exact_unicode_raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
        exact_unicode_catalog = CompositionCatalog.from_signed_bytes(
            exact_unicode_raw,
            FixtureVerifier(),
            signature_policy=FIXTURE_SIGNATURE_POLICY,
        )
        self.assertEqual(
            {entry.composition_id.encode("utf-8") for entry in exact_unicode_catalog.entries},
            {"é".encode("utf-8"), "e\u0301".encode("utf-8")},
        )

    def test_signed_release_requires_a_trust_root_and_canonical_payload(self) -> None:
        verifier = FixtureVerifier()
        release = InstallerRelease.from_signed_metadata(
            release_metadata(),
            verifier,
            signature_policy=FIXTURE_SIGNATURE_POLICY,
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(release.version, SemanticVersion.parse("1.1.0"))
        self.assertEqual(len(verifier.payloads), 1)
        self.assertEqual(verifier.policies, [FIXTURE_SIGNATURE_POLICY])
        self.assertEqual(release.signatures, (FIXTURE_SIGNATURE,))
        self.assertEqual(
            release.github_release.descriptor_url,
            "https://github.com/example/forge-platform/releases/download/forge-platform-installer-v1.1.0/ForgePlatformInstallerReleaseDescriptor.json",
        )
        self.assertEqual(
            release.github_release.asset_url(release.assets[0].asset_name),
            "https://github.com/example/forge-platform/releases/download/forge-platform-installer-v1.1.0/ForgePlatformInstaller-macos-arm64.zip",
        )
        self.assertNotIn(b"signatures", verifier.payloads[0])
        with self.assertRaisesRegex(UniversalInstallerError, "signature verification failed"):
            InstallerRelease.from_signed_metadata(
                release_metadata(),
                FixtureVerifier(False),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )
        bad = release_metadata()
        bad["unexpected"] = "untrusted"  # type: ignore[index]
        with self.assertRaisesRegex(ValueError, "fields are invalid"):
            InstallerRelease.from_signed_metadata(
                bad,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

        self.assertEqual(
            trusted_release(sequence=(1 << 64) - 1).sequence,
            (1 << 64) - 1,
        )
        with self.assertRaisesRegex(ValueError, "UInt64"):
            trusted_release(sequence=(1 << 64))
        self.assertEqual(
            str(SemanticVersion.parse("9223372036854775807.0.0")),
            "9223372036854775807.0.0",
        )
        with self.assertRaisesRegex(ValueError, "Int64"):
            SemanticVersion.parse("9223372036854775808.0.0")

    def test_public_signature_envelopes_enforce_key_ids_and_threshold_before_verification(self) -> None:
        verifier = FixtureVerifier()
        opaque = release_metadata()
        opaque["signatures"] = ["opaque-signature"]
        with self.assertRaisesRegex(ValueError, "signature envelope"):
            InstallerRelease.from_signed_metadata(
                opaque,
                verifier,
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )
        self.assertEqual(verifier.payloads, [])

        untrusted = release_metadata()
        untrusted["signatures"] = [{
            "algorithm": "ed25519",
            "key_id": "untrusted-key-002",
            "signature": "A" * 86,
        }]
        with self.assertRaisesRegex(ValueError, "not trusted by policy"):
            InstallerRelease.from_signed_metadata(
                untrusted,
                verifier,
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )
        self.assertEqual(verifier.payloads, [])

        duplicate = release_metadata()
        duplicate["signatures"] = [dict(FIXTURE_SIGNATURE_ENVELOPE), dict(FIXTURE_SIGNATURE_ENVELOPE)]
        with self.assertRaisesRegex(ValueError, "key IDs must be unique"):
            InstallerRelease.from_signed_metadata(
                duplicate,
                verifier,
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )
        self.assertEqual(verifier.payloads, [])

        threshold_policy = SignatureThresholdPolicy(
            algorithm="ed25519",
            trusted_key_ids=frozenset({"fixture-key-001", "fixture-key-002"}),
            threshold=2,
        )
        with self.assertRaisesRegex(ValueError, "policy threshold"):
            InstallerRelease.from_signed_metadata(
                release_metadata(),
                verifier,
                signature_policy=threshold_policy,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )
        self.assertEqual(verifier.payloads, [])

        threshold_payload = release_metadata()
        threshold_payload["signatures"] = [
            dict(FIXTURE_SIGNATURE_ENVELOPE),
            dict(SECOND_FIXTURE_SIGNATURE_ENVELOPE),
        ]
        threshold_verifier = FixtureVerifier(
            expected_policy=threshold_policy,
            expected_signatures=(FIXTURE_SIGNATURE, SECOND_FIXTURE_SIGNATURE),
        )
        release = InstallerRelease.from_signed_metadata(
            threshold_payload,
            threshold_verifier,
            signature_policy=threshold_policy,
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(release.signatures, (FIXTURE_SIGNATURE, SECOND_FIXTURE_SIGNATURE))
        self.assertEqual(threshold_verifier.policies, [threshold_policy])

    def test_release_descriptor_rejects_arbitrary_asset_urls_and_mismatched_sealed_provenance(self) -> None:
        injected = release_metadata()
        injected["installer"]["assets"][0]["url"] = "https://attacker.example.invalid/installer.zip"  # type: ignore[index]
        with self.assertRaisesRegex(ValueError, "fields are invalid"):
            InstallerRelease.from_signed_metadata(
                injected,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

        bad_tag = release_metadata(release_tag="../other-release")
        with self.assertRaisesRegex(ValueError, "GitHub release tag"):
            InstallerRelease.from_signed_metadata(
                bad_tag,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

        for repository in ("owner/..", "./repo", "owner/."):
            dot_segment = release_metadata()
            dot_segment["github_release"]["repository"] = repository  # type: ignore[index]
            with self.assertRaisesRegex(ValueError, "GitHub release repository"):
                InstallerRelease.from_signed_metadata(
                    dot_segment,
                    FixtureVerifier(),
                    signature_policy=FIXTURE_SIGNATURE_POLICY,
                    sealed_release_trust=SEALED_RELEASE_TRUST,
                )

        redirected = release_metadata()
        redirected["github_release"]["repository"] = "other-owner/other-repository"  # type: ignore[index]
        with self.assertRaisesRegex(ValueError, "does not match the sealed trust"):
            InstallerRelease.from_signed_metadata(
                redirected,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

        # The selector repeats the binding so a manually constructed model can
        # never bypass parser admission and redirect a live update.
        forged_model = replace(
            trusted_release(),
            github_release=GitHubInstallerReleaseIdentity(
                repository="other-owner/other-repository",
                tag="forge-platform-installer-v1.1.0",
                descriptor_asset_name="ForgePlatformInstallerReleaseDescriptor.json",
            ),
        )
        with self.assertRaisesRegex(UniversalInstallerError, "sealed trust configuration"):
            select_self_update(
                installed(),
                [forged_model],
                channel="stable",
                architecture="arm64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

        current = trusted_release()
        mismatched = installed(
            version="1.1.0",
            source_revision="b" * 40,
            digest=NEW_DIGEST,
            accepted_sequence=2,
            provenance_sha256="f" * 64,
        )
        decision = select_self_update(
            mismatched,
            [current],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(decision.state, "SELF_UPDATE_BLOCKED")
        self.assertIn("different immutable provenance", decision.reason)

    def test_release_descriptor_requires_exactly_one_arm64_asset(self) -> None:
        with self.assertRaisesRegex(ValueError, "architecture"):
            trusted_release(
                architecture="x86_64",
                asset_name="ForgePlatformInstaller-macos-x86_64.zip",
            )

        payload = release_metadata()
        installer = payload["installer"]
        assert isinstance(installer, dict)
        assets = installer["assets"]
        assert isinstance(assets, list)
        assets.append(dict(assets[0]))
        with self.assertRaisesRegex(ValueError, "exactly one arm64"):
            InstallerRelease.from_signed_metadata(
                payload,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

    def test_release_descriptor_requires_exact_macos_26_asset_identity(self) -> None:
        with self.assertRaisesRegex(ValueError, "minimum_macos_version"):
            trusted_release(minimum_macos_version="27.0.0")

    def test_signed_release_bytes_reject_duplicate_json_keys_before_verification(self) -> None:
        raw = json.dumps(release_metadata(), separators=(",", ":"))
        duplicate = raw[:-1] + ',"sequence":2}'
        with self.assertRaisesRegex(UniversalInstallerError, "strict JSON"):
            InstallerRelease.from_signed_bytes(
                duplicate.encode("utf-8"),
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

    def test_older_installer_must_handoff_to_newer_verified_release(self) -> None:
        decision = select_self_update(
            installed(),
            [trusted_release()],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(decision.state, "SELF_UPDATE_REQUIRED")
        self.assertTrue(decision.old_process_must_exit)
        self.assertFalse(decision.permits_platform_mutation)
        self.assertEqual(str(decision.target_release.version), "1.1.0")  # type: ignore[union-attr]
        self.assertEqual(decision.target_asset.archive_digest, NEW_DIGEST)  # type: ignore[union-attr]

    def test_newer_installer_may_rotate_its_target_trust_configuration(self) -> None:
        rotated = trusted_release(
            version="1.2.0",
            sequence=3,
            release_trust_configuration_sha256="f" * 64,
            provenance_sha256="e" * 64,
        )
        decision = select_self_update(
            installed(),
            [rotated],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(decision.state, "SELF_UPDATE_REQUIRED")

        current_config_mismatch = select_self_update(
            installed(release_trust_configuration_sha256="f" * 64),
            [rotated],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(current_config_mismatch.state, "SELF_UPDATE_BLOCKED")
        self.assertIn("installed installer identity", current_config_mismatch.reason)

    def test_same_installer_version_with_other_bytes_fails_closed_not_overwrites(self) -> None:
        release = trusted_release(version="1.0.0", source_revision="e" * 40, digest=NEW_DIGEST)
        decision = select_self_update(
            installed(),
            [release],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(decision.state, "SELF_UPDATE_BLOCKED")
        self.assertIn("different immutable provenance", decision.reason)
        duplicate = trusted_release(version="1.1.0", source_revision="c" * 40, digest="sha256:" + "9" * 64, sequence=3)
        with self.assertRaisesRegex(UniversalInstallerError, "conflicting immutable metadata"):
            select_self_update(
                installed(),
                [trusted_release(), duplicate],
                channel="stable",
                architecture="arm64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )
        policy_changed = trusted_release(version="1.1.0", policy_revision="forge-platform-installer-release-v2", sequence=4)
        with self.assertRaisesRegex(UniversalInstallerError, "conflicting immutable metadata"):
            select_self_update(
                installed(),
                [trusted_release(), policy_changed],
                channel="stable",
                architecture="arm64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

    def test_self_update_rejects_replayed_sequence_and_higher_unproven_local_version(self) -> None:
        current = trusted_release(version="1.1.0", source_revision="b" * 40, digest=NEW_DIGEST, sequence=2)
        matching = installed(version="1.1.0", source_revision="b" * 40, digest=NEW_DIGEST, accepted_sequence=2)
        self.assertEqual(
            select_self_update(
                matching,
                [current],
                channel="stable",
                architecture="arm64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            ).state,
            "CURRENT",
        )
        replayed = installed(version="1.1.0", source_revision="b" * 40, digest=NEW_DIGEST, accepted_sequence=3)
        self.assertEqual(
            select_self_update(
                replayed,
                [current],
                channel="stable",
                architecture="arm64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            ).state,
            "SELF_UPDATE_BLOCKED",
        )
        unproven_higher = installed(version="1.2.0", accepted_sequence=3)
        self.assertEqual(
            select_self_update(
                unproven_higher,
                [current],
                channel="stable",
                architecture="arm64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            ).state,
            "SELF_UPDATE_BLOCKED",
        )

    def test_expired_release_blocks_platform_mutation(self) -> None:
        expired = trusted_release(expires_at=NOW - timedelta(seconds=1))
        decision = select_self_update(
            installed(),
            [expired],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(decision.state, "SELF_UPDATE_BLOCKED")

    def test_self_update_requires_fresh_trusted_feed_and_preserves_accepted_channel(self) -> None:
        current = trusted_release()
        matching = installed(version="1.1.0", source_revision="b" * 40, digest=NEW_DIGEST, accepted_sequence=2)
        stale = select_self_update(
            matching,
            [current],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(fresh_until=NOW),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(stale.state, "SELF_UPDATE_BLOCKED")
        untrusted_clock = select_self_update(
            matching,
            [current],
            channel="stable",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(trusted_clock=False),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(untrusted_clock.state, "SELF_UPDATE_BLOCKED")
        channel_switch = select_self_update(
            matching,
            [trusted_release(channel="candidate")],
            channel="candidate",
            architecture="arm64",
            now=NOW,
            release_feed=fresh_release_feed(),
            sealed_release_trust=SEALED_RELEASE_TRUST,
        )
        self.assertEqual(channel_switch.state, "SELF_UPDATE_BLOCKED")

    def test_catalog_binds_exact_downloaded_bytes_and_installer_capabilities(self) -> None:
        catalog = {
            "schema": COMPOSITION_CATALOG_SCHEMA,
            "sequence": 4,
            "channel": "stable",
            "published_at": "2026-09-01T00:00:00Z",
            "expires_at": "2026-10-01T00:00:00Z",
            "approved_python_runtime_identity": PYTHON_RUNTIME_IDENTITY,
            "compositions": [{
                "composition_id": "stable-001",
                "channel": "stable",
                "url": "https://github.example.invalid/releases/stable-001.json",
                "digest": MANIFEST_DIGEST,
                "requires_installer": {"minimum_version": "1.0.0", "capabilities": ["composition/v1"]},
            }],
            "component_combination_catalog": {
                "url": "https://github.example.invalid/releases/component-combinations-001.json",
                "digest": "sha256:" + "8" * 64,
            },
            "signatures": [dict(FIXTURE_SIGNATURE_ENVELOPE)],
        }
        raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
        verifier = FixtureVerifier()
        parsed = CompositionCatalog.from_signed_bytes(
            raw,
            verifier,
            signature_policy=FIXTURE_SIGNATURE_POLICY,
        )
        self.assertEqual(parsed.catalog_digest, "sha256:" + sha256(raw).hexdigest())
        self.assertEqual(
            parsed.component_combination_catalog,
            DownloadIdentity(
                "https://github.example.invalid/releases/component-combinations-001.json",
                "sha256:" + "8" * 64,
            ),
        )
        outer_acceptance = AcceptedCatalogIdentity(
            CatalogAcceptanceScope.from_verified_installer_context(current_context()),
            parsed.sequence,
            parsed.catalog_digest,
        )
        selector_context = CatalogInstallerContext.from_verified_installer_context(current_context())
        self.assertEqual(selector_context.scope, outer_acceptance.scope)
        self.assertEqual(selector_context.capabilities, current_context().capabilities)
        self.assertEqual(
            CatalogPublicationBinding.from_verified_composition_catalog(
                parsed,
                outer_catalog_acceptance=outer_acceptance,
            ),
            parsed.component_combination_catalog_binding(
                outer_catalog_acceptance=outer_acceptance,
            ),
        )
        self.assertIn(b"component_combination_catalog", verifier.payloads[0])
        self.assertEqual([entry.composition_id for entry in parsed.selectable_entries(current_context(), now=NOW)], ["stable-001"])
        with self.assertRaisesRegex(UniversalInstallerError, "does not match"):
            CompositionCatalog.from_signed_metadata(
                {**catalog, "sequence": 5},
                FixtureVerifier(),
                raw_bytes=raw,
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )
        with self.assertRaisesRegex(UniversalInstallerError, "does not match"):
            CompositionCatalog.from_signed_metadata(
                {
                    **catalog,
                    "component_combination_catalog": {
                        "url": "https://github.example.invalid/releases/component-combinations-other.json",
                        "digest": "sha256:" + "9" * 64,
                    },
                },
                FixtureVerifier(),
                raw_bytes=raw,
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            )
        tampered = raw + b" "
        self.assertNotEqual(
            CompositionCatalog.from_signed_bytes(
                tampered,
                FixtureVerifier(),
                signature_policy=FIXTURE_SIGNATURE_POLICY,
            ).catalog_digest,
            parsed.catalog_digest,
        )
        arm_only = trusted_release()
        with self.assertRaisesRegex(ValueError, "native arm64"):
            select_self_update(
                installed(),
                [arm_only],
                channel="stable",
                architecture="x86_64",
                now=NOW,
                release_feed=fresh_release_feed(),
                sealed_release_trust=SEALED_RELEASE_TRUST,
            )

    def test_catalog_without_the_new_index_locator_stays_parseable_but_cannot_bind_one(self) -> None:
        catalog = {
            "schema": COMPOSITION_CATALOG_SCHEMA,
            "sequence": 4,
            "channel": "stable",
            "published_at": "2026-09-01T00:00:00Z",
            "expires_at": "2026-10-01T00:00:00Z",
            "approved_python_runtime_identity": PYTHON_RUNTIME_IDENTITY,
            "compositions": [{
                "composition_id": "stable-001",
                "channel": "stable",
                "url": "https://github.example.invalid/releases/stable-001.json",
                "digest": MANIFEST_DIGEST,
                "requires_installer": {"minimum_version": "1.0.0", "capabilities": ["composition/v1"]},
            }],
            "signatures": [dict(FIXTURE_SIGNATURE_ENVELOPE)],
        }
        raw = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode("utf-8")
        parsed = CompositionCatalog.from_signed_bytes(
            raw,
            FixtureVerifier(),
            signature_policy=FIXTURE_SIGNATURE_POLICY,
        )
        self.assertIsNone(parsed.component_combination_catalog)
        outer_acceptance = AcceptedCatalogIdentity(
            CatalogAcceptanceScope.from_verified_installer_context(current_context()),
            parsed.sequence,
            parsed.catalog_digest,
        )
        with self.assertRaisesRegex(UniversalInstallerError, "does not declare"):
            CatalogPublicationBinding.from_verified_composition_catalog(
                parsed,
                outer_catalog_acceptance=outer_acceptance,
            )
        with self.assertRaisesRegex(TypeError, "verified signed metadata"):
            CompositionCatalog(
                sequence=parsed.sequence,
                channel=parsed.channel,
                published_at=parsed.published_at,
                expires_at=parsed.expires_at,
                approved_python_runtime_identity=parsed.approved_python_runtime_identity,
                entries=parsed.entries,
                component_combination_catalog=parsed.component_combination_catalog,
                catalog_digest=parsed.catalog_digest,
                signatures=parsed.signatures,
            )
        with self.assertRaisesRegex(ValueError, "verified CompositionCatalog"):
            CatalogPublicationBinding.from_verified_composition_catalog(
                object(),
                outer_catalog_acceptance=outer_acceptance,
            )

    def test_signed_catalog_can_advance_without_replacing_a_compatible_installer(self) -> None:
        initial = selection(sequence=4)
        newer = selection(
            context=initial.installer_context,
            sequence=5,
            accepted_catalog=initial.catalog_identity,
        )
        self.assertEqual(newer.installer_context.release, initial.installer_context.release)
        self.assertEqual(newer.catalog_identity.sequence, 5)
        with self.assertRaisesRegex(UniversalInstallerError, "regresses accepted"):
            selection(
                context=initial.installer_context,
                sequence=3,
                accepted_catalog=newer.catalog_identity,
            )
        with self.assertRaisesRegex(UniversalInstallerError, "trusted clock"):
            selection(context=initial.installer_context, trusted_clock=False)

    def test_catalog_acceptance_anchor_is_scoped_to_the_verified_installer_context(self) -> None:
        initial = selection(sequence=4)
        scope = initial.catalog_identity.scope
        context = initial.installer_context

        self.assertEqual(
            scope.installer_release_trust_configuration_sha256,
            context.release.release_trust_configuration_sha256,
        )
        self.assertEqual(scope.channel, context.release.channel)
        self.assertEqual(scope.catalog_feed_url, context.release.composition_catalog_feed.url)

        mismatched_scopes = {
            "release trust configuration": replace(
                scope,
                installer_release_trust_configuration_sha256="f" * 64,
            ),
            "channel": replace(scope, channel="candidate"),
            "catalog feed": replace(
                scope,
                catalog_feed_url="https://github.example.invalid/forge-platform-installer/stable/alternate.json",
            ),
        }
        for label, mismatched_scope in mismatched_scopes.items():
            with self.subTest(label=label):
                mismatched_anchor = replace(initial.catalog_identity, scope=mismatched_scope)
                with self.assertRaisesRegex(UniversalInstallerError, "anchor scope does not match"):
                    selection(
                        context=context,
                        sequence=initial.catalog_identity.sequence,
                        accepted_catalog=mismatched_anchor,
                    )

        with self.assertRaisesRegex(ValueError, "accepted catalog scope"):
            AcceptedCatalogIdentity(  # type: ignore[arg-type]
                "stable",
                initial.catalog_identity.sequence,
                initial.catalog_identity.catalog_digest,
            )
        with self.assertRaisesRegex(ValueError, "accepted catalog feed URL"):
            CatalogAcceptanceScope(
                scope.installer_release_trust_configuration_sha256,
                scope.channel,
                "https://github.example.invalid/invalid fragment#blocked",
            )

    def test_planner_rejects_unbound_manifest_and_requires_explicit_composition_route(self) -> None:
        with self.assertRaisesRegex(ValueError, "verified composition selection"):
            CompositionPlanner.plan(
                manifest(),
                host_facts=host_facts(),
                managed_tool_readbacks=tool_readbacks(),
                python_runtime_readback=python_runtime_readback(),
                provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
                provider_readbacks=provider_readbacks(),
                selected_readbacks={"engineering-platform-server": absent_readback()},
                update_assessments={},
            )
        compatible = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": active_readback(artifact=OLD_EP_ARTIFACT.correlation)},
            update_assessments={
                ("engineering-platform-server", "ep-primary"): ProductUpdateAssessment(
                    "engineering-platform-server", "ep-primary", EP_ARTIFACT.correlation, "UPDATE_AVAILABLE", "evidence:ep-update",
                ),
            },
            installed_composition=InstalledCompositionIdentity("forge-ep-workspace-stable-000", MANIFEST_DIGEST),
        )
        self.assertTrue(compatible.permits_product_operation_dispatch)
        self.assertEqual(compatible.component_diffs[0].action, "UPDATE")
        blocked = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": active_readback(artifact=OLD_EP_ARTIFACT.correlation)},
            update_assessments={
                ("engineering-platform-server", "ep-primary"): ProductUpdateAssessment(
                    "engineering-platform-server", "ep-primary", EP_ARTIFACT.correlation, "UPDATE_AVAILABLE", "evidence:ep-update",
                ),
            },
            installed_composition=InstalledCompositionIdentity("unapproved-composition", MANIFEST_DIGEST),
        )
        self.assertFalse(blocked.permits_product_operation_dispatch)
        self.assertIn("not an approved upgrade route", " ".join(blocked.blocking_reasons))

    def test_preflight_includes_backup_reserve_and_system_authorization(self) -> None:
        requirement = manifest().host_requirement
        blocked = preflight_host(requirement, host_facts(administrator=False, disk=124))
        self.assertEqual(blocked.state, "BLOCKED")
        self.assertIn("backup reserve", " ".join(blocked.failures))
        self.assertIn("administrator", " ".join(blocked.failures))
        self.assertEqual(preflight_host(requirement, host_facts()).state, "PASS")

    def test_platform_preflight_rejects_intel_rosetta_and_macos_25_before_mutation(self) -> None:
        requirement = manifest().host_requirement
        intel = preflight_host(
            requirement,
            host_facts(architecture="x86_64", hardware_architecture="x86_64"),
        )
        self.assertFalse(intel.permits_platform_mutation)
        self.assertIn("Apple Silicon hardware", " ".join(intel.failures))

        rosetta = preflight_host(
            requirement,
            host_facts(architecture="x86_64", is_rosetta_translated=True),
        )
        self.assertFalse(rosetta.permits_platform_mutation)
        self.assertIn("Rosetta", " ".join(rosetta.failures))

        old_macos = preflight_host(requirement, host_facts(macos_version="25.9.9"))
        self.assertFalse(old_macos.permits_platform_mutation)
        self.assertIn("macOS 26", " ".join(old_macos.failures))
        self.assertTrue(preflight_host(requirement, host_facts(macos_version="27.0.0")).permits_platform_mutation)

    def test_managed_tool_plan_never_uses_path_and_unknown_inventory_blocks(self) -> None:
        actions = plan_managed_tools(manifest().managed_tools, tool_readbacks())
        self.assertEqual([action.action for action in actions], ["NO_CHANGE"])
        unknown = dict(tool_readbacks())
        unknown["git"] = ManagedToolReadback("git", "UNKNOWN", None, None, None, "evidence:git-unknown")
        actions = plan_managed_tools(manifest().managed_tools, unknown)
        self.assertEqual(actions[0].action, "BLOCKED")
        self.assertFalse(hasattr(actions[0].readback, "path"))
        with self.assertRaisesRegex(ValueError, "unsupported"):
            ManagedToolReadback(
                "python", "ACTIVE", SemanticVersion.parse("3.14.7"), PYTHON_DIGEST,
                "managed-python-root", "evidence:python",
            )

    def test_exact_managed_python_runtime_is_path_independent_and_rollback_bound(self) -> None:
        requirement = manifest().python_runtime
        current = python_runtime_readback()
        self.assertEqual(plan_managed_python_runtime(requirement, current).action, "NO_CHANGE")
        self.assertFalse(hasattr(current, "path"))
        self.assertEqual(
            plan_managed_python_runtime(requirement, python_runtime_readback(state="ABSENT")).action,
            "INSTALL",
        )
        self.assertEqual(
            plan_managed_python_runtime(requirement, python_runtime_readback(state="UNKNOWN")).action,
            "BLOCKED",
        )
        previous = "sha256:" + "0" * 64
        upgrade = plan_managed_python_runtime(
            requirement,
            python_runtime_readback(runtime_identity=previous),
        )
        self.assertEqual(upgrade.action, "UPGRADE")
        self.assertEqual(upgrade.rollback_runtime_identity, previous)

    def test_managed_python_identity_is_exact_and_fails_closed_on_tampering(self) -> None:
        payload = python_runtime_payload()
        parsed = ManagedPythonRuntimeIdentity.from_mapping(payload)
        self.assertEqual(str(parsed.version), "3.14.7")
        self.assertEqual(parsed.identity_digest, PYTHON_RUNTIME_IDENTITY)
        self.assertEqual(parsed.architecture, "arm64")
        self.assertFalse(hasattr(parsed, "path"))

        for field, value, message in (
            ("version", "3.14.8", "identity_digest"),
            ("architecture", "x86_64", "arm64-only"),
            ("minimum_macos_version", "25.0.0", "macOS 26"),
            ("abi_tag", "abi3", "ABI tag"),
            ("platform_tag", "macosx_15_0_universal2", "platform tag"),
        ):
            tampered = dict(payload)
            tampered[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, message):
                ManagedPythonRuntimeIdentity.from_mapping(tampered)

    def test_signed_catalog_and_every_product_bind_one_python_runtime(self) -> None:
        with self.assertRaisesRegex(UniversalInstallerError, "exact identity approved"):
            selection(approved_python_runtime_identity="sha256:" + "f" * 64)

        payload = manifest_payload()
        payload["components"][0]["python_runtime_qualification"]["runtime_identity_digest"] = (
            "sha256:" + "f" * 64
        )
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        entry = CompositionCatalogEntry(
            payload["composition_id"],
            "stable",
            DownloadIdentity(
                "https://github.example.invalid/releases/python-mismatch.json",
                "sha256:" + sha256(raw).hexdigest(),
            ),
            InstallerRequirement(SemanticVersion.parse("1.0.0"), frozenset(INSTALLER_CAPABILITIES)),
        )
        with self.assertRaisesRegex(ValueError, "built and tested"):
            CompositionManifest.from_catalog_bytes(entry, raw)

        payload = manifest_payload()
        payload["product_venvs"][0]["python_runtime_identity"] = "sha256:" + "f" * 64
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        entry = replace(entry, manifest=DownloadIdentity(entry.manifest.url, "sha256:" + sha256(raw).hexdigest()))
        with self.assertRaisesRegex(ValueError, "venvs must bind"):
            CompositionManifest.from_catalog_bytes(entry, raw)

    def test_dynamic_provider_gate_blocks_until_both_required_providers_verify(self) -> None:
        requirements = manifest().providers
        selections = {
            "codex": ProviderSelection("codex", True),
            "github-cli": ProviderSelection("github-cli", True),
        }
        blocked = evaluate_provider_gate(requirements, selections, provider_readbacks(github_state="AUTHENTICATION_REQUIRED"))
        self.assertFalse(blocked.permits_platform_mutation)
        self.assertEqual(blocked.blocking_providers, ("github-cli",))
        self.assertEqual(next(action for action in blocked.actions if action.identity == "github-cli").action, "AUTHENTICATE")
        ready = evaluate_provider_gate(requirements, selections, provider_readbacks())
        self.assertTrue(ready.permits_platform_mutation)
        with self.assertRaisesRegex(UniversalInstallerError, "cannot be deselected"):
            evaluate_provider_gate(requirements, {"codex": ProviderSelection("codex", False)}, provider_readbacks())
        self.assertEqual(provider_command("codex", "AUTHENTICATE"), ("codex", "login", "--device-auth"))
        self.assertEqual(provider_command("github-cli", "VERIFY"), ("gh", "auth", "status", "--active", "--hostname", "github.com"))

    def test_server_contract_rejects_user_launchagent_and_local_component_daemon(self) -> None:
        with self.assertRaisesRegex(ValueError, "LaunchDaemons"):
            SystemServiceContract("launchd", "gui/501", "LaunchAgent", "ep-service")
        with self.assertRaisesRegex(ValueError, "local components"):
            CompositionComponent(
                "workspace-client",
                "client",
                EP_ARTIFACT,
                manifest().components[0].python_runtime_qualification,
                SystemServiceContract("launchd", "system", "LaunchDaemon", "wrong-client-service"),
            )

    def test_read_only_composition_planner_supports_clean_install_only_after_all_gates(self) -> None:
        plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": absent_readback()},
            update_assessments={},
        )
        self.assertTrue(plan.permits_product_operation_dispatch)
        self.assertEqual(plan.component_diffs[0].action, "INSTALL")
        self.assertEqual(len(plan.fingerprint()), 64)

    def test_managed_tool_install_must_finish_and_be_re_read_before_product_dispatch(self) -> None:
        readbacks = tool_readbacks()
        readbacks["git"] = ManagedToolReadback("git", "ABSENT", None, None, None, "evidence:git-absent")
        plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=readbacks,
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": absent_readback()},
            update_assessments={},
        )
        self.assertTrue(plan.permits_installer_operation_start)
        self.assertFalse(plan.permits_product_operation_dispatch)
        self.assertIn("managed tool git", " ".join(plan.blocking_reasons))

    def test_ep_absence_requires_machine_wide_inventory_before_install_plan(self) -> None:
        plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": absent_readback(inventory_coverage="PARTIAL")},
            update_assessments={},
        )
        self.assertEqual(plan.component_diffs[0].action, "BLOCKED")
        self.assertIn("machine-wide installation inventory", plan.component_diffs[0].reason)

    def test_plan_blocks_provider_failure_wrong_ep_or_unknown_removal(self) -> None:
        plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(github_state="AUTHENTICATION_REQUIRED"),
            selected_readbacks={"engineering-platform-server": active_readback(artifact=OLD_EP_ARTIFACT.correlation)},
            update_assessments={
                ("engineering-platform-server", "ep-primary"): ProductUpdateAssessment(
                    "engineering-platform-server", "ep-primary", EP_ARTIFACT.correlation, "INCOMPATIBLE", "evidence:ep-update",
                ),
            },
            discovered_installations=(DiscoveredInstallation(absent_readback(identity="old-extra", component="workspace-server"), "UNKNOWN"),),
        )
        self.assertFalse(plan.permits_product_operation_dispatch)
        self.assertIn("provider github-cli", " ".join(plan.blocking_reasons))
        self.assertIn("did not authorize the selected update", " ".join(plan.blocking_reasons))
        self.assertIn("unselected product installation", " ".join(plan.blocking_reasons))

    def test_composition_schema_parser_demands_system_daemon_and_user_scoped_providers(self) -> None:
        payload = {
            "schema": COMPOSITION_SCHEMA,
            "composition_id": "stable-001",
            "channel": "stable",
            "requires_installer": {"minimum_version": "1.0.0", "capabilities": ["composition/v1"]},
            "host_requirements": {
                "minimum_macos_version": "26.0.0",
                "supported_architectures": ["arm64"],
                "minimum_available_disk_bytes": 1,
                "backup_reserve_bytes": 1,
                "minimum_memory_bytes": 1,
                "requires_administrator": True,
                "requires_network": True,
                "requires_trusted_clock": True,
            },
            "managed_tools": [
                {"identity": "git", "version": "2.45.0", "url": "https://artifacts.example.invalid/git.pkg", "digest": GIT_DIGEST},
            ],
            "python_runtime": python_runtime_payload(),
            "product_venvs": [{
                "component_identity": "engineering-platform-server",
                "venv_identity": "engineering-platform-server-primary",
                "python_runtime_identity": PYTHON_RUNTIME_IDENTITY,
            }],
            "providers": [
                {"identity": "codex", "required": True, "minimum_version": "1.0.0", "credential_scope": "user"},
            ],
            "components": [
                {
                    "identity": "engineering-platform-server",
                    "role": "server",
                    "artifact": {
                        "version": "2.3.1", "source_revision": "e" * 40,
                        "source": "https://registry.example.invalid/engineering-platform-2.3.1.whl",
                        "digest": EP_DIGEST, "qualification": "https://evidence.example.invalid/ep",
                    },
                    "python_runtime_qualification": {
                        "runtime_identity_digest": PYTHON_RUNTIME_IDENTITY,
                        "build_evidence": {
                            "url": "https://evidence.example.invalid/ep-python-build.json",
                            "digest": PYTHON_BUILD_EVIDENCE_DIGEST,
                        },
                        "test_evidence": {
                            "url": "https://evidence.example.invalid/ep-python-tests.json",
                            "digest": PYTHON_TEST_EVIDENCE_DIGEST,
                        },
                    },
                    "service": {"manager": "launchd", "domain": "system", "kind": "LaunchDaemon", "product_service_reference": "ep-server-v1"},
                },
            ],
            "upgrade_from": [],
        }
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        entry = CompositionCatalogEntry(
            "stable-001",
            "stable",
            DownloadIdentity("https://github.example.invalid/releases/stable-001.json", "sha256:" + sha256(raw).hexdigest()),
            InstallerRequirement(SemanticVersion.parse("1.0.0"), frozenset({"composition/v1"})),
        )
        parsed = CompositionManifest.from_catalog_bytes(entry, raw)
        self.assertEqual(parsed.composition_id, "stable-001")
        bad = dict(payload)
        bad["providers"] = [{"identity": "codex", "required": True, "minimum_version": "1.0.0", "credential_scope": "system"}]
        bad_raw = json.dumps(bad, sort_keys=True, separators=(",", ":")).encode("utf-8")
        bad_entry = CompositionCatalogEntry(
            "stable-001",
            "stable",
            DownloadIdentity("https://github.example.invalid/releases/stable-001.json", "sha256:" + sha256(bad_raw).hexdigest()),
            InstallerRequirement(SemanticVersion.parse("1.0.0"), frozenset({"composition/v1"})),
        )
        with self.assertRaisesRegex(ValueError, "user-scoped"):
            CompositionManifest.from_catalog_bytes(bad_entry, bad_raw)
        with self.assertRaisesRegex(UniversalInstallerError, "catalog digest"):
            CompositionManifest.from_catalog_bytes(entry, bad_raw)

    def test_manifest_selection_plan_and_journal_share_the_catalog_composition_identity_grammar(self) -> None:
        def bound_entry(raw: bytes, composition_id: str = "forge-ep-workspace-stable-001") -> CompositionCatalogEntry:
            return CompositionCatalogEntry(
                composition_id,
                "stable",
                DownloadIdentity(
                    "https://github.example.invalid/releases/forge-ep-workspace-stable-001.json",
                    "sha256:" + sha256(raw).hexdigest(),
                ),
                InstallerRequirement(SemanticVersion.parse("1.0.0"), frozenset(INSTALLER_CAPABILITIES)),
            )

        for invalid in (
            "forge ep workspace",
            "forge\u0085ep-workspace",
            "forge\u00A0ep-workspace",
            "forge\u0001ep-workspace",
            "forge\ud800ep-workspace",
            "x" * 257,
        ):
            with self.subTest(invalid=invalid):
                raw = manifest_raw(composition_id=invalid)
                with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
                    CompositionManifest.from_catalog_bytes(bound_entry(raw), raw)

        invalid_upgrade = manifest_raw(upgrade_from=("forge\u0085ep-workspace",))
        with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
            CompositionManifest.from_catalog_bytes(bound_entry(invalid_upgrade), invalid_upgrade)

        zero_width_identity = "forge\uFEFFep-workspace-stable-001"
        zero_width_raw = manifest_raw(composition_id=zero_width_identity)
        zero_width_manifest = CompositionManifest.from_catalog_bytes(
            bound_entry(zero_width_raw, zero_width_identity),
            zero_width_raw,
        )
        self.assertEqual(zero_width_manifest.composition_id, zero_width_identity)

        with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
            InstalledCompositionIdentity("forge\u0085ep-workspace", MANIFEST_DIGEST)

        plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": absent_readback()},
            update_assessments={},
        )
        with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
            replace(plan, composition_id="forge\u0085ep-workspace")
        record = InstallerOperationRecord.create("composition-identity-001", plan)
        with self.assertRaisesRegex(ValueError, "bounded whitespace-free identity"):
            replace(record, composition_id="forge\u0085ep-workspace")

    def test_composition_identity_schemas_exclude_non_scalar_and_whitespace_values(self) -> None:
        """Keep published JSON schema grammar identical to native/Python admission."""

        patterns: list[str] = []
        for relative_path in (
            "schemas/universal-installer-composition.schema.json",
            "schemas/universal-installer-component-combination-catalog.schema.json",
            "schemas/universal-installer-composition-catalog.schema.json",
        ):
            schema = json.loads((ROOT / relative_path).read_text(encoding="utf-8"))
            identity = schema["$defs"]["composition_identity"]
            self.assertEqual(identity["minLength"], 1)
            self.assertEqual(identity["maxLength"], 256)
            pattern = identity["pattern"]
            self.assertIn(r"\uD800-\uDFFF", pattern)
            patterns.append(pattern)
            compiled = re.compile(pattern)
            def schema_accepts(value: str) -> bool:
                return (
                    identity["minLength"] <= len(value) <= identity["maxLength"]
                    and compiled.fullmatch(value) is not None
                )

            self.assertTrue(schema_accepts("forge\uFEFFep-workspace"))
            for invalid in (
                "forge ep-workspace",
                "forge\u0085ep-workspace",
                "forge\u00A0ep-workspace",
                "forge\u0001ep-workspace",
                "forge\ud800ep-workspace",
                "x" * 257,
            ):
                with self.subTest(path=relative_path, invalid=invalid):
                    self.assertFalse(schema_accepts(invalid))
        self.assertEqual(patterns, [patterns[0]] * len(patterns))

    def test_standalone_journal_is_atomic_non_secret_and_bound_to_one_ready_plan(self) -> None:
        plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": absent_readback()},
            update_assessments={},
        )
        self.assertEqual(plan.python_runtime_action.action, "NO_CHANGE")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "installer operations"
            journal = StandaloneInstallerJournal(root)
            record = InstallerOperationRecord.create("install-001", plan)
            self.assertEqual(record.python_runtime_identity, PYTHON_RUNTIME_IDENTITY)
            self.assertEqual(
                record.product_venv_identities,
                (("engineering-platform-server", "engineering-platform-server-primary"),),
            )
            self.assertEqual(journal.start(record), record)
            self.assertEqual(oct((root / "install-001.json").stat().st_mode & 0o777), "0o600")
            self.assertEqual(oct(root.stat().st_mode & 0o777), "0o700")
            second = InstallerOperationRecord.create("install-002", plan)
            with self.assertRaisesRegex(UniversalInstallerError, "active operation"):
                journal.start(second)
            running = journal.advance(
                "install-001",
                "PRODUCT_OPERATIONS",
                {"result": "PRODUCT_OPERATIONS_DISPATCHED", "product_receipt_references": ["receipt:product-001"]},
            )
            with self.assertRaisesRegex(UniversalInstallerError, "PRODUCT_OPERATIONS -> CLEANUP_PENDING"):
                journal.advance(
                    "install-001",
                    "CLEANUP_PENDING",
                    {"result": "CLEANUP_PENDING", "cleanup_receipt_references": ["receipt:cleanup-001"], "failed_target_ids": ["operation-cache"]},
                )
            ready = journal.advance(
                "install-001",
                "READINESS",
                {"result": "READINESS_VERIFIED", "readiness_receipt_references": ["receipt:readiness-001"]},
            )
            pending = journal.advance(
                "install-001",
                "CLEANUP_PENDING",
                {"result": "CLEANUP_PENDING", "cleanup_receipt_references": ["receipt:cleanup-001"], "failed_target_ids": ["operation-cache"]},
            )
            complete = journal.advance(
                "install-001",
                "COMPLETE",
                {"result": "CLEANUP_COMPLETE", "cleanup_receipt_references": ["receipt:cleanup-002"]},
            )
            self.assertEqual(running.state, "PRODUCT_OPERATIONS")
            self.assertEqual(ready.state, "READINESS")
            self.assertEqual(pending.state, "CLEANUP_PENDING")
            self.assertEqual(journal.load("install-001"), complete)
            with self.assertRaisesRegex(ValueError, "opaque reference"):
                running.transition(
                    "READINESS",
                    {"result": "READINESS_VERIFIED", "readiness_receipt_references": ["ghp_must-not-be-recorded"]},
                )
            with self.assertRaisesRegex(UniversalInstallerError, "must start"):
                journal.start(running)
            tool_inventory = tool_readbacks()
            tool_inventory["git"] = ManagedToolReadback("git", "ABSENT", None, None, None, "evidence:git-absent")
            tool_plan = CompositionPlanner.plan(
                selection(),
                host_facts=host_facts(),
                managed_tool_readbacks=tool_inventory,
                python_runtime_readback=python_runtime_readback(),
                provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
                provider_readbacks=provider_readbacks(),
                selected_readbacks={"engineering-platform-server": absent_readback()},
                update_assessments={},
            )
            tool_record = InstallerOperationRecord.create("install-tools", tool_plan)
            journal.start(tool_record)
            with self.assertRaisesRegex(UniversalInstallerError, "managed tools require"):
                journal.advance(
                    "install-tools",
                    "PRODUCT_OPERATIONS",
                    {"result": "PRODUCT_OPERATIONS_DISPATCHED", "product_receipt_references": ["receipt:product-tools"]},
                )
            execution_request = ManagedPythonRuntimeExecutionRequest(
                "install-tools",
                tool_plan.python_runtime_action,
                tool_plan.product_venvs,
            )
            execution_receipt = managed_python_execution_receipt(execution_request)
            with self.assertRaisesRegex(UniversalInstallerError, "terminal-receipt bridge"):
                journal.advance(
                    "install-tools",
                    "MANAGED_TOOLS",
                    execution_receipt.installer_journal_evidence(plan.fingerprint()),
                )
            with self.assertRaisesRegex(UniversalInstallerError, "does not verify exact"):
                journal.advance_managed_tools(
                    "install-tools",
                    tool_plan,
                    execution_request,
                    execution_receipt,
                    tool_plan,
                    {"git": "receipt:tool-git"},
                )
            with self.assertRaisesRegex(UniversalInstallerError, "original plan"):
                journal.advance_managed_tools(
                    "install-tools",
                    plan,
                    execution_request,
                    execution_receipt,
                    plan,
                    {"git": "receipt:tool-git"},
                )
            with self.assertRaisesRegex(UniversalInstallerError, "immutable"):
                journal.advance_managed_tools(
                    "install-tools",
                    tool_plan,
                    execution_request,
                    execution_receipt,
                    replace(plan, composition_id="different-composition"),
                    {"git": "receipt:tool-git"},
                )
            with self.assertRaisesRegex(UniversalInstallerError, "do not match"):
                journal.advance_managed_tools(
                    "install-tools",
                    tool_plan,
                    execution_request,
                    execution_receipt,
                    plan,
                    {},
                )
            with self.assertRaisesRegex(UniversalInstallerError, "terminal receipt"):
                journal.advance_managed_tools(
                    "install-tools",
                    tool_plan,
                    execution_request,
                    replace(execution_receipt, request_fingerprint="f" * 64),
                    plan,
                    {"git": "receipt:tool-git"},
                )
            with self.assertRaisesRegex(UniversalInstallerError, "terminal receipt"):
                journal.advance_managed_tools(
                    "install-tools",
                    tool_plan,
                    execution_request,
                    replace(
                        execution_receipt,
                        product_venv_evidence_references=(
                            ("forge-runtime", "receipt:venv-wrong-component"),
                        ),
                    ),
                    plan,
                    {"git": "receipt:tool-git"},
                )
            managed_tools = journal.advance_managed_tools(
                "install-tools",
                tool_plan,
                execution_request,
                execution_receipt,
                plan,
                {"git": "receipt:tool-git"},
            )
            self.assertEqual(managed_tools.state, "MANAGED_TOOLS")
            self.assertEqual(
                managed_tools.events[-1].evidence["post_tool_plan_fingerprint"],
                plan.fingerprint(),
            )
            self.assertEqual(
                journal.advance(
                    "install-tools",
                    "PRODUCT_OPERATIONS",
                    {"result": "PRODUCT_OPERATIONS_DISPATCHED", "product_receipt_references": ["receipt:product-tools"]},
                ).state,
                "PRODUCT_OPERATIONS",
            )

        previous_python = "sha256:" + "0" * 64
        upgrade_plan = CompositionPlanner.plan(
            selection(),
            host_facts=host_facts(),
            managed_tool_readbacks=tool_readbacks(),
            python_runtime_readback=python_runtime_readback(runtime_identity=previous_python),
            provider_selections={"codex": ProviderSelection("codex", True), "github-cli": ProviderSelection("github-cli", True)},
            provider_readbacks=provider_readbacks(),
            selected_readbacks={"engineering-platform-server": absent_readback()},
            update_assessments={},
        )
        upgrade_record = InstallerOperationRecord.create("upgrade-python", upgrade_plan)
        self.assertEqual(upgrade_record.python_runtime_rollback_identity, previous_python)
        upgrade_request = ManagedPythonRuntimeExecutionRequest(
            "upgrade-python",
            upgrade_plan.python_runtime_action,
            upgrade_plan.product_venvs,
        )
        upgrade_receipt = managed_python_execution_receipt(upgrade_request)
        with tempfile.TemporaryDirectory() as temporary:
            upgrade_journal = StandaloneInstallerJournal(Path(temporary) / "upgrade-journal")
            upgrade_journal.start(upgrade_record)
            bridged_upgrade = upgrade_journal.advance_managed_tools(
                "upgrade-python",
                upgrade_plan,
                upgrade_request,
                upgrade_receipt,
                plan,
                {},
            )
            self.assertEqual(
                bridged_upgrade.events[-1].evidence["tool_receipt_references"],
                [upgrade_receipt.evidence_reference],
            )
        evidence = {
            "result": "TOOLS_VERIFIED",
            "tool_receipt_references": ["receipt:python-runtime"],
            "python_runtime_receipt_reference": "receipt:python-runtime",
            "python_runtime_identity": PYTHON_RUNTIME_IDENTITY,
            "retained_python_runtime_identity": previous_python,
            "post_tool_plan_fingerprint": "b" * 64,
        }
        with self.assertRaisesRegex(UniversalInstallerError, "does not activate"):
            upgrade_record.transition(
                "MANAGED_TOOLS",
                {**evidence, "python_runtime_identity": "sha256:" + "f" * 64},
            )
        managed_record = upgrade_record.transition("MANAGED_TOOLS", evidence)
        self.assertEqual(managed_record.state, "MANAGED_TOOLS")
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(UniversalInstallerError, "must start"):
                StandaloneInstallerJournal(Path(temporary)).start(managed_record)
        recovery_evidence = {
            "result": "RECOVERY_PENDING",
            "recovery_receipt_references": ["receipt:python-recovery"],
            "python_runtime_rollback_receipt_reference": "receipt:python-rollback",
            "restored_python_runtime_identity": previous_python,
        }
        with self.assertRaisesRegex(UniversalInstallerError, "does not restore"):
            managed_record.transition(
                "RECOVERY_PENDING",
                {**recovery_evidence, "restored_python_runtime_identity": "sha256:" + "f" * 64},
            )
        self.assertEqual(
            managed_record.transition("RECOVERY_PENDING", recovery_evidence).state,
            "RECOVERY_PENDING",
        )


if __name__ == "__main__":
    unittest.main()
