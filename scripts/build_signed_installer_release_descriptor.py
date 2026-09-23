#!/usr/bin/env python3
"""Build and threshold-sign one canonical installer release descriptor.

Private descriptor keys remain on the protected signing host. This command
never receives key bytes or key paths; it invokes the exact release-crypto
executable which selects a key only by reviewed key ID from its fixed key root.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))

from forge_platform.installer_release_operation import InstallerReleasePreparation
from forge_platform.installer_release_trust import parse_installer_release_trust_bytes
from forge_platform.universal_installer import canonical_https_url
from validate_installer_release_identity import load_identity


_RAW_SHA256=re.compile(r"^[0-9a-f]{64}$")
_RECEIPT=re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_TIMESTAMP=re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


def _read_json(path:Path,label:str)->dict[str,object]:
    supplied=Path(path).expanduser()
    if supplied.is_symlink():
        raise ValueError(f"{label} must not be a symlink")
    raw=supplied.resolve(strict=True).read_bytes()
    def pairs(values):
        result={}
        for key,value in values:
            if not isinstance(key,str) or key in result:
                raise ValueError(f"{label} contains duplicate or invalid fields")
            result[key]=value
        return result
    value=json.loads(raw.decode("utf-8"),object_pairs_hook=pairs,parse_constant=lambda v:(_ for _ in ()).throw(ValueError(v)))
    if not isinstance(value,dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def _digest(path:Path)->str:
    h=sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""):
            h.update(block)
    return "sha256:"+h.hexdigest()


def _canonical(value:object)->bytes:
    return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True,allow_nan=False).encode("ascii")


def _crypto(path:Path,*arguments:str)->dict[str,object]:
    executable=Path(path).expanduser()
    if executable.name!="ForgePlatformInstallerReleaseCrypto" or not executable.is_absolute():
        raise ValueError("release crypto executable identity is invalid")
    result=subprocess.run((str(executable),*arguments),capture_output=True,text=True,check=False,env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"C","LC_ALL":"C"})
    if result.returncode:
        raise ValueError("protected descriptor crypto operation failed")
    try:
        value=json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("protected descriptor signer returned invalid JSON") from error
    if not isinstance(value,dict):
        raise ValueError("protected descriptor signer returned invalid evidence")
    return value


def build(
    *,
    preparation_path:Path,
    release_identity_path:Path,
    release_trust_path:Path,
    archive_path:Path,
    architecture:str,
    code_directory_sha256:str,
    notarization_receipt_reference:str,
    composition_catalog_url:str,
    published_at:str,
    expires_at:str,
    crypto_executable:Path,
    output:Path,
)->dict[str,object]:
    if architecture!="arm64":
        raise ValueError("installer release descriptor supports only arm64")
    if _RAW_SHA256.fullmatch(code_directory_sha256) is None:
        raise ValueError("CodeDirectory digest is invalid")
    if _RECEIPT.fullmatch(notarization_receipt_reference) is None:
        raise ValueError("notarization receipt reference is invalid")
    if _TIMESTAMP.fullmatch(published_at) is None or _TIMESTAMP.fullmatch(expires_at) is None:
        raise ValueError("descriptor timestamps must be canonical RFC3339 UTC")
    start=datetime.strptime(published_at,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    end=datetime.strptime(expires_at,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    if end<=start:
        raise ValueError("descriptor expiry must follow publication")
    catalog_url=canonical_https_url(composition_catalog_url,"composition catalog URL")

    preparation=InstallerReleasePreparation.parse(_read_json(preparation_path,"installer preparation"))
    identity=load_identity(require_ready=True,path=release_identity_path)
    if identity is None or identity!=preparation.release_identity:
        raise ValueError("reviewed release identity does not match preparation")

    trust_raw=Path(release_trust_path).read_bytes()
    trust=parse_installer_release_trust_bytes(trust_raw)
    if (
        trust.configuration_sha256!=identity.release_trust_configuration_sha256
        or trust.repository!=identity.github_repository
        or trust.release_descriptor_asset_name!=identity.release_descriptor_asset_name
        or trust.expected_bundle_identifier!=identity.bundle_identifier
        or trust.expected_team_identifier!=identity.team_identifier
        or trust.signature_key_ids!=identity.signature_key_ids
        or trust.signature_threshold!=identity.signature_threshold
    ):
        raise ValueError("release trust resource does not bind reviewed identity")

    archive=Path(archive_path).resolve(strict=True)
    if archive.name!=identity.asset_name(architecture) or not stat.S_ISREG(archive.stat().st_mode):
        raise ValueError("signed installer archive name or type is invalid")
    archive_digest=_digest(archive)
    descriptor={
        "schema":"forge-platform.installer-release/v1",
        "sequence":preparation.release_sequence,
        "channel":preparation.channel,
        "published_at":published_at,
        "expires_at":expires_at,
        "github_release":{
            "repository":identity.github_repository,
            "tag":identity.release_tag(preparation.installer_version),
            "descriptor_asset_name":identity.release_descriptor_asset_name,
        },
        "installer":{
            "version":preparation.installer_version,
            "source_revision":preparation.source_revision,
            "policy_revision":preparation.policy_revision,
            "release_trust_configuration_sha256":identity.release_trust_configuration_sha256,
            "provenance_sha256":preparation.provenance_sha256,
            "capabilities":list(preparation.capabilities),
            "assets":[{
                "operating_system":"macos",
                "architecture":"arm64",
                "minimum_macos_version":"26.0.0",
                "asset_name":archive.name,
                "digest":archive_digest,
                "bundle_identifier":identity.bundle_identifier,
                "team_identifier":identity.team_identifier,
                "code_directory_sha256":code_directory_sha256,
                "notarization_receipt_reference":notarization_receipt_reference,
            }],
        },
        "composition_catalog":{"url":catalog_url},
    }
    payload=_canonical(descriptor)
    output_path=Path(output).resolve(strict=False)
    output_path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,payload_name=tempfile.mkstemp(prefix=".installer-descriptor-payload-",dir=output_path.parent)
    try:
        with os.fdopen(fd,"wb") as stream:
            stream.write(payload);stream.flush();os.fsync(stream.fileno())
        os.chmod(payload_name,0o600)
        trusted=dict(trust.ed25519_public_keys)
        signatures=[]
        for key_id in identity.signature_key_ids[:identity.signature_threshold]:
            result=_crypto(crypto_executable,"sign","--key-id",key_id,"--payload",str(Path(payload_name).resolve()))
            if (
                result.get("algorithm")!="ed25519"
                or result.get("key_id")!=key_id
                or result.get("public_key_base64")!=trusted[key_id]
                or not isinstance(result.get("signature"),str)
            ):
                raise ValueError("protected signer key identity does not match reviewed public trust")
            verify=subprocess.run(
                (str(crypto_executable),"verify","--payload",str(Path(payload_name).resolve()),
                 "--public-key-base64",trusted[key_id],"--signature",result["signature"]),
                capture_output=True,text=True,check=False,
                env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"C","LC_ALL":"C"},
            )
            if verify.returncode:
                raise ValueError("protected descriptor signature did not verify")
            signatures.append({"algorithm":"ed25519","key_id":key_id,"signature":result["signature"]})
        final={**descriptor,"signatures":signatures}
        raw=_canonical(final)+b"\n"
        output_path.write_bytes(raw)
        os.chmod(output_path,0o600)
        return final
    finally:
        Path(payload_name).unlink(missing_ok=True)


def main(argv:list[str]|None=None)->int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preparation",required=True,type=Path)
    parser.add_argument("--release-identity",required=True,type=Path)
    parser.add_argument("--release-trust",required=True,type=Path)
    parser.add_argument("--archive",required=True,type=Path)
    parser.add_argument("--architecture",default="arm64")
    parser.add_argument("--code-directory-sha256",required=True)
    parser.add_argument("--notarization-receipt-reference",required=True)
    parser.add_argument("--composition-catalog-url",required=True)
    parser.add_argument("--published-at",required=True)
    parser.add_argument("--expires-at",required=True)
    parser.add_argument("--crypto-executable",required=True,type=Path)
    parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args(argv)
    try:
        value=build(
            preparation_path=args.preparation,release_identity_path=args.release_identity,
            release_trust_path=args.release_trust,archive_path=args.archive,
            architecture=args.architecture,code_directory_sha256=args.code_directory_sha256,
            notarization_receipt_reference=args.notarization_receipt_reference,
            composition_catalog_url=args.composition_catalog_url,published_at=args.published_at,
            expires_at=args.expires_at,crypto_executable=args.crypto_executable,output=args.output,
        )
    except (OSError,RuntimeError,ValueError) as error:
        print(f"INSTALLER_RELEASE_DESCRIPTOR=FAIL reason={error}",file=sys.stderr);return 1
    print("INSTALLER_RELEASE_DESCRIPTOR=SIGNED"
          f" sequence={value['sequence']}"
          f" signatures={len(value['signatures'])}"
          f" digest=sha256:{sha256(Path(args.output).read_bytes()).hexdigest()}")
    return 0

if __name__=="__main__":
    raise SystemExit(main())
