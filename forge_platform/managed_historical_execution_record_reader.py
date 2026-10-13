"""Fixed private execution-record readback, deliberately not admission/dispatch.

A fresh authenticated native gate must supply the expected binding under its
exclusive lease. Reading correlated bytes does not prove that gate or authorize
products; a separate current-executor factory and one-shot consumption remain
required. No provider home/credential contents are read by this module.
"""
from __future__ import annotations

from hashlib import sha256
import json
import os
from pathlib import Path
import stat

from .installer_helper_companion import no_extended_acl
from .managed_historical_execution_evidence import (
    HistoricalExecutionEvidenceError, HistoricalExecutionExpectedBinding,
    decode_historical_execution_evidence,
)
from .managed_historical_product_evidence import reconstruct_original_product_evidence
from .product_worker_authority import PRODUCT_WORKER_ROOT


def _require(ok):
    if not ok: raise HistoricalExecutionEvidenceError("private historical execution evidence conflicts")


def _profile(s):
    return (s.st_dev, s.st_ino, s.st_uid, s.st_gid, s.st_mode, s.st_nlink,
            s.st_flags, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


class _PrivateHistoricalRecordReadback:
    """Internal IO seam; production entry below always uses the fixed root."""
    def __init__(self, state: Path, *, owner=0):
        self.state, self.owner, self.fd, self.initial = state, owner, None, None

    def __enter__(self):
        self.fd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                          | getattr(os, "O_NOFOLLOW_ANY", 0x20000000))
        try:
            self.initial = os.fstat(self.fd)
            self.verify()
            return self
        except BaseException:
            os.close(self.fd); self.fd = None; raise

    def verify(self):
        held = os.fstat(self.fd); named = self.state.lstat()
        _require(stat.S_ISDIR(held.st_mode) and held.st_uid == self.owner
                 and stat.S_IMODE(held.st_mode) == 0o700 and held.st_flags == 0
                 and no_extended_acl(self.fd) and _profile(held) == _profile(named)
                 and _profile(held) == _profile(self.initial))

    def read(self, name: str, maximum: int) -> bytes:
        _require(isinstance(name, str) and name and "/" not in name and "\0" not in name)
        fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC
                     | getattr(os, "O_NOFOLLOW_ANY", 0x20000000), dir_fd=self.fd)
        try:
            before = os.fstat(fd)
            _require(stat.S_ISREG(before.st_mode) and before.st_uid == self.owner
                     and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
                     and before.st_flags == 0 and no_extended_acl(fd)
                     and 0 < before.st_size <= maximum)
            chunks=[]; total=0
            while True:
                chunk=os.read(fd,min(8192,maximum+1-total))
                total+=len(chunk);_require(total<=maximum)
                if not chunk: break
                chunks.append(chunk)
            _require(no_extended_acl(fd) and _profile(before)==_profile(os.fstat(fd))
                     and _profile(before)==_profile(os.stat(name,dir_fd=self.fd,follow_symlinks=False))
                     and total==before.st_size)
            self.verify()
            return b"".join(chunks)
        finally: os.close(fd)

    def __exit__(self, *args):
        if self.fd is not None: os.close(self.fd);self.fd=None


def _effects(raw, expected):
    def pairs(items):
        value={}
        for key,item in items:_require(key not in value);value[key]=item
        return value
    def invalid(value): raise HistoricalExecutionEvidenceError("private historical execution evidence conflicts")
    value=json.loads(raw,object_pairs_hook=pairs,parse_constant=invalid)
    _require(isinstance(value,dict) and set(value)=={"schema","activeIDs","uncertain"}
             and value["schema"]=="forge-platform.product-worker-effects/v1"
             and value["activeIDs"]==[expected.worker_id] and value["uncertain"] is True
             and "sha256:"+sha256(raw).hexdigest()==expected.reserved_effect_sha256)


def read_historical_execution_evidence(expected: HistoricalExecutionExpectedBinding):
    """Return correlated Evidence only; no loader, consumption or product effects."""
    _require(os.geteuid()==0 and isinstance(expected,HistoricalExecutionExpectedBinding)
             and os.environ.get("FORGE_PLATFORM_PRODUCT_WORKER_EFFECT_ID")==expected.worker_id)
    name="historical-execution-"+sha256(expected.request.operation_id.encode()).hexdigest()+".json"
    with _PrivateHistoricalRecordReadback(PRODUCT_WORKER_ROOT/"state") as private:
        raw=private.read(name,256*1024)
        effects=private.read("product-worker-effects.json",8192)
        _effects(effects,expected)
        decoded=decode_historical_execution_evidence(raw,expected=expected)
        original=reconstruct_original_product_evidence(PRODUCT_WORKER_ROOT,expected.request.operation_id)
        _require(original.request==expected.request
                 and dict(original.protected_sha256_by_role)==dict(expected.protected_sha256_by_role))
        _require(private.read(name,256*1024)==raw
                 and private.read("product-worker-effects.json",8192)==effects)
        private.verify()
        return decoded
