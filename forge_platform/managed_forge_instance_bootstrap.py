"""Real Forge CLI bootstrap and protected installer-to-product identity binding.

Provider credentials are neither read nor copied. A new opaque local service
API credential is created only in the already selected helper-owned route;
its bytes never leave that route or appear in evidence. Product initialization
and provider configuration remain commands of the published Forge CLI.
"""
from __future__ import annotations

import ctypes
import hashlib
import errno
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import stat
import subprocess
from .managed_installer_user_identity import resolve_identity_sha256
from .qualified_forge_lifecycle import qualified_forge_installation_pairing_artifact
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .forge_server_adapter import ForgeServerTarget
    from .component_operations import QualifiedArtifact


class ForgeInstanceBootstrapError(RuntimeError):
    pass


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def _open(path: Path, *, directory=False, owners=(0,), modes=(0o700,)):
    flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW_ANY", 0x20000000)
    if directory:
        flags |= os.O_DIRECTORY
    fd = os.open(path, flags)
    s = os.fstat(fd)
    if (s.st_uid not in owners or stat.S_IMODE(s.st_mode) not in modes
        or not (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode))
        or not directory and s.st_nlink != 1):
        os.close(fd)
        raise ForgeInstanceBootstrapError("Forge bootstrap path metadata is unsafe")
    return fd


def _record(path: Path, maximum=32 * 1024):
    fd = _open(path, modes=(0o600,))
    try:
        s = os.fstat(fd)
        if not 0 < s.st_size <= maximum:
            raise ForgeInstanceBootstrapError("Forge binding record size is invalid")
        with os.fdopen(fd, "rb", closefd=False) as f:
            raw = f.read(maximum + 1)
        after = os.fstat(fd)
        if (s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns) != (
            after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise ForgeInstanceBootstrapError("Forge binding record changed")
        value = json.loads(raw)
        if not isinstance(value, dict) or _canonical(value) != raw:
            raise ForgeInstanceBootstrapError("Forge binding record is not canonical")
        return value
    finally:
        os.close(fd)


def binding_path(target: ForgeServerTarget) -> Path:
    return target.instances_root.parent.parent / "state/forge-runtime-bindings" / (target.instance_id + ".json")


def read_runtime_binding(target: ForgeServerTarget):
    path = binding_path(target)
    try:
        value = _record(path)
    except FileNotFoundError:
        return None
    expected = {"schema", "selector", "data_root", "service_account", "runtime_id", "artifact", "provider_context_digest"}
    if (set(value) != expected or value["schema"] != "forge-platform.forge-runtime-binding/v1"
        or value["selector"] != target.instance_id or value["data_root"] != str(target.data_root)
        or value["service_account"] != target.service_account
        or not re.fullmatch(r"forge-runtime-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value["runtime_id"])
        or not isinstance(value["artifact"], dict)
        or set(value["artifact"]) != {"version", "digest", "source_revision"}
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", value["provider_context_digest"])):
        raise ForgeInstanceBootstrapError("Forge product binding does not match its installer selector")
    return value


def _publish(path: Path, value):
    parent = _open(path.parent, directory=True)
    temporary = "." + path.name + ".publish-" + secrets.token_hex(8)
    fd = None
    try:
        try:
            prior = _record(path)
        except FileNotFoundError:
            prior = None
        if prior is not None:
            if prior != value:
                raise ForgeInstanceBootstrapError("Forge bootstrap evidence conflicts")
            return
        data = _canonical(value)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                     0o600, dir_fd=parent)
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data); stream.flush(); os.fsync(fd)
        try:
            os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
        except FileExistsError:
            if _record(path) != value:
                raise ForgeInstanceBootstrapError("Forge bootstrap evidence conflicts")
        os.unlink(temporary, dir_fd=parent)
        os.fsync(parent)
    finally:
        if fd is not None:
            os.close(fd)
            try: os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError: pass
        os.close(parent)


def _search(fd, uids):
    """FD-bound exact search ACL; existing unknown/broader grants fail closed."""
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    ptr = ctypes.c_void_p
    declarations = {
        "acl_get_fd_np": ([ctypes.c_int, ctypes.c_int], ptr),
        "acl_init": ([ctypes.c_int], ptr), "acl_free": ([ptr], ctypes.c_int),
        "acl_get_entry": ([ptr, ctypes.c_int, ctypes.POINTER(ptr)], ctypes.c_int),
        "acl_get_tag_type": ([ptr, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
        "acl_get_permset_mask_np": ([ptr, ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int),
        "acl_get_flagset_np": ([ptr, ctypes.POINTER(ptr)], ctypes.c_int),
        "acl_get_flag_np": ([ptr, ctypes.c_uint32], ctypes.c_int),
        "acl_get_qualifier": ([ptr], ptr),
        "acl_create_entry": ([ctypes.POINTER(ptr), ctypes.POINTER(ptr)], ctypes.c_int),
        "acl_set_tag_type": ([ptr, ctypes.c_int], ctypes.c_int),
        "acl_set_qualifier": ([ptr, ptr], ctypes.c_int),
        "acl_set_permset_mask_np": ([ptr, ctypes.c_uint64], ctypes.c_int),
        "acl_valid": ([ptr], ctypes.c_int),
        "acl_set_fd_np": ([ctypes.c_int, ptr, ctypes.c_int], ctypes.c_int),
        "mbr_uid_to_uuid": ([ctypes.c_uint32, ptr], ctypes.c_int),
    }
    for name, (args, result) in declarations.items():
        fn = getattr(lib, name); fn.argtypes = args; fn.restype = result
    def require(ok):
        if not ok: raise ForgeInstanceBootstrapError("Forge exact account search ACL was rejected")
    identities = []
    for uid in sorted(set(uids)):
        require(uid > 0)
        b = (ctypes.c_ubyte * 16)(); require(lib.mbr_uid_to_uuid(uid, b) == 0); identities.append(bytes(b))
    def entries(acl):
        answer=[]; entry=ptr(); cursor=0
        while True:
            rc=lib.acl_get_entry(acl,cursor,ctypes.byref(entry))
            if rc == -1 and ctypes.get_errno() == errno.EINVAL: break
            require(rc==0 and entry.value); cursor=-1
            tag=ctypes.c_int(); mask=ctypes.c_uint64(); flags=ptr()
            require(lib.acl_get_tag_type(entry,ctypes.byref(tag))==0 and tag.value==1)
            require(lib.acl_get_permset_mask_np(entry,ctypes.byref(mask))==0 and mask.value==8)
            require(lib.acl_get_flagset_np(entry,ctypes.byref(flags))==0 and flags.value)
            require(all(lib.acl_get_flag_np(flags,f)==0 for f in [1,1<<4,1<<5,1<<6,1<<7,1<<8,1<<17]))
            q=lib.acl_get_qualifier(entry); require(q)
            try: identity=ctypes.string_at(q,16)
            finally:lib.acl_free(q)
            require(identity in identities and identity not in answer); answer.append(identity)
        return answer
    acl=ptr(lib.acl_get_fd_np(fd,0x100))
    if not acl.value:
        require(ctypes.get_errno()==errno.ENOENT); acl=ptr(lib.acl_init(len(identities))); require(acl.value)
    try:
        existing=entries(acl)
        for identity in identities:
            if identity in existing:continue
            entry=ptr(); require(lib.acl_create_entry(ctypes.byref(acl),ctypes.byref(entry))==0)
            require(lib.acl_set_tag_type(entry,1)==0)
            q=ctypes.create_string_buffer(identity,16); require(lib.acl_set_qualifier(entry,q)==0)
            require(lib.acl_set_permset_mask_np(entry,8)==0)
        require(lib.acl_valid(acl)==0 and lib.acl_set_fd_np(fd,acl,0x100)==0); os.fsync(fd)
    finally:lib.acl_free(acl)
    after=lib.acl_get_fd_np(fd,0x100); require(after)
    try:require(set(entries(after))==set(identities))
    finally:lib.acl_free(after)


def _private_directory(path: Path, uid=0, gid=0):
    try:os.mkdir(path,0o700)
    except FileExistsError:pass
    fd=_open(path,directory=True,owners=(0,uid))
    try:
        s=os.fstat(fd)
        if s.st_uid==0 and uid:
            os.fchown(fd,uid,gid);os.fsync(fd)
        elif s.st_uid!=uid or uid and s.st_gid!=gid:
            raise ForgeInstanceBootstrapError("Forge service folder belongs to another account")
    finally:os.close(fd)


def _credential_account_uids(authority, selected_name):
    """Resolve only identities pinned by the sealed worker authority.

    Named users need their v6 identity digest; an arbitrary existing Mac
    username is insufficient. Dedicated historical accounts retain their
    original route shape.
    """
    identities = [(r["forge_service_account"], r.get("forge_service_user_identity_sha256"))
                  for r in authority.get("routes", [])]
    identities += [(r["service_account"], r.get("service_user_identity_sha256"))
                   for r in authority.get("single_routes", [])
                   if r["component_identity"] == "forge-runtime"]
    identities += [(r["forge_service_account"], r.get("forge_service_user_identity_sha256"))
                   for r in authority.get("installation_routes", [])]
    if authority.get("schema") == "forge-platform.product-worker-authority/v7":
        unique = {}
        for name, identity in identities:
            if name in unique and unique[name] != identity:
                raise ForgeInstanceBootstrapError("Forge named-user cohort has conflicting identity pins")
            unique[name] = identity
        identities = list(unique.items())
    names = [name for name, _ in identities]
    if selected_name not in names or len(set(names)) != len(names):
        raise ForgeInstanceBootstrapError("Forge API credential cohort is ambiguous")
    uids = []
    for name, identity in identities:
        if re.fullmatch(r"_fpi_[0-9a-f]{20}", name):
            if identity is not None:
                raise ForgeInstanceBootstrapError("Dedicated Forge account has a named-user identity")
        elif (authority.get("schema") not in {"forge-platform.product-worker-authority/v6", "forge-platform.product-worker-authority/v7"}
              or not isinstance(identity, str)
              or resolve_identity_sha256(name) != identity):
            raise ForgeInstanceBootstrapError("Forge API credential named-user identity is invalid")
        uid = pwd.getpwnam(name).pw_uid
        if uid <= 0 or uid in uids:
            raise ForgeInstanceBootstrapError("Forge API credential UID cohort is invalid")
        uids.append(uid)
    return uids


class ManagedForgeInstanceBootstrap:
    def __init__(self, *, root: Path, target: ForgeServerTarget, artifact: QualifiedArtifact,
                 executable: Path, codex_executable: Path, codex_home: Path, codex_digest: str):
        self.root=root;self.target=target;self.artifact=artifact;self.executable=executable
        self.codex_executable=codex_executable;self.codex_home=codex_home;self.codex_digest=codex_digest
        if ((artifact.version!="2.7.39" and not qualified_forge_installation_pairing_artifact(artifact))
            or artifact.version=="2.8.1" and target.service_user_identity_sha256 is None
            or target.instances_root!=root/"instances/forge"
            or target.data_root!=target.instances_root/target.instance_id
            or target.api_credential_file!=root/"credentials/forge"/(target.instance_id+".token")
            or not re.fullmatch(r"fpi-[0-9a-f]{40}",target.instance_id)
            or not (re.fullmatch(r"_fpi_[0-9a-f]{20}",target.service_account)
                    or (target.service_user_identity_sha256 is not None
                        and resolve_identity_sha256(target.service_account) == target.service_user_identity_sha256))):
            raise ForgeInstanceBootstrapError("Forge bootstrap is outside the fixed qualified instance layout")
    def run(self,*args,allow_nonzero=False):
        account=pwd.getpwnam(self.target.service_account)
        if self.target.service_user_identity_sha256 is not None:
            if resolve_identity_sha256(self.target.service_account) != self.target.service_user_identity_sha256:
                raise ForgeInstanceBootstrapError("Forge reviewed operator identity drifted")
        if os.geteuid()!=0 or account.pw_uid<=0 or account.pw_gid<=0:
            raise ForgeInstanceBootstrapError("Forge service-account authority is unavailable")
        result=subprocess.run((str(self.executable),"--data-root",str(self.target.data_root),*args),
            cwd=str(self.target.data_root),user=account.pw_uid,group=account.pw_gid,extra_groups=(),
            env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":account.pw_dir,"PYTHONNOUSERSITE":"1","PYTHONSAFEPATH":"1"},
            text=True,capture_output=True,check=False,timeout=60)
        if result.returncode and not allow_nonzero:
            raise ForgeInstanceBootstrapError("Published Forge instance command rejected bootstrap")
        value=json.loads(result.stdout)
        if not isinstance(value,dict):raise ForgeInstanceBootstrapError("Forge bootstrap readback is not an object")
        return value
    def _ensure_operator_policy(self):
        if self.target.service_user_identity_sha256 is None:
            return
        # The approved named-operator route runs the unchanged product's own
        # administration APIs as that real user. Identity comes from macOS.
        account = pwd.getpwnam(self.target.service_account)
        if resolve_identity_sha256(account.pw_name) != self.target.service_user_identity_sha256:
            raise ForgeInstanceBootstrapError("Forge reviewed operator identity drifted")
        program = r"""
import json, sys
from forge._version import canonical_version
from forge.runtime.bootstrap import RuntimeBootstrap
from forge.operator_identity import InstallationOperatorService, MacOSGeneratedUIDIdentityAdapter
from forge.provider_context import ProviderExecutionContextService
from forge.provider_security import (PlanningProviderSecurityService, ProviderAuthenticationMode,
                                    CODEX_CLI_CHATGPT_SESSION_TYPE)
from forge.planner.codex_cli_session import CODEX_CLI_CHATGPT_SESSION_ADAPTER_VERSION
from forge.secure_store import MacOSKeychainSecureStoreAdapter
root=sys.argv[1]; provider='codex-chatgpt-session'
try:
    if canonical_version()!=sys.argv[2]: raise RuntimeError('unqualified product version')
    context=ProviderExecutionContextService(root).read(provider)
    database=RuntimeBootstrap(data_root=root,forge_version=canonical_version()).open()
    try:
        operators=InstallationOperatorService(database,MacOSGeneratedUIDIdentityAdapter().resolve)
        try: operator=operators.context()
        except PermissionError: operator=operators.first_bind()
        if not operators.authorize(operator): raise PermissionError('operator binding denied')
        security=PlanningProviderSecurityService(database,MacOSKeychainSecureStoreAdapter(),operators)
        policy=security.inspect(provider)
        if policy.get('state')=='NOT_CONFIGURED':
            policy=security.configure(configuration_id='installer-'+context.instance_id,
                provider_id=provider,reference=None,operator_context=operator,
                expected_version=0,enabled=True,model=None,timeout_seconds=120,
                input_token_bound=8192,context_token_bound=32768,output_token_bound=4096,
                authentication_mode=ProviderAuthenticationMode.EXTERNAL_AUTHENTICATED_SESSION,
                provider_type=context.provider_type,external_session_type=CODEX_CLI_CHATGPT_SESSION_TYPE,
                executable_path=context.executable_path,
                adapter_version=CODEX_CLI_CHATGPT_SESSION_ADAPTER_VERSION,profile=context.profile)
        if (not policy.get('enabled') or policy.get('authentication_mode')!='EXTERNAL_AUTHENTICATED_SESSION'
            or policy.get('executable_path')!=context.executable_path
            or policy.get('provider_type')!=context.provider_type or policy.get('profile')!=context.profile):
            raise PermissionError('provider policy and instance context differ')
        print(json.dumps({'status':'canonical-operator-policy-ready','instance_id':context.instance_id}))
    finally: database.close()
except Exception as error:
    print(json.dumps({'status':'canonical-administration-rejected','error_class':type(error).__name__}))
    sys.exit(1)
"""
        result = subprocess.run((str(self.executable.parent/"python3"), "-I", "-B", "-c", program,
                                 str(self.target.data_root), self.artifact.version),
            cwd=str(self.target.data_root), user=account.pw_uid, group=account.pw_gid, extra_groups=(),
            env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":account.pw_dir},
            text=True,capture_output=True,check=False,timeout=30)
        if result.returncode:
            raise ForgeInstanceBootstrapError("Published Forge operator administration rejected bootstrap")
        value=json.loads(result.stdout)
        if value.get("status") != "canonical-operator-policy-ready" or value.get("instance_id") != self.target.product_runtime_id:
            raise ForgeInstanceBootstrapError("Forge operator administration identity drifted")

    def pending_runtime(self, status):
        """Observe only the exact account-owned bootstrap admitted by its intent."""
        path = binding_path(self.target).parent / (self.target.instance_id + ".intent.json")
        try:
            intent = _record(path)
        except FileNotFoundError:
            return None
        expected = {"schema": "forge-platform.forge-bootstrap-intent/v1",
                    "selector": self.target.instance_id, "data_root": str(self.target.data_root),
                    "service_account": self.target.service_account,
                    "artifact": {"version": self.artifact.version, "digest": self.artifact.digest,
                                 "source_revision": self.artifact.source_revision},
                    "codex_executable": str(self.codex_executable), "codex_home": str(self.codex_home)}
        if (set(intent) != set(expected) | {"operation_id"}
            or any(intent[k] != v for k,v in expected.items())
            or not re.fullmatch(r"product-[0-9a-f]{64}", intent["operation_id"])):
            raise ForgeInstanceBootstrapError("Forge pending bootstrap intent changed")
        account = pwd.getpwnam(self.target.service_account)
        fd = _open(self.target.data_root, directory=True, owners=(account.pw_uid,))
        os.close(fd)
        runtime = status.get("instance_id")
        if (status.get("initialized") is not True or status.get("data_root") != str(self.target.data_root)
            or status.get("product_version") != self.artifact.version
            or not isinstance(runtime,str)
            or not re.fullmatch(r"forge-runtime-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",runtime)):
            raise ForgeInstanceBootstrapError("Forge pending product identity changed")
        return runtime

    def ensure(self,operation_id):
        account=pwd.getpwnam(self.target.service_account)
        fd = _open(self.codex_executable, modes=(0o500,))
        try:
            digest = hashlib.sha256()
            with os.fdopen(fd, "rb", closefd=False) as binary:
                for chunk in iter(lambda: binary.read(1024 * 1024), b""):
                    digest.update(chunk)
            if "sha256:" + digest.hexdigest() != self.codex_digest:
                raise ForgeInstanceBootstrapError("Forge Codex executable differs from signed selection")
        finally: os.close(fd)
        home = _open(self.codex_home, directory=True, owners=(account.pw_uid,))
        os.close(home)
        parent=binding_path(self.target).parent
        _private_directory(parent)
        identity={"version":self.artifact.version,"digest":self.artifact.digest,"source_revision":self.artifact.source_revision}
        prior=read_runtime_binding(self.target)
        if prior is not None:
            if prior["artifact"]!=identity:raise ForgeInstanceBootstrapError("Forge bootstrap artifact changed")
            status = self.run("server", "status")
            context = self.run("server", "provider-context", "show", "--provider-id", "codex-chatgpt-session")
            if (status.get("instance_id") != prior["runtime_id"]
                or status.get("data_root") != str(self.target.data_root)
                or status.get("product_version") != self.artifact.version
                or context.get("instance_id") != prior["runtime_id"]
                or context.get("configuration_digest") != prior["provider_context_digest"]
                or context.get("executable_path") != str(self.codex_executable)
                or context.get("provider_home") != str(self.codex_home)):
                raise ForgeInstanceBootstrapError("Forge bootstrap binding or provider context drifted")
            self._ensure_operator_policy()
            self._ensure_api_credential(account)
            return prior
        intent={"schema":"forge-platform.forge-bootstrap-intent/v1","operation_id":operation_id,
                "selector":self.target.instance_id,"data_root":str(self.target.data_root),
                "service_account":self.target.service_account,"artifact":identity,
                "codex_executable":str(self.codex_executable),"codex_home":str(self.codex_home)}
        _publish(parent/(self.target.instance_id+".intent.json"),intent)
        for path in [self.root/"instances",self.target.instances_root]:
            try:os.mkdir(path,0o755)
            except FileExistsError:pass
            fd=_open(path,directory=True,modes=(0o755,));os.close(fd)
        if self.target.data_root.exists():
            details = self.target.data_root.lstat()
            if details.st_uid == 0 and set(os.listdir(self.target.data_root)) - {"logs"}:
                raise ForgeInstanceBootstrapError("Forge bootstrap refuses unknown existing root-owned data")
        _private_directory(self.target.data_root,account.pw_uid,account.pw_gid)
        _private_directory(self.target.data_root/"logs",account.pw_uid,account.pw_gid)
        initialized=self.run("server","init")
        runtime=initialized.get("instance_id")
        if (initialized.get("initialized") is not True or initialized.get("product_version")!=self.artifact.version
            or not isinstance(runtime,str) or not re.fullmatch(r"forge-runtime-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",runtime)
            or initialized.get("data_root")!=str(self.target.data_root)):
            raise ForgeInstanceBootstrapError("Forge init did not identify the exact product-owned runtime")
        context = self.run("server","provider-context","show","--provider-id","codex-chatgpt-session",allow_nonzero=True)
        if context.get("instance_id") is None:
            context=self.run("server","provider-context","configure","--provider-id","codex-chatgpt-session",
                "--provider-type","CODEX_CLI_CHATGPT_SESSION","--executable-path",str(self.codex_executable),
                "--provider-home",str(self.codex_home),"--provider-config-home",str(self.codex_home))
        observed=self.run("server","provider-context","show","--provider-id","codex-chatgpt-session")
        if (context!=observed or context.get("instance_id")!=runtime
            or context.get("executable_path")!=str(self.codex_executable)
            or context.get("provider_home")!=str(self.codex_home)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}",context.get("configuration_digest", ""))):
            raise ForgeInstanceBootstrapError("Forge provider context changed during exact bootstrap")
        binding={"schema":"forge-platform.forge-runtime-binding/v1","selector":self.target.instance_id,
                 "data_root":str(self.target.data_root),"service_account":self.target.service_account,
                 "runtime_id":runtime,"artifact":identity,"provider_context_digest":context["configuration_digest"]}
        _publish(binding_path(self.target),binding)
        self._ensure_operator_policy()
        self._ensure_api_credential(account)
        return binding

    def _ensure_api_credential(self, account):
        # Generate only the local service API credential in the already selected
        # bounded route, after product initialization/context are complete.
        authority = _record(self.root / "product-worker-authority.json", maximum=4 * 1024 * 1024)
        uids = _credential_account_uids(authority, self.target.service_account)
        for path in [self.root/"credentials",self.root/"credentials/forge"]:
            _private_directory(path)
            fd=_open(path,directory=True)
            try:_search(fd,uids)
            finally:os.close(fd)
        credential=self.target.api_credential_file
        try:fd=_open(credential,owners=(account.pw_uid,),modes=(0o600,))
        except FileNotFoundError:
            directory=_open(credential.parent,directory=True)
            temporary="."+credential.name+".new-"+secrets.token_hex(8)
            fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=directory)
            try:
                os.fchown(fd,account.pw_uid,account.pw_gid)
                with os.fdopen(fd,"wb",closefd=False) as out:
                    out.write(secrets.token_urlsafe(48).encode()+b"\n");out.flush();os.fsync(fd)
                os.link(temporary,credential.name,src_dir_fd=directory,dst_dir_fd=directory,follow_symlinks=False)
                os.unlink(temporary,dir_fd=directory);os.fsync(directory)
            finally:
                os.close(fd);os.close(directory)
        else:os.close(fd)
