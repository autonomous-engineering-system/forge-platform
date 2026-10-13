"""Bounded EP service paths, selected only by admitted installer authority.

EP owns initialization and service lifecycle. This preparation grants its exact
service UID access to three private mutable folders; no provider content is read.
It does not launch a service or retire historical worker uncertainty.
"""
from __future__ import annotations

import ctypes
import errno
import grp
from hashlib import sha256
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import uuid


class EPServicePreparationError(RuntimeError):
    pass


# Darwin sys/acl.h: data permissions only, never write-security/change-owner.
_DIRECTORY_MASK = sum(1 << bit for bit in (1, 2, 3, 5, 6, 7, 8))
_FILE_MASK = sum(1 << bit for bit in (1, 2, 5, 7, 8))
_INHERITED, _FILE_INHERIT, _DIRECTORY_INHERIT, _ONLY_INHERIT = 16, 32, 64, 256
_FLAGS = (1, 16, 32, 64, 128, 256, 1 << 17)


def _require(condition: bool) -> None:
    if not condition:
        raise EPServicePreparationError("EP service path preparation was rejected")


def _open(path: Path, *, directory: bool, owners=(0,)) -> int:
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
                 | getattr(os, "O_NOFOLLOW_ANY", 0x20000000)
                 | (os.O_DIRECTORY if directory else 0))
    try:
        s = os.fstat(fd)
        _require(s.st_uid in owners and s.st_flags == 0
                 and stat.S_IMODE(s.st_mode) == (0o700 if directory else 0o600)
                 and (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode))
                 and (directory or s.st_nlink == 1))
        return fd
    except BaseException:
        os.close(fd)
        raise


def _acl(fd: int, uid: int, *, directory: bool, read_only: bool = False) -> None:
    """Exact two-entry inherited profile, pinned to an open private inode."""
    _require(sys.platform == "darwin" and uid > 0)
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
        "acl_add_flag_np": ([ptr, ctypes.c_uint32], ctypes.c_int),
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
    identity = (ctypes.c_ubyte * 16)()
    _require(lib.mbr_uid_to_uuid(uid, identity) == 0)
    wanted = {(_DIRECTORY_MASK, _DIRECTORY_INHERIT),
              (_FILE_MASK, _FILE_INHERIT | _DIRECTORY_INHERIT | _ONLY_INHERIT)} if directory else {(_FILE_MASK, 0)}

    def entries(acl):
        found = set(); entry = ptr(); cursor = 0
        while True:
            ctypes.set_errno(0)
            rc = lib.acl_get_entry(acl, cursor, ctypes.byref(entry))
            if rc == -1 and ctypes.get_errno() == errno.EINVAL:
                break
            _require(rc == 0 and bool(entry.value)); cursor = -1
            tag = ctypes.c_int(); mask = ctypes.c_uint64(); flags = ptr()
            _require(lib.acl_get_tag_type(entry, ctypes.byref(tag)) == 0 and tag.value == 1)
            _require(lib.acl_get_permset_mask_np(entry, ctypes.byref(mask)) == 0)
            _require(lib.acl_get_flagset_np(entry, ctypes.byref(flags)) == 0 and bool(flags.value))
            bits = 0
            for flag in _FLAGS:
                value = lib.acl_get_flag_np(flags, flag); _require(value in (0, 1))
                if value: bits |= flag
            qualifier = lib.acl_get_qualifier(entry); _require(bool(qualifier))
            try: _require(ctypes.string_at(qualifier, 16) == bytes(identity))
            finally: lib.acl_free(qualifier)
            # Inheritance provenance is allowed, the rights profile is exact.
            item = (mask.value, bits & ~_INHERITED)
            # Darwin removes ONLY_INHERIT when propagating this entry to a
            # child directory. Admit only that exact inherited OS profile.
            if (directory and bits & _INHERITED and item ==
                    (_FILE_MASK, _FILE_INHERIT | _DIRECTORY_INHERIT)):
                item = (_FILE_MASK, _FILE_INHERIT | _DIRECTORY_INHERIT | _ONLY_INHERIT)
            _require(item in wanted and item not in found); found.add(item)
        return found

    acl = ptr(lib.acl_get_fd_np(fd, 0x100))
    if not acl.value:
        _require(not read_only)
        _require(ctypes.get_errno() == errno.ENOENT)
        acl = ptr(lib.acl_init(len(wanted))); _require(bool(acl.value))
    try:
        existing = entries(acl)
        _require(not read_only or existing == wanted)
        for mask, bits in sorted(wanted - existing):
            entry = ptr(); _require(lib.acl_create_entry(ctypes.byref(acl), ctypes.byref(entry)) == 0)
            _require(lib.acl_set_tag_type(entry, 1) == 0)
            _require(lib.acl_set_qualifier(entry, identity) == 0)
            _require(lib.acl_set_permset_mask_np(entry, mask) == 0)
            flags = ptr(); _require(lib.acl_get_flagset_np(entry, ctypes.byref(flags)) == 0)
            for flag in _FLAGS:
                if bits & flag: _require(lib.acl_add_flag_np(flags, flag) == 0)
        if existing != wanted:
            _require(lib.acl_valid(acl) == 0 and lib.acl_set_fd_np(fd, acl, 0x100) == 0)
            os.fsync(fd)
    finally:
        lib.acl_free(acl)
    after = lib.acl_get_fd_np(fd, 0x100); _require(bool(after))
    try: _require(entries(after) == wanted)
    finally: lib.acl_free(after)


class ManagedEPServicePreparation:
    """Inert constructor. Caller must hold admitted component/deployment leases."""
    data_files = frozenset({"server.json", "runtime-identity.json", "operational-installation.json",
                            "epdata.sqlite", "epdata.sqlite-wal", "epdata.sqlite-shm", "runtime.json"})

    def __init__(self, *, product_root: Path, instance_id: str,
                 service_account: str, uid: int | None = None, gid: int | None = None,
                 cohort_accounts: tuple[str,...] = (), authority_sha256: str | None = None):
        _require(product_root.is_absolute() and product_root.name == "engineering-platform"
                 and product_root.parent.name == "products")
        _require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", instance_id) is not None
                 and instance_id not in {".", ".."}
                 and re.fullmatch(r"_[A-Za-z][A-Za-z0-9_]{0,253}", service_account) is not None
                 and (uid is None and gid is None or isinstance(uid,int) and isinstance(gid,int)
                      and uid > 0 and gid > 0))
        self.product_root, self.instance_id, self.service_account = product_root, instance_id, service_account
        self.uid, self.gid = uid, gid
        self.account_identity = None
        self.cohort_accounts, self.authority_sha256 = cohort_accounts, authority_sha256

    def bind_account(self):
        _require(re.fullmatch(r"_fpi_[0-9a-f]{20}", self.service_account) is not None)
        account = pwd.getpwnam(self.service_account)
        expected_id = 200_000 + int.from_bytes(sha256(self.service_account.encode()).digest()[:4],"big") % 500_000
        _require(account.pw_name == self.service_account
                 and account.pw_uid == expected_id and account.pw_gid == expected_id
                 and pwd.getpwuid(expected_id).pw_name == self.service_account
                 and grp.getgrgid(expected_id).gr_name == "_fpi_g_"+self.service_account[5:])
        if self.uid is None:
            self.uid, self.gid = account.pw_uid, account.pw_gid
        identity = self._identity()
        _require(self.account_identity is None or self.account_identity == identity)
        self.account_identity = identity
        self._account()

    def _identity(self):
        result = subprocess.run(["/usr/bin/dscl", ".", "-read", "/Users/"+self.service_account,
            "GeneratedUID", "UniqueID", "PrimaryGroupID", "NFSHomeDirectory", "UserShell",
            "AuthenticationAuthority"], stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=5, env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin"})
        _require(result.returncode == 0 and len(result.stdout) < 4096)
        values = {}
        for line in result.stdout.splitlines():
            key, separator, value = line.partition(":")
            _require(bool(separator) and key not in values)
            values[key] = value.strip()
        _require(set(values) == {"GeneratedUID","UniqueID","PrimaryGroupID",
            "NFSHomeDirectory","UserShell","AuthenticationAuthority"})
        _require(values["UniqueID"] == str(self.uid) and values["PrimaryGroupID"] == str(self.gid)
                 and values["NFSHomeDirectory"] == "/var/empty"
                 and values["UserShell"] == "/usr/bin/false"
                 and values["AuthenticationAuthority"] == ";DisabledUser;")
        identifier = str(uuid.UUID(values["GeneratedUID"])).lower()
        return (self.uid,self.gid,identifier)

    def _account(self):
        account = pwd.getpwnam(self.service_account)
        _require(account.pw_name == self.service_account and self.uid is not None
                 and account.pw_uid == self.uid and account.pw_gid == self.gid)
        _require(self.account_identity is not None and self._identity() == self.account_identity)

    def prepare(self) -> None:
        _require(os.geteuid() == 0 and sys.platform == "darwin")
        self._account()
        from .managed_ep_partial_create import _json
        from .managed_forge_instance_bootstrap import _search
        authority_path = self.product_root.parent.parent/"product-worker-authority.json"
        _, authority_digest = _json(authority_path, maximum=4*1024*1024)
        _require(self.authority_sha256 == authority_digest and self.service_account in self.cohort_accounts)
        identities = []
        cohort = []
        for name in sorted(set(self.cohort_accounts)):
            account = ManagedEPServicePreparation(product_root=self.product_root,
                instance_id=self.instance_id,service_account=name)
            account.bind_account();identities.append(account.account_identity);cohort.append(account)
        instance = self.product_root / "instances" / self.instance_id
        # Open every ancestor without following links; existing search ACLs stay intact.
        held = []
        try:
            for path in (self.product_root, instance.parent, instance):
                held.append(_open(path, directory=True))
            for index,descriptor in enumerate(held):
                for account in cohort:account._account()
                _, current_digest = _json(authority_path, maximum=4*1024*1024)
                _require(current_digest == authority_digest)
                _search(descriptor,[identity[0] for identity in identities] if index<2 else [self.uid])
                for account in cohort:account._account()
            for name in ("data", "logs", "service-home"):
                self._account()
                try: os.mkdir(name, 0o700, dir_fd=held[-1])
                except FileExistsError: pass
                path = instance / name
                fd = _open(path, directory=True)
                try:
                    before = os.fstat(fd)
                    # The partial CREATE allowlist is metadata only; never read data bytes.
                    names = os.listdir(fd)
                    if name == "data": _require(set(names) <= self.data_files)
                    elif name == "logs": _require(set(names) <= {"server-launchdaemon.err.log"})
                    else: _require(not names)
                    _acl(fd, self.uid, directory=True)
                    if name == "logs" and not names:
                        log = os.open("server-launchdaemon.err.log", os.O_WRONLY | os.O_CREAT
                                      | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600, dir_fd=fd)
                        os.fsync(log); os.close(log); os.fsync(fd)
                        names = ["server-launchdaemon.err.log"]
                    for child in names:
                        self._account()
                        child_fd = _open(path / child, directory=False, owners=(0,self.uid))
                        try:
                            child_before = os.fstat(child_fd)
                            _acl(child_fd, self.uid, directory=False)
                            child_after = os.stat(child, dir_fd=fd, follow_symlinks=False)
                            _require((child_before.st_dev, child_before.st_ino)
                                     == (child_after.st_dev, child_after.st_ino))
                        finally: os.close(child_fd)
                    after = os.stat(name, dir_fd=held[-1], follow_symlinks=False)
                    _require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino))
                finally: os.close(fd)
            self._account()
        finally:
            for fd in reversed(held): os.close(fd)
