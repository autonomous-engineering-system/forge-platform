#!/usr/bin/env python3
"""Record exact installer GitHub publication/readback and terminal cleanup."""

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
    InstallerCleanupEvidence,InstallerPublicationEvidence,
    InstallerReleaseOperation,InstallerReleaseOperationStore,
)


def digest(path:Path)->str:
    h=sha256()
    with path.open("rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""): h.update(block)
    return "sha256:"+h.hexdigest()


def write(path:Path,operation:InstallerReleaseOperation)->None:
    raw=(json.dumps(asdict(operation),sort_keys=True,separators=(",",":"),allow_nan=False)+"\n").encode()
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    if path.exists() and path.read_bytes()!=raw: raise ValueError("output already binds different operation")
    path.write_bytes(raw);path.chmod(0o600)


def published(operation_path:Path,journal_root:Path,descriptor_readback:Path,archive_readback:Path,
              publication_receipt:str,readback_receipt:str,output:Path)->InstallerReleaseOperation:
    expected=InstallerReleaseOperation.parse(json.loads(operation_path.read_text(encoding="utf-8")))
    if expected.state!="QUALIFIED": raise ValueError("publication requires QUALIFIED operation")
    if digest(descriptor_readback)!=expected.descriptor_digest: raise ValueError("descriptor readback digest mismatch")
    if digest(archive_readback)!=expected.archives["arm64"]: raise ValueError("archive readback digest mismatch")
    evidence=InstallerPublicationEvidence(
        github_repository=expected.release_identity.github_repository,
        release_tag=expected.release_tag,policy_revision=expected.policy_revision,
        release_sequence=expected.release_sequence,provenance_sha256=expected.provenance_sha256,
        release_trust_configuration_sha256=expected.release_identity.release_trust_configuration_sha256,
        descriptor_asset_name=expected.release_identity.release_descriptor_asset_name,
        descriptor_digest=expected.descriptor_digest,descriptor_readback_digest=digest(descriptor_readback),
        archives=expected.archives,publication_receipt_reference=publication_receipt,
        readback_receipt_reference=readback_receipt,
    )
    store=InstallerReleaseOperationStore(journal_root);store.acquire(expected.operation_id)
    try:
        retained=store.load(expected.operation_id)
        if retained is None or retained!=expected: raise ValueError("durable QUALIFIED operation mismatch")
        result=store.mark_published(retained,evidence=evidence)
    finally:
        store.release(expected.operation_id)
    write(output,result);return result


def complete(operation_path:Path,journal_root:Path,cleanup_receipt:str,target_ids:list[str],output:Path)->InstallerReleaseOperation:
    expected=InstallerReleaseOperation.parse(json.loads(operation_path.read_text(encoding="utf-8")))
    if expected.state!="PUBLISHED": raise ValueError("completion requires PUBLISHED operation")
    evidence=InstallerCleanupEvidence("CLEANUP_COMPLETE",cleanup_receipt,tuple(target_ids))
    store=InstallerReleaseOperationStore(journal_root);store.acquire(expected.operation_id)
    try:
        retained=store.load(expected.operation_id)
        if retained is None or retained!=expected: raise ValueError("durable PUBLISHED operation mismatch")
        result=store.complete(retained,evidence=evidence)
    finally:
        store.release(expected.operation_id)
    write(output,result);return result


def main()->int:
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest="command",required=True)
    pub=sub.add_parser("published");pub.add_argument("--operation",required=True,type=Path);pub.add_argument("--journal-root",required=True,type=Path)
    pub.add_argument("--descriptor-readback",required=True,type=Path);pub.add_argument("--archive-readback",required=True,type=Path)
    pub.add_argument("--publication-receipt-reference",required=True);pub.add_argument("--readback-receipt-reference",required=True);pub.add_argument("--output",required=True,type=Path)
    fin=sub.add_parser("complete");fin.add_argument("--operation",required=True,type=Path);fin.add_argument("--journal-root",required=True,type=Path)
    fin.add_argument("--cleanup-receipt-reference",required=True);fin.add_argument("--target-id",action="append",default=[]);fin.add_argument("--output",required=True,type=Path)
    a=p.parse_args()
    try:
        if a.command=="published":
            op=published(a.operation,a.journal_root,a.descriptor_readback,a.archive_readback,a.publication_receipt_reference,a.readback_receipt_reference,a.output)
        else:
            op=complete(a.operation,a.journal_root,a.cleanup_receipt_reference,a.target_id,a.output)
    except (OSError,RuntimeError,ValueError) as e:
        print(f"INSTALLER_RELEASE_STATE=FAIL reason={e}",file=sys.stderr);return 1
    print(f"INSTALLER_RELEASE_STATE={op.state} operation_id={op.operation_id}");return 0

if __name__=="__main__": raise SystemExit(main())
