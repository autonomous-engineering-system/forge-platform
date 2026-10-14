"""Exact service SEARCH access to an admitted managed Python runtime.

Inert assembly only; prepare is a separate mutating component boundary. It
never selects accounts or runtime paths from an IPC caller or from PATH.
"""
from __future__ import annotations

import ctypes
from dataclasses import dataclass
from hashlib import sha256
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import uuid

from .installer_helper_companion import no_extended_acl
from .managed_ep_partial_create import _json
from .managed_forge_instance_bootstrap import _search
from .managed_historical_product_evidence import _runtime_acl
from .managed_installer_user_identity import canonical_identity, resolve_identity_sha256
from .universal_installer import CompositionManifest


class RuntimeServiceAccessError(RuntimeError):
    pass


def _require(value):
    if not value:
        raise RuntimeServiceAccessError("selected product runtime access was rejected")


@dataclass(frozen=True)
class _Claim:
    name: str
    instance_id: str
    named_identity: str | None
    runtime_identity: str
    venv_slot: str | None = None


def _claims(authority):
    # This boundary consumes only the actual installation authority. Legacy
    # project-bound routes are not silently widened by the new preparation.
    _require(authority.get("schema") == "forge-platform.product-worker-authority/v7"
             and authority.get("routes") == [] and authority.get("single_routes") == [])
    runtimes = {}
    versions = {}
    for entry in authority["candidate_manifests"] + authority["installed_manifests"]:
        from .managed_historical_product_evidence import _canonical
        manifest = CompositionManifest.from_digest_bound_bytes(
            _canonical(entry["payload"]), manifest_digest=entry["digest"])
        identity = manifest.python_runtime.identity_digest
        version = str(manifest.python_runtime.version)
        _require(identity not in versions or versions[identity] == version)
        versions[identity] = version
        for component in manifest.components:
            key = component.identity, component.artifact.digest
            _require(key not in runtimes or runtimes[key] == identity)
            runtimes[key] = identity
    claims = []
    for wire in authority["installation_routes"]:
        for component, prefix in (("engineering-platform-server", "ep"), ("forge-runtime", "forge")):
            identity = runtimes[(component, wire[prefix + "_artifact_sha256"])]
            claim = _Claim(wire[prefix + "_service_account"], wire[prefix + "_instance_id"],
                           wire.get("forge_service_user_identity_sha256") if prefix == "forge" else None,
                           identity, wire[prefix + "_venv_slot"])
            _require(re.fullmatch(r"venv-[0-9a-f]{64}", claim.venv_slot) is not None)
            _require(re.fullmatch(r"fpi-[0-9a-f]{40}", claim.instance_id) is not None)
            claims.append(claim)
    _require(claims and len({claim.name for claim in claims}) == len(claims))
    return tuple(claims), versions


def _kernel_uuid(uid):
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    lib.mbr_uid_to_uuid.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    lib.mbr_uid_to_uuid.restype = ctypes.c_int
    value = (ctypes.c_ubyte * 16)()
    _require(0 < uid <= 0xFFFFFFFF and lib.mbr_uid_to_uuid(uid, value) == 0)
    return str(uuid.UUID(bytes=bytes(value)))


def _identity(root, claim):
    account = pwd.getpwnam(claim.name)
    _require(account.pw_name == claim.name and account.pw_uid > 0 and account.pw_gid > 0)
    if claim.named_identity is not None:
        _require(not claim.name.startswith("_")
                 and resolve_identity_sha256(claim.name) == claim.named_identity
                 and "sha256:" + sha256(canonical_identity(claim.name, account.pw_uid,
                     account.pw_gid, _kernel_uuid(account.pw_uid))).hexdigest() == claim.named_identity)
        return account.pw_uid, account.pw_gid, claim.named_identity
    from .managed_ep_service_preparation import ManagedEPServicePreparation
    reader = ManagedEPServicePreparation(product_root=root / "products/engineering-platform",
        instance_id=claim.instance_id, service_account=claim.name)
    reader.bind_account()
    _require(reader.account_identity[2] == _kernel_uuid(account.pw_uid))
    return reader.account_identity


def _file_profile(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_gid, value.st_mode,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_flags)


class ManagedProductRuntimeServiceAccess:
    def __init__(self, *, root: Path, base_python: Path | None,
                 authority_sha256: str, selected_account: str):
        self.root, self.base_python = root, base_python
        self.authority_sha256, self.selected_account = authority_sha256, selected_account

    def prepare(self):
        try:
            return self._prepare()
        except RuntimeServiceAccessError:
            raise
        except Exception as error:
            raise RuntimeServiceAccessError("selected product runtime access was rejected") from error

    def _prepare(self):
        _require(os.geteuid() == 0 and sys.platform == "darwin")
        _require(self.root.is_absolute() and self.root.name == "ForgePlatformInstaller")
        authority_path = self.root / "product-worker-authority.json"
        value, digest = _json(authority_path, maximum=4 * 1024 * 1024)
        _require(digest == self.authority_sha256)
        claims, versions = _claims(value)
        selected = [claim for claim in claims if claim.name == self.selected_account]
        _require(len(selected) == 1)
        selected = selected[0]
        slots = self.root / "managed-python-runtime-slots"
        slot = slots / ("sha256-" + selected.runtime_identity.removeprefix("sha256:"))
        python = slot / "bin/python3"
        _require(isinstance(self.base_python, Path) and self.base_python == python)
        host_path = self.root / "managed-python-host-state.json"
        host, host_digest = _json(host_path)
        _require(host.get("schema") == "forge-platform.managed-python-host-state/v1"
                 and host.get("active_runtime_identity") == selected.runtime_identity
                 and host.get("active_runtime_slot") == slot.name)
        initial = tuple(_identity(self.root, claim) for claim in claims)
        _require(len({identity[0] for identity in initial}) == len(initial))
        parent_uids = [identity[0] for identity in initial]
        slot_uids = [identity[0] for claim, identity in zip(claims, initial)
                     if claim.runtime_identity == selected.runtime_identity]

        def current():
            _, fresh = _json(authority_path, maximum=4 * 1024 * 1024)
            _, fresh_host = _json(host_path)
            _require(fresh_host == host_digest)
            _require(fresh == digest and tuple(_identity(self.root, claim) for claim in claims) == initial)

        held = []
        venv_held = []
        root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                          | getattr(os, "O_NOFOLLOW_ANY", 0x20000000))
        try:
            root_before = os.fstat(root_fd)
            _require(stat.S_ISDIR(root_before.st_mode) and root_before.st_uid == 0
                     and stat.S_IMODE(root_before.st_mode) == 0o700 and root_before.st_flags == 0)
            root_grant = _runtime_acl(root_fd, parent_uids, 8)
            # Inspect both ACLs before any grant. Unknown/broader rights remain
            # rejected, including on a slot not yet reached by the selected UID.
            for path, uids in ((slots, parent_uids), (slot, slot_uids)):
                parent_fd = root_fd if path == slots else held[0][1]
                fd = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                             | getattr(os, "O_NOFOLLOW_ANY", 0x20000000), dir_fd=parent_fd)
                held.append((path, fd, os.fstat(fd), uids))
                s = os.fstat(fd)
                _require(stat.S_ISDIR(s.st_mode) and s.st_uid == 0
                         and stat.S_IMODE(s.st_mode) == 0o700 and s.st_flags == 0)
                _runtime_acl(fd, uids, 8)
            binary = os.open(python, os.O_RDONLY | os.O_CLOEXEC
                             | getattr(os, "O_NOFOLLOW_ANY", 0x20000000))
            try:
                before = os.fstat(binary)
                _require(stat.S_ISREG(before.st_mode) and before.st_uid == 0 and before.st_nlink == 1
                         and stat.S_IMODE(before.st_mode) == 0o755 and before.st_flags == 0
                         and no_extended_acl(binary) and 0 < before.st_size <= 128 * 1024 * 1024)
                raw = os.read(binary, 128 * 1024 * 1024 + 1)
                _require(len(raw) == before.st_size)
                binary_digest = sha256(raw).digest()
                # Historical admission does not repeat the native product-venv
                # readback. Bind this selected copied interpreter independently.
                parent_fd = root_fd
                venv_path = self.root
                for name, mode in (("managed-python-product-venvs", 0o700),
                                   (selected.venv_slot, 0o700), ("bin", 0o755)):
                    venv_path = venv_path / name
                    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                                 | getattr(os, "O_NOFOLLOW_ANY", 0x20000000), dir_fd=parent_fd)
                    venv_held.append((venv_path, fd, os.fstat(fd), None))
                    details = os.fstat(fd)
                    _require(stat.S_ISDIR(details.st_mode) and details.st_uid == 0
                             and stat.S_IMODE(details.st_mode) == mode and details.st_flags == 0)
                    _runtime_acl(fd, parent_uids if name == "managed-python-product-venvs"
                                 else [initial[claims.index(selected)][0]], 8)
                    parent_fd = fd
                for name, parent_path, parent_fd, maximum, mode in (
                        ("python3", venv_held[-1][0], venv_held[-1][1], 128 * 1024 * 1024, 0o755),
                        ("pyvenv.cfg", venv_held[-2][0], venv_held[-2][1], 8192, 0o644)):
                    path = parent_path / name
                    fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC
                                 | getattr(os, "O_NOFOLLOW_ANY", 0x20000000), dir_fd=parent_fd)
                    details = os.fstat(fd)
                    venv_held.append((path, fd, details, maximum))
                    _require(stat.S_ISREG(details.st_mode) and details.st_uid == 0
                             and details.st_nlink == 1 and stat.S_IMODE(details.st_mode) == mode
                             and details.st_flags == 0 and no_extended_acl(fd)
                             and 0 < details.st_size <= maximum)
                    contents = os.read(fd, maximum + 1)
                    _require(len(contents) == details.st_size)
                    if name == "python3":
                        _require(sha256(contents).digest() == binary_digest)
                    else:
                        cfg = {}
                        for line in contents.decode("utf-8").splitlines():
                            if not line.strip(): continue
                            key, separator, item = line.partition("=")
                            _require(separator == "=" and key.strip() not in cfg)
                            cfg[key.strip()] = item.strip()
                        _require(cfg.get("home") == str(slot / "bin")
                                 and cfg.get("include-system-site-packages") == "false")
                    # Capture readback bytes, rather than treating a digest from
                    # an earlier process as proof of this current publication.
                    venv_held[-1] = (path, fd, details, (maximum, sha256(contents).digest()))

                def directories_current():
                    os.lseek(binary, 0, os.SEEK_SET)
                    _require(_file_profile(os.fstat(binary)) == _file_profile(before)
                             and _file_profile(python.lstat()) == _file_profile(before)
                             and no_extended_acl(binary)
                             and sha256(os.read(binary, 128 * 1024 * 1024 + 1)).digest() == binary_digest)
                    _require(_file_profile(self.root.lstat()) == _file_profile(root_before)
                             and _file_profile(os.fstat(root_fd)) == _file_profile(root_before)
                             and _runtime_acl(root_fd, parent_uids, 8) == root_grant)
                    for held_path, held_fd, held_before, held_uids in held:
                        named, opened = held_path.lstat(), os.fstat(held_fd)
                        keys = ('st_dev', 'st_ino', 'st_uid', 'st_gid', 'st_mode', 'st_flags')
                        _require(all(getattr(held_before, key) == getattr(opened, key)
                                     == getattr(named, key) for key in keys))
                        _runtime_acl(held_fd, held_uids, 8)
                    for path, fd, before_venv, content in venv_held:
                        _require(_file_profile(os.fstat(fd)) == _file_profile(before_venv)
                                 and _file_profile(path.lstat()) == _file_profile(before_venv))
                        if content is not None:
                            maximum, expected = content
                            os.lseek(fd, 0, os.SEEK_SET)
                            _require(sha256(os.read(fd, maximum + 1)).digest() == expected
                                     and no_extended_acl(fd))

                for path, fd, before_dir, uids in held:
                    current()
                    directories_current()
                    _search(fd, uids)
                    _require(len(_runtime_acl(fd, uids, 8)) == len(uids))
                    after_dir = path.lstat()
                    _require((before_dir.st_dev, before_dir.st_ino, before_dir.st_uid, before_dir.st_gid,
                              before_dir.st_mode, before_dir.st_flags) ==
                             (after_dir.st_dev, after_dir.st_ino, after_dir.st_uid, after_dir.st_gid,
                              after_dir.st_mode, after_dir.st_flags))
                current()
                directories_current()
                index = claims.index(selected)
                uid, gid, _ = initial[index]
                version = tuple(int(part) for part in versions[selected.runtime_identity].split("."))
                code = ("import sys,ssl,sqlite3; assert sys.version_info[:3]==" + repr(version)
                        + "; ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); "
                        "assert sqlite3.connect(':memory:').execute('select 1').fetchone()==(1,); "
                        "print('PRODUCT_RUNTIME_ACCESS=PASS')")
                result = subprocess.run([str(python), "-I", "-B", "-c", code], user=uid, group=gid,
                    extra_groups=(), cwd="/var/empty", stdin=subprocess.DEVNULL, capture_output=True,
                    timeout=30, env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "HOME":"/var/empty"})
                _require(result.returncode == 0 and result.stdout == b"PRODUCT_RUNTIME_ACCESS=PASS\n"
                         and result.stderr == b"")
                os.lseek(binary, 0, os.SEEK_SET)
                _require(binary_digest == sha256(os.read(binary, 128 * 1024 * 1024 + 1)).digest()
                         and _file_profile(os.fstat(binary)) == _file_profile(before)
                         and _file_profile(python.lstat()) == _file_profile(before)
                         and no_extended_acl(binary))
                current()
                directories_current()
                _require(_file_profile(self.root.lstat()) == _file_profile(root_before)
                         and _file_profile(os.fstat(root_fd)) == _file_profile(root_before)
                         and _runtime_acl(root_fd, parent_uids, 8) == root_grant)
                for path, fd, before_dir, uids in held:
                    named, opened = path.lstat(), os.fstat(fd)
                    keys = ('st_dev', 'st_ino', 'st_uid', 'st_gid', 'st_mode', 'st_flags')
                    _require(all(getattr(before_dir, key) == getattr(opened, key)
                                 == getattr(named, key) for key in keys))
                    _require(len(_runtime_acl(fd, uids, 8)) == len(uids))
            finally:
                os.close(binary)
        finally:
            os.close(root_fd)
            for _, fd, _, _ in held + venv_held:
                os.close(fd)
