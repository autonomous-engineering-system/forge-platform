#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import tempfile
import unittest

from forge_platform.engineering_platform_provider_target import (
    EPProviderHumanAuthEvidenceBundle,
    EPProviderTargetAuthenticationEvidence,
    EngineeringPlatformProviderTargetProvisioner,
)
from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget,
    EngineeringPlatformAdapterError,
    EngineeringPlatformSystemProvisionerAdapter,
    ProductCommandResult,
)
from forge_platform.provider_fanout import (
    ProviderBootstrapHandle,
    ProviderFanoutCoordinator,
    ProviderFanoutError,
)
from forge_platform.universal_installer import (
    DownloadIdentity,
    ProviderRequirement,
    ProviderRuntimeRequirement,
    SemanticVersion,
)


class ProductRunner:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.instance_id = "ep-prod"

    def run(self, argv):
        args = tuple(argv)
        self.calls.append(args)
        provider = args[args.index("--provider") + 1]
        payload = {
            "provider": provider,
            "instance_id": self.instance_id,
            "state": "READY",
            "executable": "/Library/EP/instances/ep-prod/providers/" + provider + "/runtime/bin/" + (
                "codex" if provider == "codex" else "gh"
            ),
            "executable_sha256": args[args.index("--provider-executable-digest") + 1],
            "version": args[args.index("--provider-version") + 1],
            "home": "/Library/EP/instances/ep-prod/providers/" + provider + "/home",
            "credential_scope": "COMPONENT_INSTANCE",
            "authentication": {
                "state": "READY",
                "reference": args[args.index("--auth-reference") + 1],
            },
            "cold_boot_ready": True,
        }
        return ProductCommandResult(0, json.dumps(payload), "")


class Authenticator:
    def __init__(self, bundle):
        self.bundle = bundle

    def authenticate(self, provider, requirements):
        return ProviderBootstrapHandle(
            provider, "ceremony-codex", "supported-human-device-flow", self.bundle
        )


class EPProviderTargetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name).resolve()
        self.runner = ProductRunner()
        self.adapter = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=root / "bin/engineering-platform-system-provisioner",
            product_root=root / "product",
            target=EPSystemInstanceTarget("ep-prod", "Production", "_ep_prod", 8876),
            staged_artifacts={},
            runner=self.runner,
        )
        self.runtime = ProviderRuntimeRequirement(
            SemanticVersion.parse("1.1.0"), "tar.gz",
            DownloadIdentity("https://example.invalid/codex.tar.gz", "sha256:" + "b" * 64),
            "bin/codex", "sha256:" + "d" * 64,
        )
        self.requirement = ProviderRequirement(
            "codex", True, SemanticVersion.parse("1.0.0"), "component",
            "engineering-platform-server", "ep-prod", self.runtime,
        )
        self.evidence = EPProviderTargetAuthenticationEvidence(
            self.requirement.key, "codex", "ceremony-codex",
            self.runtime.version, self.runtime.executable_digest,
            "auth-reference-0001", "bootstrap-receipt-0001",
        )
        self.bundle = EPProviderHumanAuthEvidenceBundle(
            "codex", "ceremony-codex", (self.evidence,)
        )
        self.target = EngineeringPlatformProviderTargetProvisioner(self.adapter)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_exact_product_registration_readback_is_bound_to_fanout(self) -> None:
        receipts = ProviderFanoutCoordinator(
            authenticators={"codex": Authenticator(self.bundle)},
            targets={self.requirement.key: self.target},
        ).execute((self.requirement,))
        self.assertEqual(len(self.runner.calls), 1)
        self.assertIn("provider-register", self.runner.calls[0])
        receipt = receipts[0].targets[0]
        self.assertEqual(receipt.target_key, self.requirement.key)
        self.assertEqual(receipt.executable_digest, self.runtime.executable_digest)
        self.assertTrue(receipt.evidence_reference.startswith("ep-provider-readback:sha256:"))
        self.assertNotIn("auth-reference-0001", repr(receipts))
        self.assertNotIn("bootstrap-receipt-0001", repr(receipts))

    def test_github_cli_uses_product_owned_github_context(self) -> None:
        runtime = replace(
            self.runtime,
            executable_relative_path="bin/gh",
            executable_digest="sha256:" + "e" * 64,
        )
        requirement = replace(
            self.requirement, identity="github-cli", runtime=runtime
        )
        evidence = EPProviderTargetAuthenticationEvidence(
            requirement.key, "github-cli", "ceremony-codex",
            runtime.version, runtime.executable_digest,
            "github-auth-reference", "github-bootstrap-receipt",
        )
        bundle = EPProviderHumanAuthEvidenceBundle(
            "github-cli", "ceremony-codex", (evidence,)
        )
        readback = self.target.provision_and_verify(
            requirement,
            Authenticator(bundle).authenticate("github-cli", (requirement,)),
        )
        self.assertEqual(readback.identity, "github-cli")
        self.assertEqual(readback.executable_digest, runtime.executable_digest)
        self.assertEqual(
            self.runner.calls[0][self.runner.calls[0].index("--provider") + 1], "github"
        )

    def test_wrong_target_and_runtime_drift_fail_before_product_call(self) -> None:
        for requirement, evidence in (
            (replace(self.requirement, target_identity="ep-other"), self.evidence),
            (self.requirement, replace(self.evidence, target_key="codex:other:instance")),
            (self.requirement, replace(self.evidence, executable_digest="sha256:" + "e" * 64)),
            (self.requirement, replace(self.evidence, version=SemanticVersion.parse("1.2.0"))),
        ):
            with self.subTest(requirement=requirement, evidence=evidence):
                bundle = EPProviderHumanAuthEvidenceBundle(
                    "codex", "ceremony-codex", (evidence,)
                )
                bootstrap = Authenticator(bundle).authenticate("codex", (requirement,))
                with self.assertRaises(ProviderFanoutError):
                    self.target.provision_and_verify(requirement, bootstrap)
                self.assertEqual(self.runner.calls, [])

    def test_product_owned_wrong_instance_readback_fails_closed(self) -> None:
        self.runner.instance_id = "ep-other"
        with self.assertRaisesRegex(EngineeringPlatformAdapterError, "exact target"):
            self.target.provision_and_verify(
                self.requirement,
                Authenticator(self.bundle).authenticate("codex", (self.requirement,)),
            )
        self.assertEqual(len(self.runner.calls), 1)

    def test_malformed_or_duplicate_auth_evidence_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            replace(self.evidence, auth_reference="secret with spaces")
        with self.assertRaises(ValueError):
            EPProviderHumanAuthEvidenceBundle(
                "codex", "ceremony-codex", (self.evidence, self.evidence)
            )
        with self.assertRaisesRegex(ProviderFanoutError, "authority is unavailable"):
            self.target.provision_and_verify(
                self.requirement,
                ProviderBootstrapHandle(
                    "codex", "ceremony-codex", "unsupported", object()
                ),
            )
        self.assertEqual(self.runner.calls, [])


if __name__ == "__main__":
    unittest.main()
