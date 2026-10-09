"""Operation-owned public maintenance inputs; no product/credential changes.

Only the external resolver copy may be adopted by the owning controller.
Installer preparation/intent evidence stays in the private root-owned store.
"""
from dataclasses import dataclass, replace
from hashlib import sha256
import json
import fcntl
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import stat
import subprocess
from urllib.parse import urlsplit
from uuid import uuid4

from .managed_forge_instance_bootstrap import _open, _search
from .managed_installer_user_identity import resolve_identity_sha256
from .qualified_forge_lifecycle import qualified_forge_281_update_selection

_SCHEMA = "forge-platform.forge281-maintenance-preparation/v1"
_MAX_WHEEL = 512 * 1024 * 1024


class Forge281CompartmentError(RuntimeError):
    pass


def _canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def _read(path, owner, modes, maximum):
    fd = _open(path, owners=owner if isinstance(owner, tuple) else (owner,), modes=modes)
    try:
        before = os.fstat(fd)
        if not 0 < before.st_size <= maximum:
            raise Forge281CompartmentError("maintenance input exceeds its bound")
        chunks, remaining = [], before.st_size + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk: break
            chunks.append(chunk); remaining -= len(chunk)
        data = b"".join(chunks); after = os.fstat(fd)
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if len(data) != before.st_size or any(getattr(before,k) != getattr(after,k) for k in fields):
            raise Forge281CompartmentError("maintenance input changed")
        return data
    finally: os.close(fd)


def _proof(path, owner):
    if not os.path.lexists(path): return None
    raw = _read(path, owner, (0o600,), 65536)
    try: value = json.loads(raw)
    except ValueError: raise Forge281CompartmentError("maintenance preparation invalid") from None
    if not isinstance(value,dict) or _canonical(value) != raw:
        raise Forge281CompartmentError("maintenance preparation not canonical")
    return value


def _publish(parent, name, data, uid, gid, mode):
    """Exclusive publication through pinned directory/file descriptors."""
    temporary = ".prepare-" + uuid4().hex
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
                 | getattr(os,"O_NOFOLLOW_ANY",0x20000000), mode, dir_fd=parent)
    try:
        view = memoryview(data)
        while view:
            count = os.write(fd, view)
            if count <= 0: raise Forge281CompartmentError("maintenance write incomplete")
            view = view[count:]
        if os.fstat(fd).st_uid != uid or os.fstat(fd).st_gid != gid: os.fchown(fd,uid,gid)
        os.fchmod(fd,mode); os.fsync(fd)
        try: os.link(temporary,name,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)
        except FileExistsError: pass
        os.fsync(parent)
    finally:
        os.close(fd); os.unlink(temporary,dir_fd=parent); os.fsync(parent)


def _directory(parent, name, uid, gid, *, create, additional_owner=None):
    created = False
    if create:
        try: os.mkdir(name,0o700,dir_fd=parent); created=True
        except FileExistsError: pass
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                 | getattr(os,"O_NOFOLLOW_ANY",0x20000000),dir_fd=parent)
    try:
        info=os.fstat(fd)
        if created:
            # Only a newly created child under the closed helper-owned layout.
            if info.st_uid != os.geteuid():
                raise Forge281CompartmentError("maintenance created directory changed owner")
            os.fchown(fd,uid,gid); os.fsync(fd); info=os.fstat(fd)
        permitted = {(uid,gid)}
        if additional_owner is not None: permitted.add(additional_owner)
        if not stat.S_ISDIR(info.st_mode) or (info.st_uid,info.st_gid) not in permitted or stat.S_IMODE(info.st_mode)!=0o700:
            raise Forge281CompartmentError("maintenance directory not owned and private")
        if created: os.fsync(parent)
        return fd
    except Exception: os.close(fd); raise


def _wheel_name(artifact):
    source=urlsplit(artifact.source); name=PurePosixPath(source.path).name
    if (source.scheme!="https" or not source.hostname or source.username is not None or source.password is not None
        or ".." in name or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,192}\.whl",name) is None):
        raise Forge281CompartmentError("maintenance wheel name not admitted")
    return name


@dataclass(frozen=True)
class PreparedForge281Compartment:
    runtime_root: Path
    resolver: Path
    original_interpreter: Path
    installed_wheel: Path
    candidate_wheel: Path
    resolver_sha256: str
    status_resolver: Path


def _selection_fingerprint(request):
    """The review receipt approves an unchanged selection, not a new copy."""
    fields = request.product_request
    if fields and (set(fields) != {"reviewed_update_assessment_reference"}
        or not isinstance(fields["reviewed_update_assessment_reference"], str)
        or re.fullmatch(r"forge-update-assess:sha256:[0-9a-f]{64}",
                        fields["reviewed_update_assessment_reference"]) is None):
        raise Forge281CompartmentError("maintenance preparation has unknown review fields")
    return replace(request, product_request={}).fingerprint()


def _prepare_281_compartment_locked(*, root, request, target, installed, original_resolver,
                            runtime_id, installation_id, intent_root, intent_phase=None,
                            expected_owner_uid=0):
    """Same-operation preparation only. Never overwrite/adopt foreign files."""
    if (os.geteuid()!=expected_owner_uid or request.kind!="update" or request.component!="forge-runtime"
        or request.installation_identity!=target.instance_id or not qualified_forge_281_update_selection(installed,request.artifact)
        or target.instances_root!=root/"instances/forge" or target.data_root!=target.instances_root/target.instance_id
        or intent_root!=root/"state/forge-update-intents"
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}",request.operation_id) is None
        or not target.service_user_identity_sha256 or target.service_account.startswith("_")
        or resolve_identity_sha256(target.service_account)!=target.service_user_identity_sha256):
        raise Forge281CompartmentError("maintenance preparation authority changed")
    account=pwd.getpwnam(target.service_account)
    if account.pw_name!=target.service_account or account.pw_uid<=0 or account.pw_gid<=0:
        raise Forge281CompartmentError("maintenance named operator unavailable")
    member=subprocess.run(("/usr/bin/dsmemberutil","checkmembership","-U",account.pw_name,"-G","admin"),
        cwd="/",stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
        env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin"},timeout=5,check=False)
    if member.returncode or member.stdout.strip()!=b"user is a member of the group":
        raise Forge281CompartmentError("maintenance operator is not an administrator")
    original=_read(original_resolver,expected_owner_uid,(0o500,0o700,0o755),512*1024)
    original_digest="sha256:"+sha256(original).hexdigest()
    base=target.instances_root/(".maintenance-"+target.instance_id)
    runtime=base/"runtime"; resolver=base/"bin/forge"
    inputs=[(installed,root/"staged"/(installed.digest[7:]+".artifact")),
            (request.artifact,root/"staged"/(request.artifact.digest[7:]+".artifact"))]
    names=[_wheel_name(a) for a,_ in inputs]
    if len(set(names))!=2: raise Forge281CompartmentError("maintenance wheel names overlap")
    selection=dict(operation_id=request.operation_id,selection_fingerprint=_selection_fingerprint(request),
        installer_instance_id=target.instance_id,runtime_id=runtime_id,installation_id=installation_id,
        account_name=account.pw_name,uid=account.pw_uid,gid=account.pw_gid,
        identity_sha256=target.service_user_identity_sha256,
        original_resolver=str(original_resolver),original_resolver_sha256=original_digest,
        original_interpreter=str(original_resolver.parent/"python3"),runtime_root=str(runtime),resolver=str(resolver),
        installed_wheel=str(runtime/"inputs"/names[0]),candidate_wheel=str(runtime/"inputs"/names[1]),
        installed_digest=installed.digest,candidate_digest=request.artifact.digest)
    proof_path=intent_root/(request.operation_id+".preparation.json")
    state=_proof(proof_path,expected_owner_uid)
    if state is not None and (set(state)!={"schema","state","selection"} or state["schema"]!=_SCHEMA
        or state["selection"]!=selection or state["state"] not in {"PREPARED","COMPLETE"}):
        raise Forge281CompartmentError("maintenance preparation belongs to another selection")
    intent_fd=_open(intent_root,directory=True,owners=(expected_owner_uid,))
    parent=_open(target.instances_root,directory=True,owners=(expected_owner_uid,),modes=(0o755,))
    handles=[]
    try:
        if state is None:
            if os.path.lexists(base): raise Forge281CompartmentError("maintenance compartment has no own preparation")
            for artifact,path in inputs:
                if "sha256:"+sha256(_read(path,expected_owner_uid,(0o600,),_MAX_WHEEL)).hexdigest()!=artifact.digest:
                    raise Forge281CompartmentError("maintenance original wheel changed")
            state=dict(schema=_SCHEMA,state="PREPARED",selection=selection)
            _publish(intent_fd,proof_path.name,_canonical(state),expected_owner_uid,os.getegid(),0o600)
            if _proof(proof_path,expected_owner_uid)!=state: raise Forge281CompartmentError("maintenance preparation raced")
        # Build under a closed helper-owned parent; hand off its UID last.
        prepared=state["state"]=="PREPARED"
        closed=prepared and (not os.path.lexists(base) or base.lstat().st_uid==expected_owner_uid)
        uid,gid=(expected_owner_uid,os.getegid()) if closed else (account.pw_uid,account.pw_gid)
        extra=(account.pw_uid,account.pw_gid) if closed else None
        compartment=_directory(parent,base.name,uid,gid,create=closed); handles.append(compartment)
        binary=_directory(compartment,"bin",uid,gid,create=closed,additional_owner=extra); handles.append(binary)
        runtime_fd=_directory(compartment,"runtime",uid,gid,create=closed,additional_owner=extra); handles.append(runtime_fd)
        input_fd=_directory(runtime_fd,"inputs",uid,gid,create=closed,additional_owner=extra); handles.append(input_fd)
        if closed:
            if not os.path.lexists(resolver): _publish(binary,"forge",original,uid,gid,0o500)
            for (artifact,path),name in zip(inputs,names):
                if not os.path.lexists(runtime/"inputs"/name):
                    content=_read(path,expected_owner_uid,(0o600,),_MAX_WHEEL)
                    if "sha256:"+sha256(content).hexdigest()!=artifact.digest: raise Forge281CompartmentError("maintenance input changed")
                    _publish(input_fd,name,content,uid,gid,0o600)
        readable_owners=(expected_owner_uid,account.pw_uid) if closed else account.pw_uid
        status=resolver
        if resolver.is_symlink():
            if not (state["state"]=="COMPLETE" and intent_phase in {"UPDATER_INVOKED","PRODUCT_COMPLETE","COMPLETE"}
                    and os.readlink(resolver)==str(runtime/"bin/forge")):
                raise Forge281CompartmentError("maintenance resolver has unknown adoption")
            legacy=runtime/"legacy"/(original_digest[7:23]+"-forge")
            if _read(legacy,account.pw_uid,(0o700,),512*1024)!=original:
                raise Forge281CompartmentError("maintenance legacy resolver changed")
            if intent_phase=="UPDATER_INVOKED": status=legacy
        elif _read(resolver,readable_owners,(0o500,),512*1024)!=original:
            raise Forge281CompartmentError("maintenance resolver copy changed")
        for artifact,name in zip((installed,request.artifact),names):
            if "sha256:"+sha256(_read(runtime/"inputs"/name,readable_owners,(0o600,),_MAX_WHEEL)).hexdigest()!=artifact.digest:
                raise Forge281CompartmentError("maintenance owned wheel changed")
        if closed:
            # Only our byte-verified files are chowned; original managed files never are.
            for path,mode in ((resolver,0o500),(runtime/"inputs"/names[0],0o600),(runtime/"inputs"/names[1],0o600)):
                fd=_open(path,owners=(expected_owner_uid,account.pw_uid),modes=(mode,))
                try:
                    os.fchown(fd,account.pw_uid,account.pw_gid); os.fsync(fd)
                finally: os.close(fd)
            for fd in reversed(handles):
                os.fchown(fd,account.pw_uid,account.pw_gid); os.fsync(fd)
            os.fsync(parent)
        if state["state"]=="PREPARED":
            complete=dict(state,state="COMPLETE")
            temporary=".proof-"+uuid4().hex
            _publish(intent_fd,temporary,_canonical(complete),expected_owner_uid,os.getegid(),0o600)
            if _proof(proof_path,expected_owner_uid)!=state: raise Forge281CompartmentError("maintenance proof currency changed")
            os.rename(temporary,proof_path.name,src_dir_fd=intent_fd,dst_dir_fd=intent_fd); os.fsync(intent_fd)
            if _proof(proof_path,expected_owner_uid)!=complete: raise Forge281CompartmentError("maintenance proof not durable")
        if resolve_identity_sha256(account.pw_name)!=target.service_user_identity_sha256:
            raise Forge281CompartmentError("maintenance operator changed during preparation")
        # Only exact search on the existing helper-owned instance ancestor.
        _search(parent,[account.pw_uid])
        return PreparedForge281Compartment(runtime,resolver,original_resolver.parent/"python3",
            runtime/"inputs"/names[0],runtime/"inputs"/names[1],original_digest,status)
    finally:
        for fd in reversed(handles): os.close(fd)
        os.close(parent); os.close(intent_fd)


def prepared_281_candidate_wheel(binding, request, *, expected_owner_uid=0):
    path=binding.intent_root/(request.operation_id+".preparation.json")
    state=_proof(path,expected_owner_uid)
    expected=binding.runtime_root/"inputs"/_wheel_name(request.artifact)
    if (not isinstance(state,dict) or state.get("schema")!=_SCHEMA or state.get("state")!="COMPLETE"
        or not isinstance(state.get("selection"),dict)
        or state["selection"].get("selection_fingerprint")!=_selection_fingerprint(request)
        or state["selection"].get("runtime_root")!=str(binding.runtime_root)
        or state["selection"].get("resolver")!=str(binding.resolver)
        or state["selection"].get("candidate_wheel")!=str(expected)
        or state["selection"].get("candidate_digest")!=request.artifact.digest
        or state["selection"].get("installed_wheel")!=str(binding.installed_wheel)):
        raise Forge281CompartmentError("maintenance candidate lacks exact preparation")
    data=_read(expected,state["selection"]["uid"],(0o600,),_MAX_WHEEL)
    if "sha256:"+sha256(data).hexdigest()!=request.artifact.digest:
        raise Forge281CompartmentError("maintenance prepared candidate changed")
    return expected


def prepare_281_compartment(**kwargs):
    """A private nonblocking lease protects preparation and resume proof."""
    root = kwargs["intent_root"]; owner = kwargs.get("expected_owner_uid", 0)
    directory = _open(root, directory=True, owners=(owner,))
    fd = None
    try:
        fd = os.open(".forge281-preparation.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC
                     | getattr(os,"O_NOFOLLOW_ANY",0x20000000),0o600,dir_fd=directory)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=owner or info.st_nlink!=1 or stat.S_IMODE(info.st_mode)!=0o600:
            raise Forge281CompartmentError("maintenance preparation lease unsafe")
        try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise Forge281CompartmentError("maintenance preparation already active") from None
        return _prepare_281_compartment_locked(**kwargs)
    finally:
        if fd is not None: os.close(fd)
        os.close(directory)
