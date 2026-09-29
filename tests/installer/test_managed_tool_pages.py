"""The protected Pages stage accepts only the five exact reviewed bytes."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts import prepare_managed_tool_pages as pages


class ManagedToolPagesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.output = self.root / "site"
        paths = {
            "managed-git-runtime": "git-2.56.0-arm64/forge-platform-managed-git.tar.gz",
            "managed-python-runtime": "python-3.14.7-arm64/forge-platform-managed-python-runtime.tar.gz",
            "cpython-source": "python-3.14.7-arm64/cpython-3.14.7-source.tar.gz",
            "source-provenance": "python-3.14.7-arm64/source-provenance.json",
            "build-provenance": "python-3.14.7-arm64/build-provenance.json",
            "git-corresponding-source": "git-2.56.0-arm64/git-corresponding-source.tar.gz",
        }
        self.config = {
            "schema": pages.SCHEMA,
            "status": "REVIEWED_CANDIDATE",
            "release_tag": "forge-platform-managed-tools-v1",
            "handoff_manifest_sha256": "sha256:" + "a" * 64,
            "assets": [],
        }
        for kind, relative in paths.items():
            name = Path(relative).name
            payload = kind.encode("ascii")
            (self.assets / name).write_bytes(payload)
            self.config["assets"].append({
                "kind": kind,
                "asset_name": name,
                "relative_path": relative,
                "url": pages.SITE_PREFIX + relative,
                "sha256": "sha256:" + hashlib.sha256(payload).hexdigest(),
                "size": len(payload),
            })
        self.config_path = self.root / "config.json"

    def write_config(self, config: dict | None = None) -> Path:
        self.config_path.write_text(json.dumps(config if config is not None else self.config))
        return self.config_path

    def test_reviewed_repository_config_matches_final_local_handoff(self) -> None:
        config = pages.load_config(ROOT / "managed-tool-pages.json")
        self.assertEqual(config["handoff_manifest_sha256"],
                         "sha256:f1a343c531812af6560b773800998394958a70a97796d3bdd768a32000f02f79")
        self.assertEqual(len(config["assets"]), 6)

    def test_stages_exact_tree_and_rechecks_bytes(self) -> None:
        pages.stage(pages.load_config(self.write_config()), self.assets, self.output)
        self.assertTrue((self.output / ".nojekyll").is_file())
        for asset in self.config["assets"]:
            staged = self.output / "managed-tools" / "v1" / asset["relative_path"]
            self.assertEqual(staged.read_bytes(), (self.assets / asset["asset_name"]).read_bytes())
        index = (self.output / "managed-tools" / "v1" / "git-2.56.0-arm64" / "index.html").read_text()
        self.assertIn("git-corresponding-source.tar.gz", index)
        self.assertIn("GPL-2.0", index)
        with self.assertRaises(pages.PublicationError):
            pages.stage(self.config, self.assets, self.output)

    def test_unconfigured_and_extra_claims_block(self) -> None:
        config = copy.deepcopy(self.config)
        config.update(status="UNCONFIGURED", release_tag=None,
                      handoff_manifest_sha256=None, assets=[])
        with self.assertRaisesRegex(pages.PublicationError, "unconfigured"):
            pages.load_config(self.write_config(config))
        config["release_tag"] = "forge-platform-managed-tools-v1"
        with self.assertRaisesRegex(pages.PublicationError, "asset claims"):
            pages.load_config(self.write_config(config))

    def test_rejects_duplicate_json_keys_and_invalid_utf8(self) -> None:
        self.config_path.write_bytes(b'{"schema":1,"schema":2}')
        with self.assertRaisesRegex(pages.PublicationError, "duplicate"):
            pages.load_config(self.config_path)
        self.config_path.write_bytes(b"\xff")
        with self.assertRaisesRegex(pages.PublicationError, "UTF-8"):
            pages.load_config(self.config_path)

    def test_rejects_malformed_config_and_claims(self) -> None:
        cases = [
            (lambda c: c.update(schema="wrong"), "schema"),
            (lambda c: c.update(status="PENDING"), "status"),
            (lambda c: c.update(release_tag="../wrong"), "tag"),
            (lambda c: c.update(handoff_manifest_sha256="sha256:0"), "inventory"),
            (lambda c: c["assets"].pop(), "five"),
            (lambda c: c["assets"][1].update(kind=c["assets"][0]["kind"]), "duplicated"),
            (lambda c: c["assets"][0].update(relative_path="../git.tar.gz"), "path"),
            (lambda c: c["assets"][0].update(url="https://wrong.invalid/"), "URL"),
            (lambda c: c["assets"][0].update(sha256="sha256:0"), "digest"),
            (lambda c: c["assets"][0].update(size=True), "size"),
            (lambda c: c["assets"][0].update(extra="x"), "fields"),
            (lambda c: c["assets"][-1].update(
                relative_path="git-2.55.0-arm64/git-corresponding-source.tar.gz",
                url=pages.SITE_PREFIX + "git-2.55.0-arm64/git-corresponding-source.tar.gz"), "versions"),
        ]
        for mutate, reason in cases:
            with self.subTest(reason=reason):
                config = copy.deepcopy(self.config)
                mutate(config)
                with self.assertRaisesRegex(pages.PublicationError, reason):
                    pages.load_config(self.write_config(config))

    def test_rejects_oversized_config_and_symlink(self) -> None:
        self.config_path.write_bytes(b" " * (pages.MAXIMUM_DOCUMENT_BYTES + 1))
        with self.assertRaisesRegex(pages.PublicationError, "size"):
            pages.load_config(self.config_path)
        link = self.root / "link.json"
        link.symlink_to(self.write_config())
        with self.assertRaisesRegex(pages.PublicationError, "regular"):
            pages.load_config(link)

    def test_rejects_source_digest_size_hardlink_and_symlink(self) -> None:
        config = pages.load_config(self.write_config())
        source = self.assets / config["assets"][0]["asset_name"]
        source.write_bytes(b"wrong payload")
        with self.assertRaisesRegex(pages.PublicationError, "regular"):
            pages.stage(config, self.assets, self.output)
        source.write_bytes(b"x" * config["assets"][0]["size"])
        with self.assertRaisesRegex(pages.PublicationError, "digest"):
            pages.stage(config, self.assets, self.output)
        source.write_bytes(config["assets"][0]["kind"].encode())
        alias = self.root / "hardlink"
        alias.hardlink_to(source)
        with self.assertRaisesRegex(pages.PublicationError, "regular"):
            pages.stage(config, self.assets, self.output)
        alias.unlink()
        source.rename(alias)
        source.symlink_to(alias)
        with self.assertRaisesRegex(pages.PublicationError, "regular"):
            pages.stage(config, self.assets, self.output)

    def test_cli_fails_closed_without_creating_site(self) -> None:
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts/prepare_managed_tool_pages.py"),
            "--config", str(self.write_config()),
            "--assets-root", str(self.assets / "missing"),
            "--output", str(self.output),
        ], capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MANAGED_TOOL_PAGES=BLOCKED", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
