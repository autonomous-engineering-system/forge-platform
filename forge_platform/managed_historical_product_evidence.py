"""Read-only original CREATE evidence; never a product-operation admission.

This does not execute products, prepare providers, read credentials, change
rights or grant current-release authority. The native helper must independently
verify original signed material, current executor and authenticated operator.
"""
from __future__ import annotations

from contextlib import ExitStack
import ctypes
import errno
from dataclasses import dataclass
from hashlib import sha256
import io
import json
import os
from pathlib import Path
import pwd
import re
import stat
import tarfile
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener

from .managed_ep_partial_create import _json, assert_ep_partial_create_quiescent
from .managed_installer_user_identity import resolve_identity_sha256
from .managed_product_operation_admission import (
    NativeProductOperationRequest, decode_native_product_operation_request,
)
from .universal_installer import CompositionManifest, DownloadIdentity
from .installer_helper_companion import no_extended_acl


class HistoricalProductEvidenceError(RuntimeError):
    pass


def _require(value):
    if not value:
        raise HistoricalProductEvidenceError("original product evidence conflicts")


def _canonical(value):
    return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False,allow_nan=False).encode()


def _hash(value):
    return sha256(value).hexdigest()


def _framed(values,domain=b""):
    result=domain
    for value in values:
        raw=str(value).encode();result+=len(raw).to_bytes(8,"big")+raw
    return result


def _profile(s):
    return (s.st_dev,s.st_ino,s.st_uid,s.st_gid,s.st_mode,s.st_nlink,s.st_size,
            s.st_mtime_ns,s.st_ctime_ns,s.st_flags)


def _runtime_acl(fd, uid, mask):
    """Inspect the existing native SEARCH/READ+EXECUTE policy; never repair it."""
    lib=ctypes.CDLL("/usr/lib/libSystem.B.dylib",use_errno=True)
    ptr=ctypes.c_void_p
    declarations={
        "acl_get_fd_np":([ctypes.c_int,ctypes.c_int],ptr),
        "acl_valid":([ptr],ctypes.c_int), "acl_free":([ptr],ctypes.c_int),
        "acl_get_entry":([ptr,ctypes.c_int,ctypes.POINTER(ptr)],ctypes.c_int),
        "acl_get_tag_type":([ptr,ctypes.POINTER(ctypes.c_int)],ctypes.c_int),
        "acl_get_permset_mask_np":([ptr,ctypes.POINTER(ctypes.c_uint64)],ctypes.c_int),
        "acl_get_flagset_np":([ptr,ctypes.POINTER(ptr)],ctypes.c_int),
        "acl_get_flag_np":([ptr,ctypes.c_uint32],ctypes.c_int),
        "acl_get_qualifier":([ptr],ptr),
        "mbr_uid_to_uuid":([ctypes.c_uint32,ptr],ctypes.c_int),
    }
    for name,(args,result) in declarations.items():
        function=getattr(lib,name);function.argtypes=args;function.restype=result
    uids=(uid,) if isinstance(uid,int) else tuple(sorted(set(uid)))
    _require(uids and all(x>0 for x in uids) and mask in {8,10})
    identities=[]
    for selected in uids:
        identity=(ctypes.c_ubyte*16)();_require(lib.mbr_uid_to_uuid(selected,identity)==0)
        identities.append(bytes(identity))
    ctypes.set_errno(0);acl=lib.acl_get_fd_np(fd,0x100)
    if not acl:
        _require(ctypes.get_errno()==errno.ENOENT);return ()
    found=[]
    try:
        _require(lib.acl_valid(acl)==0)
        cursor=0;entry=ptr()
        while True:
            ctypes.set_errno(0);rc=lib.acl_get_entry(acl,cursor,ctypes.byref(entry))
            if rc==-1 and ctypes.get_errno()==errno.EINVAL:break
            _require(rc==0 and entry.value);cursor=-1
            tag=ctypes.c_int();permissions=ctypes.c_uint64();flags=ptr()
            _require(lib.acl_get_tag_type(entry,ctypes.byref(tag))==0 and tag.value==1
                and lib.acl_get_permset_mask_np(entry,ctypes.byref(permissions))==0
                and permissions.value==mask
                and lib.acl_get_flagset_np(entry,ctypes.byref(flags))==0 and flags.value)
            _require(all(lib.acl_get_flag_np(flags,f)==0 for f in [1,1<<4,1<<5,1<<6,1<<7,1<<8,1<<17]))
            qualifier=lib.acl_get_qualifier(entry);_require(qualifier)
            try:observed=ctypes.string_at(qualifier,16)
            finally:lib.acl_free(qualifier)
            _require(observed in identities and observed not in found);found.append(observed)
        return tuple(found)
    finally:lib.acl_free(acl)


class _StableReadback:
    """Keep every inspected inode open until the complete provider scan ends."""
    def __init__(self):
        self.stack=ExitStack();self.observations=[]

    def __enter__(self):return self

    def __exit__(self,*args):return self.stack.__exit__(*args)

    def open(self,path,*,directory=False,acl):
        flags=os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC|getattr(os,"O_NOFOLLOW_ANY",0x20000000)
        if directory:flags|=os.O_DIRECTORY
        fd=os.open(path,flags);self.stack.callback(os.close,fd)
        details=os.fstat(fd);grant=acl(fd)
        _require(_profile(path.lstat())==_profile(details))
        self.observations.append((path,fd,details,grant,acl))
        return fd,details

    def verify(self):
        for path,fd,before,grant,acl in self.observations:
            _require(_profile(os.fstat(fd))==_profile(before)
                     and _profile(path.lstat())==_profile(before) and acl(fd)==grant)


def _bounded_members(tf):
    entries=[];expanded=0
    for entry in tf:
        _require(len(entries)<131072 and entry.size>=0)
        expanded+=entry.size;_require(expanded<=2*1024*1024*1024)
        entries.append(entry)
    _require(entries and expanded>0)
    return entries,expanded


_MAXIMUM_ARCHIVE_BYTES = 300 * 1024 * 1024
_PUBLIC_ARCHIVE_HOSTS = frozenset({"github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"})


def _public_archive_url(value):
    # Both initial locator and every redirect remain public HTTPS. No caller
    # locator, authentication header, cookie jar or provider credential is used.
    DownloadIdentity(value,"sha256:"+"0"*64)
    _require(urlsplit(value).hostname in _PUBLIC_ARCHIVE_HOSTS)
    return value


class _PublicArchiveRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        _public_archive_url(newurl)
        return super().redirect_request(req,fp,code,msg,headers,newurl)


def _bounded_archive_bytes(stream):
    content=bytearray()
    while True:
        block=stream.read(min(1024*1024,_MAXIMUM_ARCHIVE_BYTES+1-len(content)))
        if not block:break
        content.extend(block);_require(len(content)<=_MAXIMUM_ARCHIVE_BYTES)
    _require(content)
    return bytes(content)


def _fetch_public_archive(artifact):
    try:
        url=_public_archive_url(artifact.url)
        with build_opener(ProxyHandler({}),_PublicArchiveRedirect()).open(url,timeout=30) as response:
            _public_archive_url(response.geturl())
            raw=_bounded_archive_bytes(response)
        _require("sha256:"+_hash(raw)==artifact.digest)
        return raw
    except Exception:
        # A signed public CDN URL may have opaque transport query data; neither
        # locator nor underlying HTTP exception is exposed in diagnostics.
        raise HistoricalProductEvidenceError("original public provider archive is unavailable") from None


def _archive_readback(stable,path,artifact,fetch=_fetch_public_archive):
    try:fd,before=stable.open(path,acl=no_extended_acl)
    except FileNotFoundError:fd=None
    if fd is not None:
        _require(stat.S_ISREG(before.st_mode) and before.st_uid==0 and before.st_nlink==1
                 and stat.S_IMODE(before.st_mode)==0o600 and before.st_flags==0 and no_extended_acl(fd))
        raw=b""
        if 0<before.st_size<=_MAXIMUM_ARCHIVE_BYTES:
            with os.fdopen(os.dup(fd),"rb") as stream:raw=_bounded_archive_bytes(stream)
        _require(_profile(os.fstat(fd))==_profile(before) and _profile(path.lstat())==_profile(before))
        if raw and "sha256:"+_hash(raw)==artifact.digest:return raw
    # Cache bytes are acquisition data, not retained runtime identity. Fetch
    # the exact public signed digest in memory; never recreate/replace slots,
    # archives, homes or credentials to manufacture historical tree evidence.
    raw=fetch(artifact)
    _require(isinstance(raw,bytes) and 0<len(raw)<=_MAXIMUM_ARCHIVE_BYTES
             and "sha256:"+_hash(raw)==artifact.digest)
    return raw


@dataclass(frozen=True)
class HistoricalProductEvidence:
    request: NativeProductOperationRequest
    canonical_request: bytes
    engineering_platform_operation_id: str
    protected_sha256_by_role: tuple[tuple[str,str],...]

    def canonical_readback(self) -> bytes:
        # Public intent and opaque hashes only. Raw original authority, operator
        # records and provider home contents never cross this private bridge.
        return _canonical({
            "schema":"forge-platform.historical-product-evidence/v1",
            "request":json.loads(self.canonical_request),
            "engineering_platform_operation_id":self.engineering_platform_operation_id,
            "protected_sha256_by_role":dict(self.protected_sha256_by_role),
        })


def _pin_private_directory(stable,path,uids):
    fd,details=stable.open(path,directory=True,acl=lambda fd:_runtime_acl(fd,uids,8))
    _require(stat.S_ISDIR(details.st_mode) and details.st_uid==0
             and stat.S_IMODE(details.st_mode)==0o700 and details.st_flags==0)


def _provider_references(root,parent,wire,requirement,operator,stable):
    owner= requirement["owner_component"]; provider=requirement["identity"]
    runtime=requirement["runtime"];target=parent["deployment_id"]
    _require(owner in {"engineering-platform-server","forge-runtime"}
             and provider in {"codex","github-cli"}
             and not (owner=="forge-runtime" and provider!="codex")
             and requirement["credential_scope"]=="component"
             and requirement["target_identity"]=="selected-deployment"
             and runtime["archive_kind"]=="tar.gz")
    provider_id=provider+":"+owner+":"+target
    ep=owner=="engineering-platform-server"
    instance=wire["ep_instance_id"] if ep else wire["forge_instance_id"]
    _require(re.fullmatch(r"fpi-[0-9a-f]{40}",instance) is not None)
    account_name=wire["ep_service_account"] if ep else wire["forge_service_account"]
    _require(re.fullmatch(r"_fpi_[0-9a-f]{20}",account_name) is not None if ep else account_name==operator["account_name"])
    account=pwd.getpwnam(account_name)
    provider_root=(root/"products/engineering-platform/instances"/instance/"providers"/
                   ("codex" if provider=="codex" else "github")) if ep else (
        root/"provider-contexts/deployments"/target/"providers/forge-runtime"/target/"codex/runtime")
    _require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+",runtime["version"]) is not None)
    slot=provider_root/"runtime" if ep else provider_root/runtime["version"]
    home=provider_root/("home" if provider=="codex" else "config") if ep else provider_root.parent/"home"
    # Pin each helper-owned namespace, not only its final leaf. Each provider
    # path has one exact bound account; shared helper parents are pinned by the
    # caller against the complete selected cohort.
    path=root
    for segment in provider_root.relative_to(root).parts:
        path=path/segment
        _pin_private_directory(stable,path,(account.pw_uid,))
    # Open directory metadata only. No credential child or home content is read.
    fd,hs=stable.open(home,directory=True,acl=lambda fd: no_extended_acl(fd))
    _require(stat.S_ISDIR(hs.st_mode) and hs.st_uid==account.pw_uid and hs.st_gid==account.pw_gid
             and stat.S_IMODE(hs.st_mode)==0o700 and hs.st_flags==0 and no_extended_acl(fd))
    artifact=runtime["artifact"]["digest"]
    _require(re.fullmatch(r"sha256:[0-9a-f]{64}",artifact) is not None)
    archive=provider_root/("archive-"+artifact[7:]+".tar.gz")
    download=DownloadIdentity(runtime["artifact"]["url"],artifact)
    raw=_archive_readback(stable,archive,download)
    with io.BytesIO(raw) as stream:
        with tarfile.open(fileobj=stream,mode="r:gz") as tf:
            entries,expanded=_bounded_members(tf)
            members=[];seen=set()
            for entry in entries:
                _require(entry.isfile() or entry.isdir())
                path=entry.name.rstrip("/")+("/" if entry.isdir() else "")
                parts=path.rstrip("/").split("/")
                _require(path and len(path.encode())<=1024 and not path.startswith("/")
                         and "\\" not in path and all(part not in {"",".",".."} for part in parts)
                         and path.lower() not in seen and entry.mode&~0o777==0)
                seen.add(path.lower());digest=""
                if entry.isfile():
                    source=tf.extractfile(entry);hasher=sha256()
                    for block in iter(lambda:source.read(1024*1024),b""):hasher.update(block)
                    digest="sha256:"+hasher.hexdigest()
                mode=0o500 if path==runtime["executable_relative_path"] else entry.mode
                members.append((path,"directory" if entry.isdir() else "file",mode,entry.size,digest))
    executable=[x for x in members if x[0]==runtime["executable_relative_path"]]
    _require(len(executable)==1 and executable[0][4]==runtime["executable_digest"])
    inspection="provider-archive-inspection-"+_hash(_framed([
        provider_id,provider,runtime["version"],runtime["archive_kind"],artifact,
        runtime["executable_relative_path"],runtime["executable_digest"],len(entries),expanded],
        b"forge-platform-provider-archive-inspection-v1"))
    fd,ss=stable.open(slot,directory=True,acl=lambda fd:_runtime_acl(fd,account.pw_uid,8))
    _require(stat.S_ISDIR(ss.st_mode) and ss.st_uid==0 and stat.S_IMODE(ss.st_mode)==0o700
             and ss.st_flags==0)
    material=_framed([str(slot),ss.st_ino]);children={}
    for path,kind,mode,size,digest in sorted(members,key=lambda item:(item[0].count("/"),item[0])):
        executable_file=path==runtime["executable_relative_path"] and kind=="file"
        validate=(lambda fd:_runtime_acl(fd,account.pw_uid,10)) if executable_file else (
            (lambda fd:_runtime_acl(fd,account.pw_uid,8)) if kind=="directory" and mode==0o700
            else (lambda fd: no_extended_acl(fd)))
        fd,before=stable.open(slot/path,directory=kind=="directory",acl=validate)
        _require(before.st_uid==0 and stat.S_IMODE(before.st_mode)==mode and before.st_flags==0
                 and (stat.S_ISDIR(before.st_mode) if kind=="directory" else stat.S_ISREG(before.st_mode)))
        if not executable_file and not (kind=="directory" and mode==0o700):
            _require(no_extended_acl(fd))
        if kind=="file":
            _require(before.st_nlink==1 and before.st_size==size)
            hasher=sha256()
            for block in iter(lambda:os.read(fd,1024*1024),b""):hasher.update(block)
            _require("sha256:"+hasher.hexdigest()==digest)
        material+=_framed([path,kind,mode,size,digest])
        bare=path.rstrip("/");parent_path=str(Path(bare).parent)
        parent_path="" if parent_path=="." else parent_path
        children.setdefault(parent_path,set()).add(Path(bare).name)
        if kind=="directory":children.setdefault(bare,set())
    for path,names in children.items():_require(set(os.listdir(slot/path))==names)
    _require(_profile(slot.lstat())==_profile(ss) and _profile(home.lstat())==_profile(hs))
    _require(pwd.getpwnam(account_name)==account)
    tree="receipt:managed-python-tree-v2-"+_hash(material)
    provider_tree="receipt:provider-tree-"+_hash(_framed([provider_id,inspection,tree],b"forge-platform-provider-tree-v1"))
    account_receipt=("receipt:service-account-"+_hash("\0".join([
        parent["stable_plan_fingerprint"],parent["operation_id"],account_name,
        str(account.pw_uid),str(account.pw_gid)]).encode())) if ep else (
            "receipt:named-operator-"+_hash(_canonical(operator)))
    product_artifact=wire["ep_artifact_sha256"] if ep else wire["forge_artifact_sha256"]
    authority="sha256:"+_hash(_framed(["forge-platform-preprovider-account-authority/v1",
        parent["stable_plan_fingerprint"],parent["operation_id"],target,owner,provider_id,
        product_artifact,account_name,account.pw_uid,account.pw_gid,account_receipt]))
    home_identity="provider-home-"+_hash(_framed([target,provider_id],b"forge-platform-managed-provider-identity-v1"))
    fields=[home_identity,authority,str(account.pw_uid),str(account.pw_gid)]+([instance] if ep else [])
    home_evidence="receipt:provider-home-"+_hash("\0".join(fields).encode())
    mutation="receipt:provider-runtime-"+_hash("\0".join([provider_tree,home_evidence,authority]).encode())
    return provider_id,("receipt:provider-runtime-archive-"+artifact[7:],inspection,mutation)


def reconstruct_original_product_evidence(root: Path, operation_id: str) -> HistoricalProductEvidence:
    """Inspect only the active dual CREATE; inputs come from the native helper."""
    with _StableReadback() as stable:
        result=_reconstruct_original_product_evidence(root,operation_id,stable)
        stable.verify()
        return result


def _reconstruct_original_product_evidence(root,operation_id,stable):
    _require(os.geteuid()==0 and isinstance(root,Path) and root.is_absolute()
             and isinstance(operation_id,str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",operation_id))
    protected={}
    def read(role,path):
        value,digest=_json(path,maximum=1024*1024);protected[role]=(path,digest)
        return value
    parent=read("parent",root/"state/active-installer-operation.json")
    _require(parent.get("state")=="MANAGED_TOOLS" and parent.get("operation_id")==operation_id)
    for field in ("deployment_id","session_id"):
        _require(isinstance(parent.get(field),str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",parent[field]))
    _require(re.fullmatch(r"[0-9a-f]{64}",parent["stable_plan_fingerprint"]) is not None)
    original=root/("reviewed-selection-"+_hash(operation_id.encode())+".json")
    resumed=root/("reviewed-selection-post-tool-"+_hash((operation_id+"\0"+parent["stable_plan_fingerprint"]).encode())+".json")
    selection=read("selection",resumed if os.path.lexists(resumed) else original)
    _require(selection["intent"]["operation_id"]==operation_id
             and selection["intent"]["stable_plan_fingerprint"]==parent["stable_plan_fingerprint"]
             and selection["intent"]["deployment_id"]==parent["deployment_id"]
             and selection["intent"]["session_id"]==parent["session_id"]
             and selection["component_identities"]==["engineering-platform-server","forge-runtime"])
    route=read("route",root/("released-route-"+_hash(_canonical(selection["route_request"]))+".json"))
    user_record=read("operator",root/("reviewed-installer-user-"+_hash((operation_id+"\0"+parent["stable_plan_fingerprint"]).encode())+".json"))
    operator=user_record["operator"]
    _require(user_record["operation_id"]==operation_id and user_record["stable_plan_fingerprint"]==parent["stable_plan_fingerprint"]
             and user_record["deployment_id"]==parent["deployment_id"])
    _require(resolve_identity_sha256(operator["account_name"])=="sha256:"+_hash(_canonical(operator)))
    authority=read("authority",root/"product-worker-authority.json")
    _require(authority["schema"]=="forge-platform.product-worker-authority/v7")
    routes=[x for x in authority["installation_routes"] if x["deployment_id"]==parent["deployment_id"]]
    # This bounded unfinished fresh CREATE has no other deployment cohort.
    # A host with additional routes needs the separately verified native cohort
    # resolver, rather than widening the historical reader's ACL allowance.
    _require(len(routes)==1 and len(authority["installation_routes"])==1);wire=routes[0]
    ep_account=pwd.getpwnam(wire["ep_service_account"])
    forge_account=pwd.getpwnam(wire["forge_service_account"])
    _require(wire["forge_service_account"]==operator["account_name"])
    cohort=(ep_account.pw_uid,forge_account.pw_uid)
    for path in (root.parent,root):_pin_private_directory(stable,path,cohort)
    fd,details=stable.open(root/"state",directory=True,acl=no_extended_acl)
    _require(details.st_uid==0 and stat.S_IMODE(details.st_mode)==0o700
             and details.st_flags==0 and no_extended_acl(fd))
    matches=[m for m in authority["candidate_manifests"] if m["digest"]==parent["manifest_sha256"]]
    _require(len(matches)==1);payload=matches[0]["payload"]
    manifest=CompositionManifest.from_digest_bound_bytes(_canonical(payload),manifest_digest=parent["manifest_sha256"])
    _require(manifest.composition_id==parent["composition_identity"])
    git=read("git",root/"state"/("managed-git-terminal-"+_hash(operation_id.encode())+".json"))
    _require(git["phase"]=="COMPLETE" and git["operation_id"]==operation_id
             and git["stable_plan_fingerprint"]==parent["stable_plan_fingerprint"])
    refs=[parent["managed_tools_evidence"]["python_runtime_receipt_reference"],
          git["mutation_evidence_reference"],git["final_readback_evidence_reference"]]
    providers=[]
    for requirement in payload["providers"]:
        target,values=_provider_references(root,parent,wire,requirement,operator,stable)
        providers.append(target);refs.extend(values)
    _require(sorted(providers)==selection["enabled_provider_target_ids"] and len(providers)==3)
    components=[]
    for component in route["components"]:
        _require(component["change"]=="install" and component["installed_version"] is None)
        components.append({"identity":component["id"],"change":"install","installed_version":None,
            "candidate_version":component["candidate_version"],"artifact_sha256":component["artifact_digest"],
            "update_assessment_reference":None})
    value={"schema":"forge-platform.native-product-operation-request/v3",
        "stable_plan_fingerprint":parent["stable_plan_fingerprint"],"operation_id":operation_id,
        "session_id":parent["session_id"],"deployment_id":parent["deployment_id"],"deployment_exists":False,
        "forge_instance_id":None,"engineering_platform_instance_id":None,
        "installed_composition_identity":None,"installed_composition_manifest_sha256":None,
        "inventory_evidence_reference":selection["route_request"]["inventory_evidence_reference"],
        "composition_identity":parent["composition_identity"],"manifest_sha256":parent["manifest_sha256"],
        "installer_release":authority["installer_release"],"components":sorted(components,key=lambda x:x["identity"]),
        "provider_target_ids":sorted(providers),"runtime_evidence_references":sorted(set(refs))}
    value["request_fingerprint"]=_hash(_canonical(value))
    canonical=_canonical(value);request=decode_native_product_operation_request(canonical)
    product_id="product-"+_hash((request.request_fingerprint+"\x1fengineering-platform-server\x1fmutation").encode())
    instance=wire["ep_instance_id"]
    product=read("product_request",root/"products/engineering-platform/instances"/instance/"operations"/product_id/"request.json")
    artifact=next(x.artifact for x in manifest.components if x.identity=="engineering-platform-server")
    _require(type(product.get("bind_port")) is int and product=={
        "contract":"engineering-platform.system-provisioner/v1","operation":"INSTALL","operation_id":product_id,
        "instance_id":instance,"display_label":wire["ep_display_label"],"service_account":wire["ep_service_account"],
        "bind_port":wire["ep_bind_port"],"release":{"version":artifact.version,"artifact_digest":artifact.digest,
        "source_revision":artifact.source_revision}})
    _require(pwd.getpwnam(wire["ep_service_account"])==ep_account
             and pwd.getpwnam(wire["forge_service_account"])==forge_account)
    _require(resolve_identity_sha256(operator["account_name"])=="sha256:"+_hash(_canonical(operator)))
    for path,digest in protected.values():_require(_json(path,maximum=1024*1024)[1]==digest)
    return HistoricalProductEvidence(request,canonical,product_id,
        tuple(sorted((role,digest) for role,(_,digest) in protected.items())))


INSPECTION_SCHEMA = "forge-platform.historical-product-inspection/v1"


def decode_inspection_intent(raw: bytes) -> str:
    _require(isinstance(raw,bytes) and 0<len(raw)<=1024)
    def pairs(items):
        value={}
        for key,item in items:
            _require(key not in value);value[key]=item
        return value
    value=json.loads(raw,object_pairs_hook=pairs)
    _require(isinstance(value,dict) and set(value)=={"schema","operation_id"}
             and value["schema"]==INSPECTION_SCHEMA and _canonical(value)==raw
             and isinstance(value["operation_id"],str)
             and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",value["operation_id"]) is not None)
    return value["operation_id"]


RECOVERY_PREFLIGHT_SCHEMA = "forge-platform.historical-product-recovery-preflight/v1"


def decode_recovery_preflight_intent(raw: bytes) -> str:
    """Closed read-only intent; cannot select a product effect or caller path."""
    _require(isinstance(raw, bytes) and 0 < len(raw) <= 1024)
    def pairs(items):
        value = {}
        for key, item in items:
            _require(key not in value); value[key] = item
        return value
    value = json.loads(raw, object_pairs_hook=pairs)
    _require(isinstance(value, dict) and set(value) == {"schema", "operation_id"}
             and value["schema"] == RECOVERY_PREFLIGHT_SCHEMA and _canonical(value) == raw
             and isinstance(value["operation_id"], str)
             and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value["operation_id"]) is not None)
    return value["operation_id"]


def inspect_original_recovery_preflight(root: Path, operation_id: str) -> bytes:
    """No effects: original evidence PLUS physically unloaded EP/service account."""
    with _StableReadback() as stable:
        evidence = _reconstruct_original_product_evidence(root, operation_id, stable)
        authority, digest = _json(root / "product-worker-authority.json", maximum=1024*1024)
        expected = dict(evidence.protected_sha256_by_role)
        _require(digest == expected["authority"])
        routes = authority["installation_routes"]
        _require(len(routes) == 1 and routes[0]["deployment_id"] == evidence.request.deployment_id)
        wire = routes[0]
        assert_ep_partial_create_quiescent(helper_root=root, instance_id=wire["ep_instance_id"],
                                          service_account=wire["ep_service_account"])
        stable.verify()
        # Repeat the complete original readback after physical process inspection.
        repeated = _reconstruct_original_product_evidence(root, operation_id, stable)
        _require(repeated == evidence)
        assert_ep_partial_create_quiescent(helper_root=root, instance_id=wire["ep_instance_id"],
                                          service_account=wire["ep_service_account"])
        stable.verify()
        return _canonical({"schema": RECOVERY_PREFLIGHT_SCHEMA, "quiescent": True,
                           "original_evidence": json.loads(evidence.canonical_readback())})
