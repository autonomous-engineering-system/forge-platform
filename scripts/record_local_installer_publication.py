#!/usr/bin/env python3
"""Record exact GitHub Release readback in the local signer journal."""
from __future__ import annotations

import argparse
from dataclasses import asdict
from hashlib import sha256
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from forge_platform.installer_release_operation import (
    InstallerPublicationEvidence,
    InstallerReleaseOperation,
    InstallerReleaseOperationError,
    InstallerReleaseOperationStore,
)


def _digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError("publication evidence must be a regular file")
    value = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return "sha256:" + value.hexdigest()


def record(
    *,
    operation_path: Path,
    descriptor_path: Path,
    descriptor_readback_path: Path,
    archive_path: Path,
    archive_readback_path: Path,
    run_id: int,
    journal_root: Path,
    output_path: Path,
) -> InstallerReleaseOperation:
    try:
        operation = InstallerReleaseOperation.parse(json.loads(operation_path.read_text(encoding="utf-8")))
    except (OSError, ValueError, json.JSONDecodeError, InstallerReleaseOperationError) as error:
        raise ValueError("qualified installer operation is invalid") from error
    if operation.state != "QUALIFIED":
        raise ValueError("publication input must be a qualified operation")
    descriptor_digest = _digest(descriptor_path)
    descriptor_readback_digest = _digest(descriptor_readback_path)
    archive_digest = _digest(archive_path)
    archive_readback_digest = _digest(archive_readback_path)
    if (
        descriptor_digest != operation.descriptor_digest
        or descriptor_readback_digest != descriptor_digest
        or archive_digest != operation.archives["arm64"]
        or archive_readback_digest != archive_digest
    ):
        raise ValueError("GitHub Release readback bytes do not bind qualified evidence")
    evidence = InstallerPublicationEvidence(
        github_repository=operation.release_identity.github_repository,
        release_tag=operation.release_tag,
        policy_revision=operation.policy_revision,
        release_sequence=operation.release_sequence,
        provenance_sha256=operation.provenance_sha256,
        release_trust_configuration_sha256=operation.release_identity.release_trust_configuration_sha256,
        descriptor_asset_name=operation.release_identity.release_descriptor_asset_name,
        descriptor_digest=descriptor_digest,
        descriptor_readback_digest=descriptor_readback_digest,
        archives={"arm64": archive_readback_digest},
        publication_receipt_reference=f"receipt:github-release-{run_id}",
        readback_receipt_reference=f"receipt:github-release-readback-{run_id}",
    )
    store = InstallerReleaseOperationStore(journal_root)
    store.acquire(operation.operation_id)
    try:
        published = store.mark_published(operation, evidence=evidence)
    finally:
        store.release(operation.operation_id)
    raw = (json.dumps(asdict(published), sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    if output_path.exists() and output_path.read_bytes() != raw:
        raise ValueError("published operation output already contains different evidence")
    if not output_path.exists():
        output_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with output_path.open("xb") as stream:
            stream.write(raw)
        output_path.chmod(0o600)
    return published


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--operation", required=True)
    parser.add_argument("--descriptor", required=True)
    parser.add_argument("--descriptor-readback", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--archive-readback", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--journal-root", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        published = record(
            operation_path=Path(args.operation),
            descriptor_path=Path(args.descriptor),
            descriptor_readback_path=Path(args.descriptor_readback),
            archive_path=Path(args.archive),
            archive_readback_path=Path(args.archive_readback),
            run_id=args.run_id,
            journal_root=Path(args.journal_root),
            output_path=Path(args.output),
        )
    except (OSError, RuntimeError, ValueError, InstallerReleaseOperationError) as error:
        print(f"LOCAL_INSTALLER_PUBLICATION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "LOCAL_INSTALLER_PUBLICATION=PASS"
        f" operation_id={published.operation_id}"
        f" tag={published.release_tag}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
