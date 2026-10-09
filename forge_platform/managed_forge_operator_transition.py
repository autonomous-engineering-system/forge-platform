"""Bounded filesystem preparation for a reviewed Forge operator transition.

This module does not start an operation or edit product databases. Its caller
must hold the installer mutation lease, verify the real product operator, stop
only the selected product through its normal supervisor, and preserve evidence.
Credential files are opened for metadata only; no credential bytes are read.
"""
from __future__ import annotations
from dataclasses import dataclass
import ctypes
import errno
import os
from pathlib import Path
import stat

from .managed_forge_instance_bootstrap import ForgeInstanceBootstrapError


def _require_no_extended_grants(fd):
    lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    pointer=ctypes.c_void_p
    lib.acl_get_fd_np.argtypes=[ctypes.c_int,ctypes.c_int];lib.acl_get_fd_np.restype=pointer
    lib.acl_get_entry.argtypes=[pointer,ctypes.c_int,ctypes.POINTER(pointer)];lib.acl_get_entry.restype=ctypes.c_int
    lib.acl_free.argtypes=[pointer];lib.acl_free.restype=ctypes.c_int
    acl=lib.acl_get_fd_np(fd,0x100)
    if not acl:
        if ctypes.get_errno()==errno.ENOENT:return
        raise ForgeInstanceBootstrapError('Forge ownership ACL is unavailable')
    try:
        entry=pointer();result=lib.acl_get_entry(acl,0,ctypes.byref(entry))
        if result!=-1 or ctypes.get_errno()!=errno.EINVAL:
            raise ForgeInstanceBootstrapError('Forge ownership path has unreviewed ACL grants')
    finally:lib.acl_free(acl)


@dataclass
class _Node:
    fd: int
    path: Path
    parent: int | None
    name: str | None
    original: os.stat_result
    children: tuple[str, ...] | None


class ReviewedForgeOwnershipPreparation:
    """Hold every inode before mutation; reject a partial or unsafe tree.

    All approved roots must be supplied by the helper's sealed review. Paths
    are never accepted directly from a CLI request. Symlinks are admitted only
    as provider-generated wrappers pointing at the exact reviewed executable;
    they are neither followed nor changed.
    """
    def __init__(self, *, data_root: Path, provider_home: Path, api_credential: Path,
                 provider_executable: Path, old_uid: int, old_gid: int,
                 new_uid: int, new_gid: int):
        if (min(old_uid, old_gid, new_uid, new_gid) <= 0 or old_uid == new_uid
            or any(not p.is_absolute() for p in
                   (data_root, provider_home, api_credential, provider_executable))):
            raise ForgeInstanceBootstrapError("Forge ownership review is invalid")
        self.old_uid=old_uid; self.old_gid=old_gid
        self.new_uid=new_uid; self.new_gid=new_gid
        self.nodes=[]; self.links=[]
        self.applied=False
        try:
            self._walk(data_root, provider=False, executable=provider_executable)
            self._walk(provider_home, provider=True, executable=provider_executable)
            self._open(api_credential, provider=False, credential=True)
            self.validate()
        except BaseException:
            self.close(); raise

    @staticmethod
    def _identity(s):
        return (s.st_dev, s.st_ino, s.st_uid, s.st_gid, s.st_mode, s.st_nlink)

    def _open(self, path, *, provider, credential=False, parent=None, name=None):
        flags=os.O_RDONLY|os.O_CLOEXEC|getattr(os,"O_NOFOLLOW_ANY",0x20000000)
        if parent is not None:
            flags=os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW
        fd=os.open(path if parent is None else name, flags, dir_fd=parent)
        try:
            s=os.fstat(fd); mode=stat.S_IMODE(s.st_mode)
            directory=stat.S_ISDIR(s.st_mode)
            if ((s.st_uid,s.st_gid)!=(self.old_uid,self.old_gid)
                or not (directory or stat.S_ISREG(s.st_mode))
                or not directory and s.st_nlink!=1
                or directory and mode not in ((0o700,0o755) if provider else (0o700,))
                or not directory and mode not in ((0o600,) if credential else (0o600,0o644))
                or credential and directory):
                raise ForgeInstanceBootstrapError("Forge ownership path metadata is unsafe")
            _require_no_extended_grants(fd)
            children=tuple(sorted(os.listdir(fd))) if directory else None
            node=_Node(fd,path,parent,name,s,children)
            self.nodes.append(node)
            return node
        except BaseException:
            os.close(fd); raise

    def _walk(self, path, *, provider, executable, parent=None, name=None, depth=0):
        if depth>32 or len(self.nodes)>2048:
            raise ForgeInstanceBootstrapError("Forge ownership tree exceeds review bounds")
        node=self._open(path,provider=provider,parent=parent,name=name)
        if node.children is None:return
        for child in node.children:
            s=os.stat(child,dir_fd=node.fd,follow_symlinks=False)
            if stat.S_ISLNK(s.st_mode):
                if (not provider or (s.st_uid,s.st_gid)!=(self.old_uid,self.old_gid)
                    or os.readlink(child,dir_fd=node.fd)!=str(executable)):
                    raise ForgeInstanceBootstrapError("Forge provider symlink is outside the reviewed executable")
                self.links.append((node.fd,child,self._identity(s),str(executable)))
                continue
            self._walk(path/child,provider=provider,executable=executable,
                       parent=node.fd,name=child,depth=depth+1)

    def validate(self):
        for node in self.nodes:
            _require_no_extended_grants(node.fd)
            if self._identity(os.fstat(node.fd))!=self._identity(node.original):
                raise ForgeInstanceBootstrapError("Forge ownership inode changed during review")
            if node.parent is not None and self._identity(os.stat(node.name,dir_fd=node.parent,follow_symlinks=False))!=self._identity(node.original):
                raise ForgeInstanceBootstrapError("Forge ownership path changed during review")
            if node.parent is None:
                check=os.open(node.path,os.O_RDONLY|os.O_CLOEXEC|getattr(os,"O_NOFOLLOW_ANY",0x20000000))
                try:
                    if self._identity(os.fstat(check))!=self._identity(node.original):
                        raise ForgeInstanceBootstrapError("Forge ownership root changed during review")
                finally:os.close(check)
            if node.children is not None and tuple(sorted(os.listdir(node.fd)))!=node.children:
                raise ForgeInstanceBootstrapError("Forge ownership directory changed during review")
        for parent,name,identity,target in self.links:
            if (self._identity(os.stat(name,dir_fd=parent,follow_symlinks=False))!=identity
                or os.readlink(name,dir_fd=parent)!=target):
                raise ForgeInstanceBootstrapError("Forge provider wrapper changed during review")

    def apply_after_service_stop(self, *, selected_service_is_stopped):
        if os.geteuid()!=0 or self.applied or selected_service_is_stopped() is not True:
            raise ForgeInstanceBootstrapError("Forge ownership preparation requires the selected stopped service")
        self.validate()
        # Children before parents keeps the selected private roots inaccessible
        # to the new owner until their contents have been prepared.
        for node in reversed(self.nodes):
            os.fchown(node.fd,self.new_uid,self.new_gid)
            s=os.fstat(node.fd)
            if ((s.st_uid,s.st_gid)!=(self.new_uid,self.new_gid)
                or (s.st_dev,s.st_ino,s.st_mode,s.st_nlink)!=(node.original.st_dev,node.original.st_ino,node.original.st_mode,node.original.st_nlink)):
                raise ForgeInstanceBootstrapError("Forge ownership readback failed")
            os.fsync(node.fd)
        self.applied=True
        return {"status":"OWNERSHIP_PREPARED","inodes":len(self.nodes),
                "provider_wrappers_preserved":len(self.links),"credential_bytes_read":False}

    def close(self):
        for node in reversed(self.nodes):os.close(node.fd)
        self.nodes=[]

    def __enter__(self):return self
    def __exit__(self,*args):self.close()
