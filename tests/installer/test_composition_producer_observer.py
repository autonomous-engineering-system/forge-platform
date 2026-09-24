#!/usr/bin/env python3
from __future__ import annotations

from hashlib import sha256
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "observe_composition_producer_releases.py"
WORKFLOW = ROOT / ".github" / "workflows" / "forge-platform-composition-producer-observer.yml"

spec = importlib.util.spec_from_file_location("observe_composition_producer_releases", SCRIPT)
assert spec is not None and spec.loader is not None
OBSERVER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(OBSERVER)


def canonical(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    ).encode("utf-8")


class FakeFetch:
    def __init__(self, documents: dict[str, bytes]):
        self.documents = documents
        self.requests: list[str] = []

    def __call__(self, url: str) -> bytes:
        self.requests.append(url)
        if url not in self.documents:
            raise OBSERVER.PublicEvidenceNotFound("public evidence does not exist")
        return self.documents[url]


class CompositionProducerObserverTests(unittest.TestCase):
    observed_at = "2026-09-24T14:00:00Z"

    def producer(
        self,
        *,
        identity: str,
        repository: str,
        prefix: str,
        product: str,
        component: str,
        project: str | None,
        registry: str,
        eligible: bool,
    ) -> dict[str, object]:
        return {
            "identity": identity,
            "repository": repository,
            "tag_prefix": prefix + "v",
            "receipt_asset_prefix": prefix + "release-complete-",
            "product": product,
            "component": component,
            "registry": registry,
            "pypi_project": project,
            "composition_eligible": eligible,
        }

    def config(self, *, external: list[dict[str, object]] | None = None) -> dict[str, object]:
        return {
            "schema": OBSERVER.CONFIG_SCHEMA,
            "producers": [
                self.producer(
                    identity="engineering-platform-server",
                    repository="pcvantol/engineering-platform",
                    prefix="engineering-platform-",
                    product="engineering-platform",
                    component="server",
                    project="engineering-platform",
                    registry="pypi",
                    eligible=True,
                ),
                self.producer(
                    identity="forge-runtime",
                    repository="pcvantol/forge",
                    prefix="forge-",
                    product="forge",
                    component="forge-autonomy",
                    project="forge-autonomy",
                    registry="pypi",
                    eligible=True,
                ),
                self.producer(
                    identity="workspace-server-client",
                    repository="pcvantol/workspace",
                    prefix="workspace-",
                    product="workspace",
                    component="source-bundle",
                    project=None,
                    registry="github-release",
                    eligible=False,
                ),
            ],
            "external_inputs": external
            if external is not None
            else [
                {"identity": "managed-git", "status": "UNCONFIGURED", "evidence": None},
                {
                    "identity": "managed-python-runtime",
                    "status": "UNCONFIGURED",
                    "evidence": None,
                },
            ],
        }

    def add_pypi_release(
        self,
        documents: dict[str, bytes],
        *,
        repository: str,
        tag_prefix: str,
        receipt_prefix: str,
        product: str,
        component: str,
        project: str,
        version: str,
        source: str,
    ) -> None:
        wheel = "sha256:" + ("a" if product == "forge" else "b") * 64
        sdist = "sha256:" + ("c" if product == "forge" else "d") * 64
        normalized = project.replace("-", "_")
        wheel_name = f"{normalized}-{version}-py3-none-any.whl"
        sdist_name = f"{normalized}-{version}.tar.gz"
        tag = tag_prefix + version
        receipt_name = f"{receipt_prefix}{version}-{source}.json"
        receipt_url = f"https://github.com/{repository}/releases/download/{tag}/{receipt_name}"
        receipt = {
            "operation_id": f"release-{version}-{source}",
            "product": product,
            "component": component,
            "version": version,
            "policy_revision": "production-release-v1",
            "source_revision": source,
            "artifacts": {"wheel": wheel, "sdist": sdist},
            "state": "RELEASE_COMPLETE",
            "qualification": {"exact_main_sha": source, "qualification": "qualified"},
            "publication_receipt": {
                "registry": "pypi",
                "readback": "PASS",
                "observed_artifact_digests": {wheel_name: wheel, sdist_name: sdist},
            },
            "cleanup": {"result": "COMPLETE"},
        }
        receipt_raw = canonical(receipt)
        release = {
            "tag_name": tag,
            "target_commitish": source,
            "draft": False,
            "prerelease": False,
            "html_url": f"https://github.com/{repository}/releases/tag/{tag}",
            "assets": [
                {
                    "name": receipt_name,
                    "digest": "sha256:" + sha256(receipt_raw).hexdigest(),
                    "browser_download_url": receipt_url,
                }
            ],
        }
        pypi = {
            "info": {"name": project, "version": version},
            "urls": [
                {
                    "packagetype": "bdist_wheel",
                    "filename": wheel_name,
                    "url": f"https://files.pythonhosted.org/{wheel_name}",
                    "digests": {"sha256": wheel.removeprefix("sha256:")},
                },
                {
                    "packagetype": "sdist",
                    "filename": sdist_name,
                    "url": f"https://files.pythonhosted.org/{sdist_name}",
                    "digests": {"sha256": sdist.removeprefix("sha256:")},
                },
            ],
        }
        documents[f"https://api.github.com/repos/{repository}/releases/latest"] = canonical(release)
        documents[receipt_url] = receipt_raw
        documents[f"https://pypi.org/pypi/{project}/{version}/json"] = canonical(pypi)

    def add_workspace_release(self, documents: dict[str, bytes]) -> None:
        repository = "pcvantol/workspace"
        version = "2.3.0"
        source = "e" * 40
        tag = f"workspace-v{version}"
        bundle_name = f"workspace-{version}-{source}.tar.gz"
        bundle_digest = "sha256:" + "f" * 64
        receipt_name = f"workspace-release-complete-{version}-{source}.json"
        receipt_url = f"https://github.com/{repository}/releases/download/{tag}/{receipt_name}"
        receipt = {
            "operation_id": f"workspace-release-{version}-{source}",
            "product": "workspace",
            "component": "source-bundle",
            "version": version,
            "policy_revision": "workspace-production-release-v2",
            "source_revision": source,
            "artifacts": {"source_bundle": bundle_digest},
            "state": "RELEASE_COMPLETE",
            "qualification": {"exact_main_sha": source, "qualification": "foundation"},
            "publication_receipt": {
                "registry": "github-release",
                "tag": tag,
                "artifact_name": bundle_name,
                "source_revision": source,
                "observed_artifact_digests": {"source_bundle": bundle_digest},
                "readback": "PASS",
            },
            "cleanup": {"result": "COMPLETE"},
        }
        receipt_raw = canonical(receipt)
        base = f"https://github.com/{repository}/releases/download/{tag}"
        release = {
            "tag_name": tag,
            "target_commitish": source,
            "draft": False,
            "prerelease": False,
            "html_url": f"https://github.com/{repository}/releases/tag/{tag}",
            "assets": [
                {
                    "name": receipt_name,
                    "digest": "sha256:" + sha256(receipt_raw).hexdigest(),
                    "browser_download_url": receipt_url,
                },
                {
                    "name": bundle_name,
                    "digest": bundle_digest,
                    "browser_download_url": f"{base}/{bundle_name}",
                },
            ],
        }
        documents[f"https://api.github.com/repos/{repository}/releases/latest"] = canonical(release)
        documents[receipt_url] = receipt_raw

    def inputs(self) -> tuple[dict[str, object], dict[str, bytes]]:
        config = self.config()
        documents: dict[str, bytes] = {}
        self.add_pypi_release(
            documents,
            repository="pcvantol/engineering-platform",
            tag_prefix="engineering-platform-v",
            receipt_prefix="engineering-platform-release-complete-",
            product="engineering-platform",
            component="server",
            project="engineering-platform",
            version="2.3.102",
            source="b" * 40,
        )
        self.add_pypi_release(
            documents,
            repository="pcvantol/forge",
            tag_prefix="forge-v",
            receipt_prefix="forge-release-complete-",
            product="forge",
            component="forge-autonomy",
            project="forge-autonomy",
            version="2.7.34",
            source="a" * 40,
        )
        return config, documents

    def write_config(self, root: Path, config: dict[str, object]) -> Path:
        path = root / "sources.json"
        path.write_bytes(canonical(config))
        return path

    def test_valid_forge_ep_and_missing_workspace_are_reported_fail_closed(self) -> None:
        config, documents = self.inputs()
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary), config)
            report = OBSERVER.observe(
                config_path=path, observed_at=self.observed_at, fetch=FakeFetch(documents)
            )
        self.assertEqual(report["status"], "BLOCKED")
        self.assertEqual(report["manifest_generation"], "BLOCKED")
        by_identity = {item["identity"]: item for item in report["producer_observations"]}
        self.assertEqual(by_identity["forge-runtime"]["version"], "2.7.34")
        self.assertEqual(by_identity["engineering-platform-server"]["version"], "2.3.102")
        self.assertEqual(by_identity["workspace-server-client"]["status"], "NO_PUBLIC_RELEASE")
        self.assertEqual(
            report["blockers"],
            [
                "managed-git:UNCONFIGURED",
                "managed-python-runtime:UNCONFIGURED",
                "workspace-server-client:NO_PUBLIC_RELEASE",
            ],
        )

    def test_workspace_source_bundle_is_observed_but_not_installable(self) -> None:
        config, documents = self.inputs()
        self.add_workspace_release(documents)
        with tempfile.TemporaryDirectory() as temporary:
            report = OBSERVER.observe(
                config_path=self.write_config(Path(temporary), config),
                observed_at=self.observed_at,
                fetch=FakeFetch(documents),
            )
        workspace = report["producer_observations"][2]
        self.assertEqual(workspace["status"], "OBSERVED_NOT_INSTALLABLE")
        self.assertEqual(workspace["artifacts"][0]["kind"], "source-bundle")
        self.assertIn("workspace-server-client:OBSERVED_NOT_INSTALLABLE", report["blockers"])

    def test_receipt_digest_and_source_drift_are_errors(self) -> None:
        config, documents = self.inputs()
        release_url = "https://api.github.com/repos/pcvantol/forge/releases/latest"
        release = json.loads(documents[release_url])
        release["assets"][0]["digest"] = "sha256:" + "0" * 64
        documents[release_url] = canonical(release)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(OBSERVER.ObservationError, "receipt bytes"):
                OBSERVER.observe(
                    config_path=self.write_config(Path(temporary), config),
                    observed_at=self.observed_at,
                    fetch=FakeFetch(documents),
                )

        config, documents = self.inputs()
        release = json.loads(documents[release_url])
        receipt_url = release["assets"][0]["browser_download_url"]
        del documents[receipt_url]
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(OBSERVER.PublicEvidenceNotFound, "does not exist"):
                OBSERVER.observe(
                    config_path=self.write_config(Path(temporary), config),
                    observed_at=self.observed_at,
                    fetch=FakeFetch(documents),
                )

        config, documents = self.inputs()
        release = json.loads(documents[release_url])
        release["target_commitish"] = "f" * 40
        documents[release_url] = canonical(release)
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(OBSERVER.ObservationError, "terminal receipt"):
                OBSERVER.observe(
                    config_path=self.write_config(Path(temporary), config),
                    observed_at=self.observed_at,
                    fetch=FakeFetch(documents),
                )

    def test_ready_external_input_requires_public_digest_readback(self) -> None:
        raw = b"immutable-runtime"
        url = "https://github.com/example/runtime/releases/download/v1/runtime.tar.gz"
        external = {
            "identity": "managed-git",
            "status": "READY",
            "evidence": {
                "identity_digest": "sha256:" + "1" * 64,
                "artifacts": [
                    {"kind": "archive", "url": url, "digest": "sha256:" + sha256(raw).hexdigest()}
                ],
            },
        }
        validated = OBSERVER._external_config(external)
        self.assertEqual(
            OBSERVER._observe_external(validated, FakeFetch({url: raw}))["status"], "READY"
        )
        with self.assertRaisesRegex(OBSERVER.ObservationError, "digest drifted"):
            OBSERVER._observe_external(validated, FakeFetch({url: b"changed"}))

    def test_configuration_timestamp_and_cli_fail_closed(self) -> None:
        config, documents = self.inputs()
        config["producers"] = list(reversed(config["producers"]))
        with tempfile.TemporaryDirectory() as temporary:
            path = self.write_config(Path(temporary), config)
            with self.assertRaisesRegex(OBSERVER.ObservationError, "unique and sorted"):
                OBSERVER.observe(config_path=path, observed_at=self.observed_at, fetch=FakeFetch(documents))
            self.assertEqual(
                OBSERVER.main(["--config", str(path), "--observed-at", "invalid", "--output", str(Path(temporary) / "out.json")]),
                1,
            )

    def test_cli_writes_canonical_report(self) -> None:
        report = {
            "schema": OBSERVER.SCHEMA,
            "observed_at": self.observed_at,
            "configuration_digest": "sha256:" + "0" * 64,
            "producer_observations": [],
            "external_input_observations": [],
            "blockers": [],
            "manifest_generation": "READY_FOR_REVIEW",
            "status": "READY",
        }
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "nested" / "report.json"
            with patch.object(OBSERVER, "observe", return_value=report):
                self.assertEqual(
                    OBSERVER.main(
                        ["--config", "unused.json", "--observed-at", self.observed_at, "--output", str(output)]
                    ),
                    0,
                )
            self.assertEqual(output.read_bytes(), canonical(report))

    def test_workflow_is_scheduled_read_only_and_github_hosted(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("schedule:", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn("runs-on: ubuntu-24.04", workflow)
        self.assertIn("observe_composition_producer_releases.py", workflow)
        self.assertIn("actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("pull-requests: write", workflow)
        self.assertNotIn("forge-platform-build", workflow)
        self.assertNotIn("secrets.", workflow)

    def test_network_fetch_and_strict_parsers_fail_closed(self) -> None:
        class Response:
            def __init__(self, raw: bytes):
                self.raw = raw

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, limit: int) -> bytes:
                return self.raw[:limit]

        with patch.dict(os.environ, {"GITHUB_TOKEN": "test-token"}), patch.object(
            OBSERVER, "urlopen", return_value=Response(b"{}")
        ):
            self.assertEqual(OBSERVER._network_fetch("https://api.github.com/repos/a/b"), b"{}")
        missing = OBSERVER.HTTPError("https://example.test", 404, "missing", {}, io.BytesIO())
        with patch.object(
            OBSERVER,
            "urlopen",
            side_effect=missing,
        ):
            with self.assertRaises(OBSERVER.PublicEvidenceNotFound):
                OBSERVER._network_fetch("https://example.test")
        missing.close()
        failed = OBSERVER.HTTPError("https://example.test", 500, "error", {}, io.BytesIO())
        with patch.object(
            OBSERVER,
            "urlopen",
            side_effect=failed,
        ):
            with self.assertRaisesRegex(OBSERVER.ObservationError, "HTTP 500"):
                OBSERVER._network_fetch("https://example.test")
        failed.close()
        with patch.object(OBSERVER, "urlopen", side_effect=OBSERVER.URLError("offline")):
            with self.assertRaisesRegex(OBSERVER.ObservationError, "transport failed"):
                OBSERVER._network_fetch("https://example.test")
        with patch.object(
            OBSERVER, "urlopen", return_value=Response(b"x" * (OBSERVER.MAXIMUM_DOCUMENT_BYTES + 1))
        ):
            with self.assertRaisesRegex(OBSERVER.ObservationError, "document boundary"):
                OBSERVER._network_fetch("https://example.test")
        for raw in (b'{"a":1,"a":2}', b'{"value":NaN}', b"[]"):
            with self.assertRaises(OBSERVER.ObservationError):
                OBSERVER._strict_json(raw, "test")
        for url in ("http://example.test/a", "https://user@example.test/a", "https://example.test/a#b"):
            with self.assertRaisesRegex(OBSERVER.ObservationError, "canonical HTTPS"):
                OBSERVER._require_https(url, "test URL")


if __name__ == "__main__":
    unittest.main()
