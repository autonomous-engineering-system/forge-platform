#!/usr/bin/env python3
"""Verify one protected GitHub authorization before the local signer acts.

The command consumes only public GitHub run metadata and downloaded artifact
bytes. It never reads Apple credentials, unlocks a Keychain, signs, notarizes,
or publishes. A successful result means only that the exact protected-main
workflow/run approved the exact unsigned candidate for the separate local
signer account.
"""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import sys
from typing import Mapping

_SCHEMA = "forge-platform.local-signing-authorization/v1"
_REPOSITORY = "autonomous-engineering-system/forge-platform"
_WORKFLOW = "Forge Platform installer release framework"
_REF = "refs/heads/main"
_SHA = re.compile(r"^[0-9a-f]{40}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_REQUIRED_JOBS = {
    "Build unsigned macOS installer candidate",
    "Authorize exact local signing handoff",
}
_AUTHORIZATION_FIELDS = {
    "schema", "repository", "ref", "source_sha", "workflow_sha", "workflow",
    "run_id", "run_attempt", "environment", "candidate_artifact",
    "archive_name", "archive_digest", "installer_version", "release_sequence",
    "operation_id", "requested_by", "result",
}


def _pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, member in pairs:
        if not isinstance(key, str) or key in value:
            raise ValueError("JSON contains duplicate or invalid keys")
        value[key] = member
    return value


def _load(path: Path, label: str) -> object:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError(f"{label} is not a bounded regular file")
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not strict JSON") from error


def _string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} is invalid")
    return value


def verify(
    *,
    authorization_path: Path,
    run_metadata_path: Path,
    candidate_directory: Path,
    source_sha: str,
    run_id: int,
    repository: str,
) -> Mapping[str, object]:
    if repository != _REPOSITORY:
        raise ValueError("repository is not the canonical release repository")
    if _SHA.fullmatch(source_sha) is None:
        raise ValueError("source SHA must be one full lowercase Git SHA")

    authorization = _load(authorization_path, "signing authorization")
    if not isinstance(authorization, Mapping) or set(authorization) != _AUTHORIZATION_FIELDS:
        raise ValueError("signing authorization fields are invalid")
    expected = {
        "schema": _SCHEMA,
        "repository": repository,
        "ref": _REF,
        "source_sha": source_sha,
        "workflow_sha": source_sha,
        "workflow": _WORKFLOW,
        "run_id": run_id,
        "environment": "forge-platform-installer-signing",
        "result": "AUTHORIZED_FOR_LOCAL_SIGNER",
    }
    for field, value in expected.items():
        if authorization[field] != value:
            raise ValueError(f"signing authorization {field} does not bind the request")
    for field in ("run_attempt", "release_sequence"):
        if type(authorization[field]) is not int or authorization[field] <= 0:
            raise ValueError(f"signing authorization {field} is invalid")
    for field in (
        "candidate_artifact", "archive_name", "installer_version",
        "operation_id", "requested_by",
    ):
        _string(authorization[field], f"signing authorization {field}")
    archive_digest = _string(authorization["archive_digest"], "signing authorization archive digest")
    if _DIGEST.fullmatch(archive_digest) is None:
        raise ValueError("signing authorization archive digest is invalid")

    metadata = _load(run_metadata_path, "GitHub run metadata")
    if not isinstance(metadata, Mapping):
        raise ValueError("GitHub run metadata root is invalid")
    for field, value in {
        "databaseId": run_id,
        "headBranch": "main",
        "headSha": source_sha,
        "event": "workflow_dispatch",
        "conclusion": "success",
        "workflowName": _WORKFLOW,
    }.items():
        if metadata.get(field) != value:
            raise ValueError(f"GitHub run metadata {field} does not bind the authorization")
    if not isinstance(metadata.get("url"), str) or not metadata["url"].startswith(
        f"https://github.com/{repository}/actions/runs/{run_id}"
    ):
        raise ValueError("GitHub run URL does not bind the canonical repository and run")

    jobs = metadata.get("jobs")
    if not isinstance(jobs, list):
        raise ValueError("GitHub run jobs are unavailable")
    observed: dict[str, str] = {}
    for job in jobs:
        if isinstance(job, Mapping) and isinstance(job.get("name"), str):
            name = job["name"]
            if name in observed:
                raise ValueError("GitHub run contains duplicate job names")
            conclusion = job.get("conclusion")
            if isinstance(conclusion, str):
                observed[name] = conclusion
    if any(observed.get(name) != "success" for name in _REQUIRED_JOBS):
        raise ValueError("required build or protected authorization job did not succeed")

    candidate = candidate_directory.resolve(strict=True)
    if not candidate.is_dir() or candidate_directory.is_symlink():
        raise ValueError("candidate artifact directory is invalid")
    archive_name = authorization["archive_name"]
    assert isinstance(archive_name, str)
    if Path(archive_name).name != archive_name or not archive_name.endswith(".zip"):
        raise ValueError("authorized archive name is unsafe")
    archive = candidate / archive_name
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("authorized candidate archive is missing")
    actual = "sha256:" + sha256(archive.read_bytes()).hexdigest()
    if actual != archive_digest:
        raise ValueError("downloaded candidate archive digest does not match authorization")

    manifest = _load(candidate / "installer-candidate.json", "installer candidate manifest")
    if not isinstance(manifest, Mapping):
        raise ValueError("installer candidate manifest root is invalid")
    if (
        manifest.get("source_revision") != source_sha
        or manifest.get("version") != authorization["installer_version"]
        or manifest.get("release_sequence") != authorization["release_sequence"]
    ):
        raise ValueError("installer candidate manifest does not bind the authorization")
    archives = manifest.get("archives")
    if not isinstance(archives, Mapping) or set(archives) != {"arm64"}:
        raise ValueError("installer candidate manifest architectures are invalid")
    arm64 = archives["arm64"]
    if not isinstance(arm64, Mapping) or (
        arm64.get("name") != archive_name
        or arm64.get("digest") != archive_digest
        or arm64.get("packaging") != "UNSIGNED_APP_CANDIDATE"
    ):
        raise ValueError("installer candidate manifest archive does not bind the authorization")
    return authorization


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorization", required=True)
    parser.add_argument("--run-metadata", required=True)
    parser.add_argument("--candidate-directory", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--repository", default=_REPOSITORY)
    args = parser.parse_args(argv)
    try:
        authorization = verify(
            authorization_path=Path(args.authorization),
            run_metadata_path=Path(args.run_metadata),
            candidate_directory=Path(args.candidate_directory),
            source_sha=args.source_sha,
            run_id=args.run_id,
            repository=args.repository,
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"LOCAL_SIGNING_AUTHORIZATION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "LOCAL_SIGNING_AUTHORIZATION=PASS"
        f" run_id={authorization['run_id']}"
        f" source_sha={authorization['source_sha']}"
        f" archive_digest={authorization['archive_digest']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
