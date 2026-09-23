#!/usr/bin/env python3
"""Promote one exact protected signed/notarized installer to QUALIFIED."""

from __future__ import annotations
import argparse
from dataclasses import asdict
from hashlib import sha256
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))

from forge_platform.installer_release_operation import (
    InstallerQualificationEvidence,InstallerReleaseOperation,
    InstallerReleaseOperationStore,InstallerReleasePreparation,
)


def digest(path:Path)->str:
    h=sha256()
    with path.open("rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""): h.update(block)
    return "sha256:"+h.hexdigest()


def qualify(preparation_path:Path,journal_root:Path,descriptor:Path,archive:Path,
            code_directory_sha256:str,notary_reference:str,receipt_reference:str,
            output:Path)->InstallerReleaseOperation:
    prep=InstallerReleasePreparation.parse(json.loads(preparation_path.read_text(encoding="utf-8")))
    archive_digest=digest(archive)
    descriptor_digest=digest(descriptor)
    evidence=InstallerQualificationEvidence(
        source_revision=prep.source_revision,
        policy_revision=prep.policy_revision,
        release_sequence=prep.release_sequence,
        provenance_sha256=prep.provenance_sha256,
        release_trust_configuration_sha256=prep.release_identity.release_trust_configuration_sha256,
        candidate_manifest_digest=prep.preparation.candidate_manifest_digest,
        candidate_archives=prep.preparation.candidate_archives,
        descriptor_digest=descriptor_digest,
        archives={"arm64":archive_digest},
        archive_code_directory_sha256={"arm64":code_directory_sha256},
        archive_notarization_receipt_references={"arm64":notary_reference},
        qualification_receipt_reference=receipt_reference,
    )
    operation=InstallerReleaseOperation.create(
        operation_id=prep.operation_id,installer_version=prep.installer_version,
        channel=prep.channel,release_sequence=prep.release_sequence,
        source_revision=prep.source_revision,policy_revision=prep.policy_revision,
        provenance_sha256=prep.provenance_sha256,release_identity=prep.release_identity,
        capabilities=prep.capabilities,preparation=prep.preparation,
        archives={"arm64":archive_digest},descriptor_digest=descriptor_digest,
        qualification=evidence,
    )
    store=InstallerReleaseOperationStore(journal_root)
    store.acquire(operation.operation_id)
    try:
        retained=store.prepare_qualified(operation)
    finally:
        store.release(operation.operation_id)
    raw=(json.dumps(asdict(retained),sort_keys=True,separators=(",",":"),allow_nan=False)+"\n").encode()
    output.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    if output.exists() and output.read_bytes()!=raw:
        raise ValueError("qualification output already binds different release bytes")
    output.write_bytes(raw);output.chmod(0o600)
    return retained


def main()->int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--preparation",required=True,type=Path);p.add_argument("--journal-root",required=True,type=Path)
    p.add_argument("--descriptor",required=True,type=Path);p.add_argument("--archive",required=True,type=Path)
    p.add_argument("--code-directory-sha256",required=True);p.add_argument("--notarization-receipt-reference",required=True)
    p.add_argument("--qualification-receipt-reference",required=True);p.add_argument("--output",required=True,type=Path)
    a=p.parse_args()
    try:
        op=qualify(a.preparation,a.journal_root,a.descriptor,a.archive,a.code_directory_sha256,
                   a.notarization_receipt_reference,a.qualification_receipt_reference,a.output)
    except (OSError,RuntimeError,ValueError) as e:
        print(f"INSTALLER_RELEASE_QUALIFICATION=FAIL reason={e}",file=sys.stderr);return 1
    print(f"INSTALLER_RELEASE_QUALIFICATION=QUALIFIED operation_id={op.operation_id} descriptor_digest={op.descriptor_digest}")
    return 0

if __name__=="__main__": raise SystemExit(main())
