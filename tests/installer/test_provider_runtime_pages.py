"""Provider Pages staging keeps the published managed-tool tree byte-exact."""
from __future__ import annotations

import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import prepare_managed_tool_pages as tools
import prepare_provider_runtime_pages as pages


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


class Response:
    def __init__(self, data: bytes, url: str, *, status: int = 200,
                 length: str | None = None):
        self.stream = io.BytesIO(data)
        self.url = url
        self.status = status
        self.headers = {"Content-Length": length or str(len(data))}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    def geturl(self):
        return self.url

    def read(self, count: int):
        return self.stream.read(count)


class ProviderRuntimePagesTests(unittest.TestCase):
    def test_module_imports_from_repository_root_like_protected_workflow(self):
        result = subprocess.run(
            [sys.executable, "-c",
             "from scripts.prepare_provider_runtime_pages import load_config; "
             "from pathlib import Path; "
             "assert load_config(Path('provider-runtime-pages.json'))['assets']"],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.assets = self.root / "provider-assets"
        self.assets.mkdir()
        self.output = self.root / "site"
        provider_paths = {
            "codex-runtime": "codex-0.157.1-arm64/forge-platform-provider-codex-0.157.1-arm64.tar.gz",
            "github-cli-runtime": "github-cli-2.101.0-arm64/forge-platform-provider-gh-2.101.0-arm64.tar.gz",
            "provider-provenance": "provider-runtime-provenance.json",
        }
        self.config = {
            "schema": pages.SCHEMA,
            "status": "REVIEWED_CANDIDATE",
            "release_tag": "forge-platform-provider-runtimes-v1",
            "preserved_managed_tool_tag": "forge-platform-managed-tools-v1",
            "preserved_managed_tool_marker_sha256": digest(b"old-marker"),
            "preserved_managed_tool_marker_size": len(b"old-marker"),
            "assets": [],
        }
        for kind, relative in provider_paths.items():
            payload = kind.encode()
            name = Path(relative).name
            (self.assets / name).write_bytes(payload)
            self.config["assets"].append({
                "kind": kind, "asset_name": name, "relative_path": relative,
                "url": pages.PREFIX + relative, "sha256": digest(payload),
                "size": len(payload),
            })
        self.config_path = self.root / "provider-config.json"
        tool_paths = {
            "managed-git-runtime": "git-2.56.0-arm64/forge-platform-managed-git.tar.gz",
            "managed-python-runtime": "python-3.14.7-arm64/forge-platform-managed-python-runtime.tar.gz",
            "cpython-source": "python-3.14.7-arm64/cpython-3.14.7-source.tar.gz",
            "source-provenance": "python-3.14.7-arm64/source-provenance.json",
            "build-provenance": "python-3.14.7-arm64/build-provenance.json",
            "git-corresponding-source": "git-2.56.0-arm64/git-corresponding-source.tar.gz",
        }
        self.old = {
            "schema": tools.SCHEMA, "status": "REVIEWED_CANDIDATE",
            "release_tag": "forge-platform-managed-tools-v1",
            "handoff_manifest_sha256": digest(b"handoff"), "assets": [],
        }
        self.old_bytes = {}
        old_assets = self.root / "old-assets"
        old_assets.mkdir()
        for kind, relative in tool_paths.items():
            payload = kind.encode()
            name = Path(relative).name
            self.old_bytes[tools.SITE_PREFIX + relative] = payload
            (old_assets / name).write_bytes(payload)
            self.old["assets"].append({
                "kind": kind, "asset_name": name, "relative_path": relative,
                "url": tools.SITE_PREFIX + relative, "sha256": digest(payload),
                "size": len(payload),
            })
        old_site = self.root / "old-site"
        tools.stage(self.old, old_assets, old_site)
        index = (old_site / "managed-tools/v1/git-2.56.0-arm64/index.html").read_bytes()
        self.old_bytes[tools.SITE_PREFIX + "git-2.56.0-arm64/index.html"] = index
        self.old_bytes[tools.SITE_PREFIX + "publication.json"] = b"old-marker"

    def write(self, value=None):
        self.config_path.write_text(json.dumps(self.config if value is None else value))
        return self.config_path

    def fake_fetch(self, url, size, expected, destination):
        payload = self.old_bytes[url]
        if size != len(payload) or expected != digest(payload):
            raise pages.PublicationError("preserved public asset bytes differ")
        destination.write_bytes(payload)

    def test_repository_candidate_binds_exact_private_artifacts(self):
        config = pages.load_config(ROOT / "provider-runtime-pages.json")
        self.assertEqual(config["release_tag"], "forge-platform-provider-runtimes-v1")
        self.assertEqual(len(config["assets"]), 3)
        provenance = ROOT / "provider-runtime-provenance.json"
        claim = next(a for a in config["assets"] if a["kind"] == "provider-provenance")
        self.assertEqual(tools._digest(provenance, claim["size"]), claim["sha256"])
        record = json.loads(provenance.read_text())
        self.assertEqual(record["schema"], "forge-platform.provider-runtime-provenance/v1")
        for item, role in zip(record["assets"], ("codex-runtime", "github-cli-runtime")):
            asset = next(a for a in config["assets"] if a["kind"] == role)
            self.assertEqual(item["normalized_sha256"], asset["sha256"])
            self.assertEqual(item["normalized_size"], asset["size"])
        for asset in config["assets"]:
            source = Path("/private/tmp/l1-provider-runtime-candidates/normalized") / asset["asset_name"]
            # Private candidate bytes are only checked when present locally;
            # protected CI independently checks the frozen JSON identity.
            if source.is_file():
                self.assertEqual(tools._digest(source, asset["size"]), asset["sha256"])

    def test_stages_old_site_and_new_exact_assets(self):
        with patch.object(pages, "fetch_exact", side_effect=self.fake_fetch):
            pages.stage(self.config, self.old, self.assets, self.output, "a" * 40, 123, 1)
        self.assertEqual((self.output / "managed-tools/v1/publication.json").read_bytes(),
                         b"old-marker")
        for asset in self.old["assets"]:
            path = self.output / "managed-tools/v1" / asset["relative_path"]
            self.assertEqual(path.read_bytes(), self.old_bytes[asset["url"]])
        for asset in self.config["assets"]:
            path = self.output / "provider-runtimes/v1" / asset["relative_path"]
            self.assertEqual(path.read_bytes(), asset["kind"].encode())
        marker = json.loads((self.output / "provider-runtimes/v1/publication.json").read_text())
        self.assertEqual(marker["source_sha"], "a" * 40)
        self.assertEqual(marker["github_run_id"], 123)
        self.assertEqual(marker["preserved_managed_tool_marker_sha256"], digest(b"old-marker"))

    def test_stage_rejects_context_and_byte_drift(self):
        for change in [
            {"preserved_managed_tool_tag": "wrong"},
        ]:
            altered = copy.deepcopy(self.config)
            altered.update(change)
            with self.subTest(change=change), self.assertRaises(pages.PublicationError):
                pages.stage(altered, self.old, self.assets, self.output, "a" * 40, 123, 1)
        with self.assertRaises(pages.PublicationError):
            pages.stage(self.config, self.old, self.assets, self.output, "bad", 123, 1)
        with self.assertRaises(pages.PublicationError):
            pages.stage(self.config, self.old, self.assets, self.output, "a" * 40, True, 1)
        with patch.object(pages, "fetch_exact", side_effect=self.fake_fetch):
            altered = copy.deepcopy(self.config)
            altered["assets"][0]["sha256"] = digest(b"different")
            with self.assertRaises(pages.PublicationError):
                pages.stage(altered, self.old, self.assets, self.output, "a" * 40, 123, 1)
        self.assertTrue(self.output.exists())

    def test_load_config_rejects_invalid_shapes_and_paths(self):
        self.assertEqual(pages.load_config(self.write()), self.config)
        changes = [
            lambda c: c.update(schema="wrong"),
            lambda c: c.update(status="PUBLISHED"),
            lambda c: c.update(release_tag="../tag"),
            lambda c: c.update(preserved_managed_tool_marker_sha256="bad"),
            lambda c: c.update(preserved_managed_tool_marker_size=True),
            lambda c: c["assets"].pop(),
            lambda c: c["assets"][1].update(kind=c["assets"][0]["kind"]),
            lambda c: c["assets"][0].update(asset_name=[]),
            lambda c: c["assets"][0].update(relative_path="../escape"),
            lambda c: c["assets"][0].update(url="https://wrong.invalid"),
            lambda c: c["assets"][0].update(sha256="bad"),
            lambda c: c["assets"][0].update(size=True),
            lambda c: c["assets"][0].update(extra="x"),
        ]
        for change in changes:
            altered = copy.deepcopy(self.config)
            change(altered)
            with self.subTest(change=change), self.assertRaises(pages.PublicationError):
                pages.load_config(self.write(altered))
        self.config_path.write_bytes(b'{"schema":1,"schema":2}')
        with self.assertRaises(pages.PublicationError):
            pages.load_config(self.config_path)
        self.config_path.write_bytes(b"\xff")
        with self.assertRaises(pages.PublicationError):
            pages.load_config(self.config_path)
        self.config_path.write_bytes(b" " * (64 * 1024 + 1))
        with self.assertRaises(pages.PublicationError):
            pages.load_config(self.config_path)
        link = self.root / "link"
        link.symlink_to(self.write())
        with self.assertRaises(pages.PublicationError):
            pages.load_config(link)

    def test_fetch_exact_rejects_status_redirect_length_and_digest(self):
        url = "https://example.test/archive"
        destination = self.root / "fetched"
        for response in [Response(b"ok", url, status=500),
                         Response(b"ok", "https://redirect.test/archive"),
                         Response(b"ok", url, length="3"),
                         Response(b"wrong", url, length="5"),
                         Response(b"long", url)]:
            with self.subTest(response=response), patch.object(
                pages.urllib.request, "build_opener"
            ) as opener:
                opener.return_value.open.return_value = response
                with self.assertRaises(pages.PublicationError):
                    pages.fetch_exact(url, 2, digest(b"ok"), destination)
                destination.unlink(missing_ok=True)
        with patch.object(pages.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = Response(b"ok", url)
            pages.fetch_exact(url, 2, digest(b"ok"), destination)
        self.assertEqual(destination.read_bytes(), b"ok")
        with self.assertRaises(pages.PublicationError):
            pages.fetch_exact(url, 2, digest(b"ok"), destination)

    def test_cli_blocks_invalid_config(self):
        self.config_path.write_bytes(b"{}")
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts/prepare_provider_runtime_pages.py"),
            "--config", str(self.config_path), "--tool-config", "managed-tool-pages.json",
            "--provider-assets", str(self.assets), "--output", str(self.output),
            "--source-sha", "a" * 40, "--run-id", "123", "--run-attempt", "1",
        ], capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PROVIDER_RUNTIME_PAGES=BLOCKED", result.stderr)

    def test_protected_workflow_rechecks_old_site_and_private_draft(self):
        workflow = (ROOT / ".github/workflows/forge-platform-provider-runtime-pages.yml").read_text()
        review = workflow.split("\n  review:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertIn("github.ref_protected", review)
        self.assertIn("github.workflow_sha == inputs.source_sha", review)
        self.assertIn("contents: write", review)
        self.assertIn("verify_managed_tool_pages.py", review)
        self.assertIn("provider public path already exists", review)
        self.assertIn("validate_backing_release", review)
        self.assertIn("provider release or preserved tool binding differs", review)
        self.assertIn("staged managed-tool byte changed", workflow)
        self.assertIn("staged provider byte changed", workflow)
        self.assertIn("provider release assets changed during readback", workflow)
        self.assertIn("validate_release_tag_binding(False", workflow)
