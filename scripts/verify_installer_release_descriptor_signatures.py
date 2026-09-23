#!/usr/bin/env python3
"""Independently verify installer descriptor Ed25519 threshold signatures."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))

from forge_platform.installer_release_trust import parse_installer_release_trust_bytes
from forge_platform.universal_installer import SignatureThresholdPolicy,parse_public_signature_envelopes


def _pairs(values):
    result={}
    for key,value in values:
        if not isinstance(key,str) or key in result:
            raise ValueError("descriptor has duplicate/invalid keys")
        result[key]=value
    return result


def verify(descriptor:Path,trust_path:Path,crypto:Path)->int:
    raw=descriptor.read_bytes()
    root=json.loads(raw.decode("utf-8"),object_pairs_hook=_pairs,parse_constant=lambda v:(_ for _ in ()).throw(ValueError(v)))
    if not isinstance(root,dict) or "signatures" not in root:
        raise ValueError("descriptor signatures missing")
    signatures=parse_public_signature_envelopes(root["signatures"],label="installer release descriptor")
    trust=parse_installer_release_trust_bytes(trust_path.read_bytes())
    policy=SignatureThresholdPolicy("ed25519",frozenset(trust.signature_key_ids),trust.signature_threshold)
    policy.require_eligible(signatures)
    unsigned=dict(root);del unsigned["signatures"]
    payload=json.dumps(unsigned,sort_keys=True,separators=(",",":"),ensure_ascii=True,allow_nan=False).encode("ascii")
    payload_path=descriptor.with_name(".descriptor-canonical-payload.json")
    payload_path.write_bytes(payload)
    try:
        trusted=dict(trust.ed25519_public_keys)
        verified=0
        for envelope in signatures:
            result=subprocess.run(
                (str(crypto),"verify","--payload",str(payload_path.resolve()),
                 "--public-key-base64",trusted[envelope.key_id],"--signature",envelope.signature),
                capture_output=True,text=True,check=False,
                env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"C","LC_ALL":"C"},
            )
            if result.returncode!=0:
                raise ValueError("descriptor cryptographic signature verification failed")
            verified+=1
        if verified<trust.signature_threshold:
            raise ValueError("descriptor signatures do not meet threshold")
        return verified
    finally:
        payload_path.unlink(missing_ok=True)


def main()->int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--descriptor",required=True,type=Path)
    p.add_argument("--release-trust",required=True,type=Path)
    p.add_argument("--crypto-executable",required=True,type=Path)
    a=p.parse_args()
    try:
        count=verify(a.descriptor,a.release_trust,a.crypto_executable)
    except (OSError,RuntimeError,ValueError,KeyError) as e:
        print(f"INSTALLER_RELEASE_DESCRIPTOR_CRYPTO=FAIL reason={e}",file=sys.stderr);return 1
    print(f"INSTALLER_RELEASE_DESCRIPTOR_CRYPTO=PASS verified_signatures={count}")
    return 0

if __name__=="__main__":
    raise SystemExit(main())
