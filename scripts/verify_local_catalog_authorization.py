#!/usr/bin/env python3
"""Verify a protected GitHub handoff before the offline catalog signer acts."""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
import sys
from typing import Mapping


SCHEMA = "forge-platform.local-catalog-signing-authorization/v1"
REPOSITORY = "autonomous-engineering-system/forge-platform"
WORKFLOW = "Forge Platform composition catalog release framework"
REF = "refs/heads/main"
REQUIRED_JOBS = {
    "Build unsigned composition catalog candidate",
    "Authorize exact local catalog signing handoff",
}
SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
FIELDS = {
    "schema", "repository", "ref", "source_sha", "workflow_sha", "workflow",
    "run_id", "run_attempt", "environment", "candidate_artifact",
    "candidate_digest", "unsigned_catalog_digest", "catalog_sequence",
    "requested_by", "result",
}


def _pairs(values: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if not isinstance(key, str) or key in result:
            raise ValueError("JSON contains duplicate or invalid keys")
        result[key] = value
    return result


def _load(path: Path, label: str) -> Mapping[str, object]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise ValueError(f"{label} is not a bounded regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not strict JSON") from error
    if not isinstance(value, Mapping):
        raise ValueError(f"{label} root is invalid")
    return value


def verify(
    *,
    authorization_path: Path,
    run_metadata_path: Path,
    candidate_directory: Path,
    source_sha: str,
    run_id: int,
) -> Mapping[str, object]:
    if SHA.fullmatch(source_sha) is None:
        raise ValueError("source SHA must be one full lowercase Git SHA")
    authorization = _load(authorization_path, "catalog signing authorization")
    if set(authorization) != FIELDS:
        raise ValueError("catalog signing authorization fields are invalid")
    expected = {
        "schema": SCHEMA,
        "repository": REPOSITORY,
        "ref": REF,
        "source_sha": source_sha,
        "workflow_sha": source_sha,
        "workflow": WORKFLOW,
        "run_id": run_id,
        "environment": "forge-platform-installer-signing",
        "result": "AUTHORIZED_FOR_LOCAL_CATALOG_SIGNER",
    }
    for field, value in expected.items():
        if authorization[field] != value:
            raise ValueError(f"catalog signing authorization {field} does not bind the request")
    for field in ("run_attempt", "catalog_sequence"):
        if type(authorization[field]) is not int or authorization[field] <= 0:
            raise ValueError(f"catalog signing authorization {field} is invalid")
    for field in ("candidate_digest", "unsigned_catalog_digest"):
        if not isinstance(authorization[field], str) or DIGEST.fullmatch(authorization[field]) is None:
            raise ValueError(f"catalog signing authorization {field} is invalid")
    candidate_artifact = authorization["candidate_artifact"]
    if (
        not isinstance(candidate_artifact, str)
        or re.fullmatch(r"forge-platform-composition-catalog-candidate-[1-9][0-9]*-[0-9a-f]{40}", candidate_artifact) is None
    ):
        raise ValueError("catalog candidate artifact name is unsafe")

    metadata = _load(run_metadata_path, "GitHub run metadata")
    for field, value in {
        "databaseId": run_id,
        "headBranch": "main",
        "headSha": source_sha,
        "event": "workflow_dispatch",
        "conclusion": "success",
        "workflowName": WORKFLOW,
    }.items():
        if metadata.get(field) != value:
            raise ValueError(f"GitHub run metadata {field} does not bind the authorization")
    jobs = metadata.get("jobs")
    if not isinstance(jobs, list):
        raise ValueError("GitHub run jobs are unavailable")
    observed: dict[str, str] = {}
    for job in jobs:
        if isinstance(job, Mapping) and isinstance(job.get("name"), str):
            name = job["name"]
            if name in observed:
                raise ValueError("GitHub run contains duplicate job names")
            if isinstance(job.get("conclusion"), str):
                observed[name] = job["conclusion"]
    if any(observed.get(name) != "success" for name in REQUIRED_JOBS):
        raise ValueError("required catalog build or protected authorization job did not succeed")

    candidate_root = candidate_directory.resolve(strict=True)
    if candidate_directory.is_symlink() or not candidate_root.is_dir():
        raise ValueError("catalog candidate directory is invalid")
    candidate_path = candidate_root / "composition-catalog-candidate.json"
    actual_candidate_digest = "sha256:" + sha256(candidate_path.read_bytes()).hexdigest()
    if actual_candidate_digest != authorization["candidate_digest"]:
        raise ValueError("downloaded catalog candidate digest does not match authorization")
    candidate = _load(candidate_path, "catalog candidate")
    if (
        candidate.get("source_sha") != source_sha
        or candidate.get("sequence") != authorization["catalog_sequence"]
        or candidate.get("unsigned_catalog_digest") != authorization["unsigned_catalog_digest"]
        or candidate.get("repository") != REPOSITORY
    ):
        raise ValueError("catalog candidate does not bind the protected authorization")
    unsigned_path = candidate_root / "composition-catalog-unsigned.json"
    actual_unsigned_digest = "sha256:" + sha256(unsigned_path.read_bytes()).hexdigest()
    if actual_unsigned_digest != authorization["unsigned_catalog_digest"]:
        raise ValueError("downloaded unsigned catalog bytes do not match authorization")
    return authorization


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authorization", required=True)
    parser.add_argument("--run-metadata", required=True)
    parser.add_argument("--candidate-directory", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    args = parser.parse_args(argv)
    try:
        authorization = verify(
            authorization_path=Path(args.authorization),
            run_metadata_path=Path(args.run_metadata),
            candidate_directory=Path(args.candidate_directory),
            source_sha=args.source_sha,
            run_id=args.run_id,
        )
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        print(f"LOCAL_CATALOG_AUTHORIZATION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "LOCAL_CATALOG_AUTHORIZATION=PASS"
        f" run_id={authorization['run_id']}"
        f" source_sha={authorization['source_sha']}"
        f" sequence={authorization['catalog_sequence']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
