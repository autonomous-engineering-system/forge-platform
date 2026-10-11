"""Closed V1/companion binding; no signing, credential or network effects."""
from copy import deepcopy
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat

CAPABILITY = "helper-package-companion/v1"
ASSET_NAME = "ForgePlatformInstallerHelperDescriptor.json"
MAXIMUM_BYTES = 128 * 1024


def no_extended_acl(descriptor):
    import ctypes
    import errno
    import sys
    if sys.platform != "darwin":
        return "system.posix_acl_access" not in os.listxattr(descriptor)
    library=ctypes.CDLL("/usr/lib/libSystem.B.dylib",use_errno=True)
    library.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int];library.acl_get_fd_np.restype=ctypes.c_void_p
    library.acl_get_entry.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_void_p)]
    library.acl_valid.argtypes=[ctypes.c_void_p];library.acl_free.argtypes=[ctypes.c_void_p]
    ctypes.set_errno(0);acl=library.acl_get_fd_np(descriptor,0x100)
    if not acl:return ctypes.get_errno()==errno.ENOENT
    try:
        if library.acl_valid(acl)!=0:return False
        entry=ctypes.c_void_p();ctypes.set_errno(0)
        return library.acl_get_entry(acl,0,ctypes.byref(entry))==-1 and ctypes.get_errno()==errno.EINVAL
    finally:library.acl_free(acl)


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=True,allow_nan=False).encode()


def strict_object(raw):
    if not isinstance(raw,bytes) or not 0 < len(raw) <= MAXIMUM_BYTES:
        raise ValueError("helper companion exceeds bound")
    def pairs(items):
        result={}
        for key,value in items:
            if key in result:raise ValueError("duplicate companion field")
            result[key]=value
        return result
    def constant(_):raise ValueError("nonfinite companion field")
    value=json.loads(raw.decode("utf-8"),object_pairs_hook=pairs,parse_constant=constant)
    if not isinstance(value,dict):raise ValueError("companion must be an object")
    return value


def read_document(path):
    path=Path(path)
    if path.name!=ASSET_NAME:raise ValueError("companion input name invalid")
    fd=os.open(path,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or not 0<before.st_size<=MAXIMUM_BYTES:
            raise ValueError("companion input is not a bounded single-link regular file")
        raw=b""
        while len(raw)<before.st_size:
            block=os.read(fd,min(65536,before.st_size-len(raw)))
            if not block:raise ValueError("truncated companion input")
            raw+=block
        if os.read(fd,1):raise ValueError("companion input grew")
        fields=("st_dev","st_ino","st_mode","st_uid","st_gid","st_nlink","st_size","st_mtime_ns","st_ctime_ns")
        if any(getattr(before,k)!=getattr(other,k) for other in (os.fstat(fd),path.lstat()) for k in fields):
            raise ValueError("companion input changed")
        return raw,(before.st_dev,before.st_ino)
    finally:os.close(fd)


def requires_companion(primary):
    installer=primary.get("installer")
    capabilities=installer.get("capabilities") if isinstance(installer,dict) else None
    return isinstance(capabilities,list) and CAPABILITY in capabilities


def qualification_binding(operation):
    reference=operation.qualification.qualification_receipt_reference
    match=re.fullmatch(r"receipt:local-signing-qualification-[1-9][0-9]*-helper-([0-9a-f]{64})",reference)
    return "sha256:"+match[1] if match else None


def bound_metadata(primary_raw,companion_raw,expected_digest):
    from forge_platform.universal_installer import InstallerHelperPackage
    primary=strict_object(primary_raw);companion=strict_object(companion_raw)
    if (not requires_companion(primary) or primary.get("schema")!="forge-platform.installer-release/v1"
        or set(companion)!=set(primary)|{"primary_descriptor_digest"}
        or companion.get("schema")!="forge-platform.installer-release/v2"
        or companion.get("primary_descriptor_digest")!="sha256:"+sha256(primary_raw).hexdigest()
        or expected_digest!="sha256:"+sha256(companion_raw).hexdigest()):
        raise ValueError("helper companion does not bind primary/qualified digest")
    assets=companion.get("installer",{}).get("assets")
    if not isinstance(assets,list) or len(assets)!=1 or not isinstance(assets[0],dict):
        raise ValueError("companion requires one asset")
    metadata=assets[0].get("helper_package")
    InstallerHelperPackage.from_mapping(metadata)
    cleaned=deepcopy(companion)
    cleaned.pop("primary_descriptor_digest");cleaned.pop("signatures",None);cleaned["schema"]=primary["schema"]
    for asset in cleaned["installer"]["assets"]:asset.pop("helper_package")
    unsigned=deepcopy(primary);unsigned.pop("signatures",None)
    if canonical(cleaned)!=canonical(unsigned):raise ValueError("companion release fields conflict with primary")
    if not isinstance(companion.get("signatures"),list) or not companion["signatures"]:
        raise ValueError("companion signatures missing")
    return metadata


class FileHelperCompanionAcceptanceStore:
    """Durable second anchor; caller owns a fixed private installer namespace."""
    def __init__(self,root):
        self.root=Path(root)

    def accept(self,sequence,digest):
        import fcntl
        import uuid
        if type(sequence) is not int or sequence<=0 or not isinstance(digest,str) or re.fullmatch(r"sha256:[0-9a-f]{64}",digest) is None:
            raise ValueError("companion anchor identity invalid")
        if not self.root.is_absolute() or self.root.resolve()!=self.root:
            raise ValueError("companion anchor root must be physical and absolute")
        self.root.mkdir(mode=0o700,parents=False,exist_ok=True)
        parent=os.open(self.root.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(parent)
        finally:os.close(parent)
        root=os.open(self.root,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        def secure(fd,directory=False):
            st=os.fstat(fd)
            if (st.st_uid!=os.geteuid() or stat.S_IMODE(st.st_mode)!=(0o700 if directory else 0o600)
                or not (stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode))
                or (not directory and st.st_nlink!=1) or not no_extended_acl(fd)):
                raise ValueError("companion anchor ownership/type/mode invalid")
            return st
        lock=None
        try:
            secure(root,True)
            lock=os.open("anchor.lock",os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600,dir_fd=root)
            secure(lock);fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            name="highest-accepted-installer-release.json"
            if set(os.listdir(root))-{name,"anchor.lock"}:raise ValueError("unresolved companion anchor files")
            try:fd=os.open(name,os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW,dir_fd=root)
            except FileNotFoundError:old=None
            else:
                try:
                    before=secure(fd)
                    if not 0<before.st_size<=4096:raise ValueError("companion anchor exceeds bound")
                    raw=os.read(fd,4097)
                    if len(raw)!=before.st_size or os.read(fd,1):raise ValueError("companion anchor changed")
                    after=secure(fd);named=os.stat(name,dir_fd=root,follow_symlinks=False)
                    fields=("st_dev","st_ino","st_mode","st_uid","st_nlink","st_size","st_mtime_ns","st_ctime_ns")
                    if any(getattr(before,k)!=getattr(other,k) for other in (after,named) for k in fields):raise ValueError("companion anchor changed")
                    old=strict_object(raw)
                    if (set(old)!={"sequence","descriptorSHA256"} or type(old["sequence"]) is not int or old["sequence"]<=0
                        or not isinstance(old["descriptorSHA256"],str) or re.fullmatch(r"[0-9a-f]{64}",old["descriptorSHA256"]) is None):
                        raise ValueError("companion anchor corrupt")
                finally:os.close(fd)
            raw_digest=digest.removeprefix("sha256:")
            if old is not None:
                if sequence<old["sequence"] or (sequence==old["sequence"] and raw_digest!=old["descriptorSHA256"]):
                    raise ValueError("companion replay/equivocation")
                if sequence==old["sequence"]:
                    secure(root,True);secure(lock);os.fsync(root)
                    held=os.fstat(root);named=self.root.lstat()
                    if (held.st_dev,held.st_ino)!=(named.st_dev,named.st_ino):raise ValueError("companion anchor root changed")
                    return
            temporary="anchor-"+str(uuid.uuid4())+".tmp"
            fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=root)
            try:
                secure(fd);raw=canonical({"sequence":sequence,"descriptorSHA256":raw_digest})+b"\n"
                if os.write(fd,raw)!=len(raw):raise ValueError("companion anchor write incomplete")
                os.fsync(fd);secure(fd)
            finally:os.close(fd)
            secure(root,True);secure(lock)
            os.rename(temporary,name,src_dir_fd=root,dst_dir_fd=root);os.fsync(root)
            secure(root,True);secure(lock)
            held=os.fstat(root);named=self.root.lstat()
            if (held.st_dev,held.st_ino)!=(named.st_dev,named.st_ino):raise ValueError("companion anchor root changed")
        finally:
            if lock is not None:os.close(lock)
            os.close(root)
