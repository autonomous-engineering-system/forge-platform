"""Exact reviewed three-topology inputs for the first signed catalog."""
from __future__ import annotations

from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from forge_platform.universal_installer import CompositionManifest
from scripts.prepare_composition_catalog_candidate import prepare_many


ROOT = Path(__file__).resolve().parents[2]
COMPOSITIONS = ROOT / "compositions"
IDENTITIES = (
    "ep-only-2.3.106",
    "forge-ep-2.7.39-2.3.106",
    "forge-only-2.7.39",
)
SOURCE_SHA = "d39fc483173d2d5ef92bde72130caafa3b8575d1"
REPORT_DIGEST = "sha256:2d472b5f3a4e270d99cacb91e9fda2287dbc45f8c17f560ac5d1a240ca31bd6d"


class ProductionCompositionTests(unittest.TestCase):
    def manifests(self) -> tuple[tuple[Path, str], ...]:
        return tuple((COMPOSITIONS / f"{identity}.json", f"ForgePlatformComposition-1-{index}.json")
                     for index, identity in enumerate(IDENTITIES, 1))

    def test_exact_three_topologies_and_immutable_producer_inputs(self) -> None:
        index = json.loads((COMPOSITIONS / "component-combination-catalog-v1.json").read_bytes())
        self.assertEqual([item["composition_id"] for item in index["compositions"]], list(IDENTITIES))
        self.assertEqual(index["sequence"], 1)
        installer = json.loads((ROOT / "installer-version.json").read_bytes())
        for (path, asset), entry in zip(self.manifests(), index["compositions"], strict=True):
            raw = path.read_bytes()
            digest = "sha256:" + sha256(raw).hexdigest()
            self.assertEqual(entry["manifest"]["digest"], digest)
            self.assertTrue(entry["manifest"]["url"].endswith("/" + asset))
            manifest = CompositionManifest.from_digest_bound_bytes(raw, manifest_digest=digest)
            self.assertEqual(manifest.composition_id, entry["composition_id"])
            self.assertEqual(manifest.installer_requirement.minimum_version.major, 0)
            self.assertEqual(manifest.installer_requirement.minimum_version.minor, 3)
            self.assertTrue(manifest.installer_requirement.capabilities <= frozenset(installer["capabilities"]))
            self.assertEqual({item.identity for item in manifest.components},
                             {item["identity"] for item in entry["components"]})
            self.assertEqual(len(manifest.providers), 2 * len(manifest.components))
            self.assertEqual({provider.target_identity for provider in manifest.providers}, {"selected-deployment"})
            self.assertEqual({component.python_runtime_qualification.test_evidence.digest
                              for component in manifest.components}, {REPORT_DIGEST})
            self.assertEqual(manifest.python_runtime.identity_digest,
                             "sha256:519d7975f16e78f808403188b3a8417bab10af000208ef1ec82c42bccfa94ceb")
            for component in manifest.components:
                if component.identity == "forge-runtime":
                    self.assertEqual(component.artifact.version, "2.7.39")
                    self.assertEqual(component.artifact.source_revision, "ebc43dc12da27353f85c991a26da9852aa790f05")
                    self.assertEqual(component.artifact.digest,
                                     "sha256:b62bf5f7a1d937f5224ef941a3dea3e961d28b67d9206fd89b644153aea502f1")
                else:
                    self.assertEqual(component.artifact.version, "2.3.106")
                    self.assertEqual(component.artifact.source_revision, "7b99b578153ae5d72372a09db194306b49ec9f9c")
                    self.assertEqual(component.artifact.digest,
                                     "sha256:9d25a53d75b61d43d665d9f8290a968dc3e63d12d2037eae8ef31ee810eb6694")

    def test_candidate_preparation_binds_all_three_exact_assets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = prepare_many(
                manifests=self.manifests(),
                index_path=COMPOSITIONS / "component-combination-catalog-v1.json",
                output_directory=Path(temporary) / "candidate",
                source_sha=SOURCE_SHA, sequence=1,
                published_at="2026-10-01T08:30:00Z",
                expires_at="2026-11-01T08:30:00Z",
                index_asset_name="ForgePlatformComponentCombinationCatalog-1.json",
                key_ids=("forge-platform-composition-catalog-2026-01",),
            )
            self.assertEqual(len(result["manifests"]), 3)
            self.assertEqual([item["composition_id"] for item in result["manifests"]], list(IDENTITIES))
            for path, asset in self.manifests():
                self.assertEqual((Path(temporary) / "candidate" / asset).read_bytes(), path.read_bytes())

    def test_sequence_two_scopes_github_to_ep_only(self) -> None:
        paths = (
            COMPOSITIONS / "ep-only-2.3.106.json",
            COMPOSITIONS / "forge-ep-2.7.39-2.3.106-v2.json",
            COMPOSITIONS / "forge-only-2.7.39-v2.json",
        )
        index = json.loads((COMPOSITIONS / "component-combination-catalog-v2.json").read_bytes())
        self.assertEqual(index["sequence"], 2)
        self.assertEqual([entry["composition_id"] for entry in index["compositions"]], list(IDENTITIES))
        expected = (
            {("codex", "engineering-platform-server"), ("github-cli", "engineering-platform-server")},
            {("codex", "engineering-platform-server"), ("github-cli", "engineering-platform-server"),
             ("codex", "forge-runtime")},
            {("codex", "forge-runtime")},
        )
        manifests = []
        for number, (path, entry, providers) in enumerate(zip(paths, index["compositions"], expected, strict=True), 1):
            raw = path.read_bytes()
            digest = "sha256:" + sha256(raw).hexdigest()
            self.assertEqual(entry["manifest"]["digest"], digest)
            self.assertTrue(entry["manifest"]["url"].endswith(
                f"/forge-platform-composition-catalog-v2/ForgePlatformComposition-2-{number}.json"
            ))
            manifest = CompositionManifest.from_digest_bound_bytes(raw, manifest_digest=digest)
            self.assertEqual(manifest.composition_id, entry["composition_id"])
            self.assertEqual(
                {(item["identity"], item["owner_component"]) for item in json.loads(raw)["providers"]},
                providers,
            )
            self.assertEqual(entry["selection_sequence"], 2)
            manifests.append((path, f"ForgePlatformComposition-2-{number}.json"))
        with tempfile.TemporaryDirectory() as temporary:
            result = prepare_many(
                manifests=tuple(manifests),
                index_path=COMPOSITIONS / "component-combination-catalog-v2.json",
                output_directory=Path(temporary) / "candidate",
                source_sha=SOURCE_SHA, sequence=2,
                published_at="2026-10-04T19:40:00Z",
                expires_at="2026-11-03T19:40:00Z",
                index_asset_name="ForgePlatformComponentCombinationCatalog-2.json",
                key_ids=("forge-platform-composition-catalog-2026-01",),
            )
            self.assertEqual(len(result["manifests"]), 3)

    def test_catalog_tools_run_directly_without_pythonpath(self) -> None:
        env = dict(os.environ)
        env.pop("PYTHONPATH", None)
        for script in ("prepare_composition_catalog_candidate.py", "finalize_signed_composition_catalog.py"):
            completed = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / script), "--help"],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
