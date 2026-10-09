#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import replace
from hashlib import sha256
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, PropertyMock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from forge_platform.component_operations import ComponentOperationRequest, QualifiedArtifact
from forge_platform.forge_server_adapter import (
    ForgeCommandResult, ForgeServerAdapterError, ForgeServerTarget,
)
from forge_platform.forge_update_binding_provider import ReleasedForge239UpdateBindingProvider, ReleasedForge281MaintenanceBindingProvider
from forge_platform.forge_update_intent import ForgeUpdateIntent, ForgeUpdateIntentStore
from forge_platform.forge_update_resources import Forge239UpdateResources


OLD = QualifiedArtifact(
    "2.7.38", "0a3d6e35b01da93bb5a674ae7795558655c16c7d",
    "https://example.invalid/forge-old.whl",
    "sha256:e9a5609969b8e49476f44e99a6cf72b8edf60280a77e010effe55a3bc1b33af8",
    "https://example.invalid/old-evidence",
)
NEW = QualifiedArtifact(
    "2.7.39", "ebc43dc12da27353f85c991a26da9852aa790f05",
    "https://example.invalid/forge-new.whl",
    "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1",
    "https://example.invalid/new-evidence",
)


class StatusRunner:
    def __init__(self, root: Path, instance: str) -> None:
        self.root = root
        self.instance = instance
        self.version = OLD.version
        self.runtime_id = instance
        self.peer = {"status": "NOT_CONFIGURED", "live_status": "NOT_VERIFIED"}
        self.calls: list[tuple[str, ...]] = []

    def run(self, argv) -> ForgeCommandResult:
        self.calls.append(tuple(argv))
        if tuple(argv)[-2:] == ("health", "snapshot"):
            return ForgeCommandResult(2, json.dumps({"read_only": True, "product": "forge",
                "product_version": self.version, "runtime_id": self.runtime_id,
                "installation_id": "installation-a", "outcome": "MISSING"}), "")
        return ForgeCommandResult(0, json.dumps({
            "product_version": self.version,
            "data_root": str(self.root / "instances/forge" / self.instance),
            "initialized": True, "runtime_status": "active",
            "instance_id": self.runtime_id, "execution_host_peer": self.peer,
        }), "")


class ReleasedForge239UpdateBindingProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        for relative in (
            "products", "products/forge", "products/forge/forge-a",
            "state", "state/forge-update-intents",
            "managed-python-product-venvs/venv-a/bin",
        ):
            path = self.root / relative
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o700)
        self.root.chmod(0o700)
        self.executable = self.root / "managed-python-product-venvs/venv-a/bin/forge"
        self.executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        self.executable.chmod(0o700)
        self.target = ForgeServerTarget(
            "forge-a", self.root / "instances/forge/forge-a",
            self.root / "instances/forge", "_forge_a", 8811,
            self.root / "credentials/forge-a.token",
        )
        self.runner = StatusRunner(self.root, self.target.instance_id)
        self.controller = self.root / "signed/forge-controller.py"
        self.receipt = self.root / "signed/release.json"
        self.resources = Forge239UpdateResources(self.controller, self.receipt)
        self.provider = ReleasedForge239UpdateBindingProvider(
            self.root, self.root / "Signed.app/Contents/Resources/forge-platform-product-worker.pyz",
            self.executable, self.target, OLD, "installation-a",
            self.root / "managed-python-runtime-slots/slot/bin/python3",
            os.geteuid(), runner=self.runner,
        )
        self.request = ComponentOperationRequest(
            "update-forge-a", "forge-runtime", "update", NEW,
            self.target.instance_id, "server", {},
        )
        self.patch = patch(
            "forge_platform.forge_update_binding_provider.read_forge_239_update_resources",
            return_value=self.resources,
        )
        self.patch.start()

    def tearDown(self) -> None:
        self.patch.stop()
        self.temporary.cleanup()

    def test_281_maintenance_keeps_selector_and_owns_real_runtime_uuid(self) -> None:
        # Contract fixtures; no installed-product or signed-app claim.
        candidate = QualifiedArtifact("2.8.1", "c8833ffa4754800de451cce94b109ef1ad07123f",
            NEW.source, "sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0", NEW.qualification)
        fields = dict(vars(self.provider)); fields["installed_artifact"] = NEW
        provider = ReleasedForge281MaintenanceBindingProvider(**fields)
        request = replace(self.request, artifact=candidate)
        self.runner.version = NEW.version; self.runner.runtime_id = "forge-runtime-own-uuid"
        with patch("forge_platform.forge_update_binding_provider.read_forge_281_maintenance_resources",
                   return_value=self.resources), patch.object(ForgeServerTarget, "product_runtime_id",
                   new_callable=PropertyMock, return_value=self.runner.runtime_id), patch(
                   "forge_platform.forge_281_compartment.prepare_281_compartment") as prepare:
            from forge_platform.forge_281_compartment import PreparedForge281Compartment
            runtime=self.target.instances_root/".maintenance-forge-a/runtime"
            prepare.return_value=PreparedForge281Compartment(runtime,runtime.parent/"bin/forge",
                self.executable.parent/"python3",runtime/"inputs/forge_autonomy-2.7.39-py3-none-any.whl",
                runtime/"inputs/forge_autonomy-2.8.1-py3-none-any.whl",
                "sha256:"+sha256(self.executable.read_bytes()).hexdigest(),self.executable)
            binding = provider.resolve(request)
            self.assertEqual(binding.runtime_id, "forge-runtime-own-uuid")
            self.assertEqual(binding.runtime_root, runtime)
            self.assertEqual(binding.installation_id, "installation-a")
            self.assertEqual(binding.existing_version, "2.7.39")
            self.assertEqual(binding.installed_wheel,
                runtime / "inputs/forge_autonomy-2.7.39-py3-none-any.whl")
            intent = ForgeUpdateIntent(request.operation_id, request.fingerprint(), self.target.instance_id,
                NEW.digest, candidate.digest, "forge-update-assess:sha256:" + "a" * 64,
                binding_snapshot=binding.durable_snapshot())
            self.assertEqual(intent.payload()["schema"], "forge-platform.forge-update-intent/v3")
            store = ForgeUpdateIntentStore(binding.intent_root)
            store.prepare(intent)
            self.assertEqual(store.read(request.operation_id), intent)
            drift = dict(binding.durable_snapshot()); drift["installer_instance_id"] = "different-selector"
            with self.assertRaises(ValueError): replace(intent, binding_snapshot=tuple(sorted(drift.items())))
            with self.assertRaises(ValueError): replace(intent, candidate_artifact=NEW.digest)
            self.assertEqual(binding.controller_source, "0ea8c1a263a8b71a09d1206387099b748789b04b")
            self.assertEqual(binding.qualification_receipt_sha256,
                "sha256:51017bb17faa3d2568e457360d54b873deddbf59eeedb86310b4cb56e1345a76")
            calls = len(self.runner.calls)
            with self.assertRaises(ForgeServerAdapterError):
                provider.resolve(replace(request, artifact=replace(candidate, source_revision="0" * 40)))
            self.assertEqual(len(self.runner.calls), calls)
            # Historical provider never adopts the new target selection.
            with self.assertRaises(ForgeServerAdapterError): self.provider.resolve(request)

    def test_fresh_unpaired_binding_uses_exact_product_status_and_private_instance(self) -> None:
        binding = self.provider.resolve(self.request)
        expected = "sha256:" + sha256((json.dumps({
            "state": "NOT_CONFIGURED", "runtime_id": "forge-a",
        }, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()
        self.assertEqual(binding.peer_configuration_digest, expected)
        self.assertEqual(binding.runtime_root, self.root / "products/forge/forge-a")
        self.assertEqual(binding.resolver_sha256, "sha256:" + sha256(self.executable.read_bytes()).hexdigest())
        self.assertEqual(binding.intent_root, self.root / "state/forge-update-intents")
        self.assertEqual(self.runner.calls[-1][-2:], ("server", "status"))

    def test_exact_durable_intent_survives_adopted_resolver_and_rejects_drift(self) -> None:
        binding = self.provider.resolve(self.request)
        store = ForgeUpdateIntentStore(binding.intent_root)
        intent = store.prepare(ForgeUpdateIntent(
            self.request.operation_id, self.request.fingerprint(),
            self.target.instance_id, OLD.digest, NEW.digest,
            "forge-update-assess:sha256:" + "a" * 64,
            binding_snapshot=binding.durable_snapshot(),
        ))
        store.advance(intent, "UPDATER_INVOKED")
        legacy = binding.runtime_root / "legacy" / (
            binding.resolver_sha256.removeprefix("sha256:")[:16] + "-forge"
        )
        legacy.parent.mkdir(mode=0o700)
        legacy.write_bytes(self.executable.read_bytes())
        legacy.chmod(0o700)
        self.executable.unlink()
        self.executable.symlink_to(binding.runtime_root / "bin/forge")
        self.assertEqual(self.provider.resolve(self.request), binding)
        self.assertEqual(self.runner.calls[-1][0], str(legacy))
        legacy.write_bytes(b"changed")
        with self.assertRaisesRegex(ForgeServerAdapterError, "legacy resolver changed"):
            self.provider.resolve(self.request)
        legacy.write_bytes(b"#!/bin/sh\nexit 0\n")
        legacy.chmod(0o700)
        wrong = replace(self.provider, installation_id="other-installation")
        with self.assertRaisesRegex(ForgeServerAdapterError, "binding changed"):
            wrong.resolve(self.request)

    def test_wrong_target_candidate_and_unsafe_instance_root_fail_closed(self) -> None:
        wrong = replace(self.request, installation_identity="forge-b")
        with self.assertRaisesRegex(ForgeServerAdapterError, "selection is unavailable"):
            self.provider.resolve(wrong)
        wrong_candidate = replace(self.request, artifact=OLD)
        with self.assertRaisesRegex(ForgeServerAdapterError, "selection is unavailable"):
            self.provider.resolve(wrong_candidate)
        runtime = self.root / "products/forge/forge-a"
        runtime.chmod(0o755)
        with self.assertRaisesRegex(ForgeServerAdapterError, "runtime directory is unsafe"):
            self.provider.resolve(self.request)
        runtime.chmod(0o700)
        runtime.rmdir()
        outside = self.root / "outside"
        outside.mkdir(mode=0o700)
        runtime.symlink_to(outside)
        with self.assertRaisesRegex(ForgeServerAdapterError, "runtime directory is unsafe"):
            self.provider.resolve(self.request)

    def test_stale_product_status_and_peer_are_rejected(self) -> None:
        self.runner.version = NEW.version
        with self.assertRaisesRegex(ForgeServerAdapterError, "unpaired instance"):
            self.provider.resolve(self.request)
        self.runner.version = OLD.version
        self.runner.peer = {"status": "CONFIGURED", "live_status": "NOT_VERIFIED"}
        with self.assertRaisesRegex(ForgeServerAdapterError, "unpaired instance"):
            self.provider.resolve(self.request)

    def test_paired_digest_is_read_from_the_exact_product_owned_peer(self) -> None:
        digest = "sha256:" + "c" * 64
        self.runner.peer = {
            "status": "CONFIGURED", "live_status": "NOT_VERIFIED",
            "binding_id": "ep-primary", "ep_consumer_id": "consumer-a",
            "configuration_revision": 1, "configuration_digest": digest,
            "owning_forge_runtime_id": "forge-a",
        }
        paired = replace(
            self.provider, expected_pairing_binding_id="ep-primary",
            expected_ep_consumer_id="consumer-a",
        )
        self.assertEqual(paired.resolve(self.request).peer_configuration_digest, digest)
        self.runner.peer["ep_consumer_id"] = "consumer-b"
        with self.assertRaisesRegex(ForgeServerAdapterError, "peer configuration"):
            paired.resolve(self.request)


if __name__ == "__main__":
    unittest.main()
