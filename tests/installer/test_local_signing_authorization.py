#!/usr/bin/env python3
from __future__ import annotations

from hashlib import sha256
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from scripts.verify_local_signing_authorization import verify

SOURCE = "a" * 40
RUN_ID = 12345
ARCHIVE = "ForgePlatformInstaller-macos-arm64.zip"


class LocalSigningAuthorizationTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, Path, Path]:
        candidate = root / "candidate"
        candidate.mkdir()
        archive = candidate / ARCHIVE
        archive.write_bytes(b"unsigned-candidate")
        digest = "sha256:" + sha256(archive.read_bytes()).hexdigest()
        authorization = {
            "schema": "forge-platform.local-signing-authorization/v1",
            "repository": "autonomous-engineering-system/forge-platform",
            "ref": "refs/heads/main",
            "source_sha": SOURCE,
            "workflow_sha": SOURCE,
            "workflow": "Forge Platform installer release framework",
            "run_id": RUN_ID,
            "run_attempt": 1,
            "environment": "forge-platform-installer-signing",
            "candidate_artifact": f"forge-platform-installer-candidate-0.2.0-{SOURCE}",
            "archive_name": ARCHIVE,
            "archive_digest": digest,
            "installer_version": "0.2.0",
            "release_sequence": 7,
            "operation_id": f"forge-platform-installer-0.2.0-{SOURCE}",
            "requested_by": "pcvantol",
            "result": "AUTHORIZED_FOR_LOCAL_SIGNER",
        }
        auth_path = root / "authorization.json"
        auth_path.write_text(json.dumps(authorization), encoding="utf-8")
        manifest = {
            "source_revision": SOURCE,
            "version": "0.2.0",
            "release_sequence": 7,
            "archives": {
                "arm64": {
                    "name": ARCHIVE,
                    "digest": digest,
                    "packaging": "UNSIGNED_APP_CANDIDATE",
                }
            },
        }
        (candidate / "installer-candidate.json").write_text(json.dumps(manifest), encoding="utf-8")
        metadata = {
            "databaseId": RUN_ID,
            "headBranch": "main",
            "headSha": SOURCE,
            "event": "workflow_dispatch",
            "conclusion": "success",
            "workflowName": "Forge Platform installer release framework",
            "url": f"https://github.com/autonomous-engineering-system/forge-platform/actions/runs/{RUN_ID}",
            "jobs": [
                {"name": "Build unsigned macOS installer candidate", "conclusion": "success"},
                {"name": "Authorize exact local signing handoff", "conclusion": "success"},
            ],
        }
        metadata_path = root / "run.json"
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        return auth_path, metadata_path, candidate

    def invoke(self, root: Path):
        auth, metadata, candidate = self.fixture(root)
        return verify(
            authorization_path=auth,
            run_metadata_path=metadata,
            candidate_directory=candidate,
            source_sha=SOURCE,
            run_id=RUN_ID,
            repository="autonomous-engineering-system/forge-platform",
        )

    def test_exact_successful_protected_handoff_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = self.invoke(Path(temporary))
            self.assertEqual(result["source_sha"], SOURCE)

    def test_workflow_or_source_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            auth, metadata, candidate = self.fixture(root)
            value = json.loads(metadata.read_text())
            value["headSha"] = "b" * 40
            metadata.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "headSha"):
                verify(
                    authorization_path=auth,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha=SOURCE,
                    run_id=RUN_ID,
                    repository="autonomous-engineering-system/forge-platform",
                )

    def test_failed_required_job_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            auth, metadata, candidate = self.fixture(root)
            value = json.loads(metadata.read_text())
            value["jobs"][1]["conclusion"] = "failure"
            metadata.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "did not succeed"):
                verify(
                    authorization_path=auth,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha=SOURCE,
                    run_id=RUN_ID,
                    repository="autonomous-engineering-system/forge-platform",
                )

    def test_changed_candidate_bytes_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            auth, metadata, candidate = self.fixture(root)
            (candidate / ARCHIVE).write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "digest"):
                verify(
                    authorization_path=auth,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha=SOURCE,
                    run_id=RUN_ID,
                    repository="autonomous-engineering-system/forge-platform",
                )

    def test_duplicate_authorization_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            auth, metadata, candidate = self.fixture(root)
            raw = auth.read_text()
            auth.write_text(raw.replace('"schema":', '"schema":"duplicate","schema":', 1))
            with self.assertRaisesRegex(ValueError, "strict JSON"):
                verify(
                    authorization_path=auth,
                    run_metadata_path=metadata,
                    candidate_directory=candidate,
                    source_sha=SOURCE,
                    run_id=RUN_ID,
                    repository="autonomous-engineering-system/forge-platform",
                )


if __name__ == "__main__":
    unittest.main()
