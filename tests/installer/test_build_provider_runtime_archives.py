"""Pinned upstream provider bytes rebuild the reviewed installer layout."""
from __future__ import annotations

import copy
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import build_provider_runtime_archives as builder


class ProviderRuntimeArchiveBuildTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        codex = b"signed codex binary"
        gh = b"signed github cli binary"
        codex_license = b"Codex license\n"
        gh_license = b"GitHub CLI license\n"
        self.codex_archive = self.root / "codex.tar.gz"
        source = io.BytesIO()
        with tarfile.open(fileobj=source, mode="w:gz") as archive:
            item = tarfile.TarInfo("codex-aarch64-apple-darwin")
            item.size = len(codex)
            archive.addfile(item, io.BytesIO(codex))
        self.codex_archive.write_bytes(source.getvalue())
        self.codex_license = self.root / "codex-license"
        self.codex_license.write_bytes(codex_license)
        self.gh_archive = self.root / "gh.zip"
        source = io.BytesIO()
        with zipfile.ZipFile(source, mode="w") as archive:
            archive.writestr("gh_2.101.0_macOS_arm64/bin/gh", gh)
            archive.writestr("gh_2.101.0_macOS_arm64/LICENSE", gh_license)
        self.gh_archive.write_bytes(source.getvalue())
        self.record = {
            "schema": builder.SCHEMA,
            "assets": [
                self.asset("codex", self.codex_archive.read_bytes(), codex,
                           codex_license, "codex"),
                self.asset("github-cli", self.gh_archive.read_bytes(), gh,
                           gh_license, "gh"),
            ],
        }
        self.provenance = self.root / "provenance.json"
        self.write_record()
        self.output = self.root / "output"

    @staticmethod
    def asset(provider, archive, binary, license_bytes, executable):
        normalized = builder.repack(binary, license_bytes, executable)
        return {
            "provider": provider,
            "upstream_archive_sha256": builder.digest(archive),
            "executable_sha256": builder.digest(binary),
            "license_sha256": builder.digest(license_bytes),
            "executable_path": "bin/" + executable,
            "normalized_asset": (
                "forge-platform-provider-codex-0.157.1-arm64.tar.gz"
                if provider == "codex" else
                "forge-platform-provider-gh-2.101.0-arm64.tar.gz"
            ),
            "normalized_sha256": builder.digest(normalized),
            "normalized_size": len(normalized),
        }

    def write_record(self):
        self.provenance.write_text(json.dumps(self.record) + "\n")

    def build(self):
        builder.build(self.codex_archive, self.codex_license, self.gh_archive,
                      self.provenance, self.output)

    def test_exact_rebuild_is_deterministic_and_cannot_overwrite(self):
        self.build()
        for item in self.record["assets"]:
            data = (self.output / item["normalized_asset"]).read_bytes()
            self.assertEqual(builder.digest(data), item["normalized_sha256"])
            self.assertEqual(len(data), item["normalized_size"])
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
                self.assertEqual(archive.getnames(), ["bin", item["executable_path"], "LICENSE"])
        self.assertEqual((self.output / "provider-runtime-provenance.json").read_bytes(),
                         self.provenance.read_bytes())
        with self.assertRaises(builder.BuildError):
            self.build()
        second = self.root / "second"
        builder.build(self.codex_archive, self.codex_license, self.gh_archive,
                      self.provenance, second)
        for item in self.record["assets"]:
            self.assertEqual((second / item["normalized_asset"]).read_bytes(),
                             (self.output / item["normalized_asset"]).read_bytes())

    def test_rejects_upstream_executable_license_and_normalized_drift(self):
        for field in ("upstream_archive_sha256", "executable_sha256",
                      "license_sha256", "normalized_sha256", "normalized_size",
                      "executable_path", "normalized_asset"):
            original = copy.deepcopy(self.record)
            self.record["assets"][0][field] = "bad" if field != "normalized_size" else 1
            self.write_record()
            with self.subTest(field=field), self.assertRaises(builder.BuildError):
                self.build()
            self.assertFalse(self.output.exists())
            self.record = original
        self.codex_license.write_bytes(b"different")
        self.write_record()
        with self.assertRaises(builder.BuildError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_rejects_symlink_invalid_provenance_and_archive_layout(self):
        link = self.root / "link"
        link.symlink_to(self.codex_archive)
        with self.assertRaises(builder.BuildError):
            builder.build(link, self.codex_license, self.gh_archive,
                          self.provenance, self.output)
        self.assertFalse(self.output.exists())
        self.record["assets"].reverse()
        self.write_record()
        with self.assertRaises(builder.BuildError):
            self.build()
        self.record["assets"].reverse()
        self.write_record()
        raw = self.gh_archive.read_bytes()
        with zipfile.ZipFile(self.gh_archive, mode="a") as archive:
            archive.writestr("gh_2.101.0_macOS_arm64/bin/gh", b"duplicate")
        self.record["assets"][1]["upstream_archive_sha256"] = builder.digest(
            self.gh_archive.read_bytes())
        self.write_record()
        with self.assertRaises(builder.BuildError):
            self.build()
        self.assertFalse(self.output.exists())
        self.gh_archive.write_bytes(raw)

    def test_rejects_missing_github_license(self):
        source = io.BytesIO()
        with zipfile.ZipFile(source, mode="w") as archive:
            archive.writestr("gh_2.101.0_macOS_arm64/bin/gh", b"signed github cli binary")
        self.gh_archive.write_bytes(source.getvalue())
        self.record["assets"][1]["upstream_archive_sha256"] = builder.digest(source.getvalue())
        self.write_record()
        with self.assertRaises(builder.BuildError):
            self.build()

    def test_repository_provenance_matches_normalized_output(self):
        record, raw = builder.load_provenance(ROOT / "provider-runtime-provenance.json")
        self.assertEqual(record["schema"], builder.SCHEMA)
        self.assertEqual(raw, (ROOT / "provider-runtime-provenance.json").read_bytes())
        self.assertEqual([item["provider"] for item in record["assets"]],
                         ["codex", "github-cli"])
