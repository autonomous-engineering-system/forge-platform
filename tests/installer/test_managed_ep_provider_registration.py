#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
import io
import json
from pathlib import Path
import tempfile
import unittest

from forge_platform.engineering_platform_system_adapter import (
    EPSystemInstanceTarget, EngineeringPlatformSystemProvisionerAdapter,
)
from forge_platform.installer_product_worker import (
    InstallerProductWorkerUnavailable, execute_ep_provider_registration, run,
)
from forge_platform.managed_ep_provider_registration import (
    EPProviderRegistrationRequest, RECEIPT_SCHEMA, register_ep_provider,
)
from forge_platform.managed_product_operation_service import (
    ManagedProductOperationHelperService, ManagedProductOperationServiceError,
    PinnedManagedProductOperationAuthorityResolver,
)
from forge_platform.universal_installer import (
    DownloadIdentity, ProviderRequirement, ProviderRuntimeRequirement,
    SemanticVersion,
)
from tests.installer.test_ep_provider_target import ProductRunner
from tests.installer.test_managed_product_operation_admission import installer_release
from tests.installer.test_universal_installer import current_context, selection


class EPProviderWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.private = tempfile.TemporaryDirectory()
        root = Path(self.private.name).resolve()
        self.runner = ProductRunner()
        self.adapter = EngineeringPlatformSystemProvisionerAdapter(
            provisioner_executable=root / "bin/engineering-platform-system-provisioner",
            product_root=root / "product",
            target=EPSystemInstanceTarget("ep-prod", "Production", "_ep_prod", 8876),
            staged_artifacts={}, runner=self.runner,
        )
        runtime = ProviderRuntimeRequirement(
            SemanticVersion.parse("1.1.0"), "tar.gz",
            DownloadIdentity("https://example.invalid/codex.tar.gz", "sha256:" + "b" * 64),
            "bin/codex", "sha256:" + "d" * 64,
        )
        selected = selection(context=current_context(), composition_id="forge-ep-current")
        self.manifest = replace(selected.manifest, providers=(ProviderRequirement(
            "codex", True, SemanticVersion.parse("1.0.0"), "component",
            "engineering-platform-server", "deployment-a", runtime,
        ),))
        self.request = EPProviderRegistrationRequest(
            "operation-a", "sha256:" + "a" * 64,
            self.manifest.composition_id, self.manifest.manifest_digest,
            "deployment-a", "ep-prod", "codex",
            "receipt:provider-observation-" + "c" * 64,
        )
        self.service = object.__new__(ManagedProductOperationHelperService)
        self.service.authority_resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=installer_release(), manifests=(self.manifest,)
        )
        self.service.provider_routes = {"deployment-a": self.adapter}

    def tearDown(self) -> None:
        self.private.cleanup()

    def test_exact_pinned_worker_route_registers_only_ep_target(self) -> None:
        raw = self.request.canonical_bytes()
        response = execute_ep_provider_registration(
            raw, service_loader=lambda: self.service
        )
        receipt = json.loads(response)
        self.assertEqual(receipt["schema"], RECEIPT_SCHEMA)
        self.assertEqual(receipt["ep_instance_id"], "ep-prod")
        self.assertEqual(receipt["provider_target"], "codex:engineering-platform-server:ep-prod")
        self.assertEqual(receipt["state"], "VERIFIED")
        self.assertEqual(len(self.runner.calls), 1)
        self.assertIn("provider-register", self.runner.calls[0])
        self.assertNotIn("provider-observation", " ".join(self.runner.calls[0]))
        self.assertNotIn("token", response.decode().lower())
        output = io.BytesIO()
        self.assertEqual(run(io.BytesIO(raw), output, service_loader=lambda: self.service), 0)
        self.assertEqual(output.getvalue(), response)

    def test_wrong_route_manifest_instance_and_observation_fail_before_product(self) -> None:
        for request, routes in (
            (replace(self.request, deployment_id="deployment-b"), self.service.provider_routes),
            (replace(self.request, ep_instance_id="ep-other"), self.service.provider_routes),
            (replace(self.request, manifest_digest="sha256:" + "e" * 64), self.service.provider_routes),
            (self.request, {"deployment-b": self.adapter}),
        ):
            with self.subTest(request=request, routes=routes):
                self.service.provider_routes = routes
                with self.assertRaises(ManagedProductOperationServiceError):
                    self.service.register_ep_provider(request.canonical_bytes())
                self.assertEqual(self.runner.calls, [])
        for raw in (
            self.request.canonical_bytes() + b"\n",
            self.request.canonical_bytes().replace(b"provider-observation-", b"forged-"),
            b"{}",
        ):
            with self.subTest(raw=raw), self.assertRaises(Exception):
                execute_ep_provider_registration(raw, service_loader=lambda: self.service)
        self.assertEqual(self.runner.calls, [])

    def test_github_cli_uses_exact_product_owned_github_context(self) -> None:
        github_runtime = replace(
            self.manifest.providers[0].runtime,
            executable_relative_path="bin/gh",
            executable_digest="sha256:" + "e" * 64,
        )
        self.manifest = replace(self.manifest, providers=(replace(
            self.manifest.providers[0], identity="github-cli", runtime=github_runtime,
        ),))
        self.service.authority_resolver = PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=installer_release(), manifests=(self.manifest,)
        )
        request = replace(self.request, provider="github-cli")
        receipt = json.loads(self.service.register_ep_provider(request.canonical_bytes()))
        self.assertEqual(receipt["provider_target"], "github-cli:engineering-platform-server:ep-prod")
        self.assertEqual(receipt["runtime_digest"], "sha256:" + "e" * 64)
        self.assertEqual(self.runner.calls[0][self.runner.calls[0].index("--provider") + 1], "github")

    def test_worker_rejects_mismatched_product_receipt(self) -> None:
        raw = self.request.canonical_bytes()
        fake = object.__new__(ManagedProductOperationHelperService)
        fake.register_ep_provider = lambda _request: b'{"schema":"wrong"}'
        with self.assertRaises(InstallerProductWorkerUnavailable):
            execute_ep_provider_registration(raw, service_loader=lambda: fake)
        self.assertEqual(self.runner.calls, [])

    def test_direct_registration_rejects_wrong_manifest_target(self) -> None:
        wrong = replace(self.manifest, providers=(replace(
            self.manifest.providers[0], target_identity="deployment-b"
        ),))
        with self.assertRaisesRegex(ValueError, "manifest target"):
            register_ep_provider(self.request, manifest=wrong, adapter=self.adapter)
        self.assertEqual(self.runner.calls, [])


if __name__ == "__main__":
    unittest.main()
