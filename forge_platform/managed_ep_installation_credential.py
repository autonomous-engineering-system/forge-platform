"""Durable installation-only issuance; plaintext goes only to the native store.

This is separate from historical project credentials. An uncertain issuance is
never retried: only the same product operation's metadata and an already stored
credential may complete recovery. Otherwise the journal stays ISSUING.
"""
from dataclasses import asdict, dataclass, replace
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import stat
from typing import Protocol

from .managed_deployments import ManagedDeployment, ManagedDeploymentRegistry
from .managed_ep_credential_issuance import _deployment_fingerprint, _write
from .managed_install_flow import EP_COMPONENT, FORGE_COMPONENT

_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
_OP = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_REFERENCE = re.compile(r"keychain://[A-Za-z0-9._-]{1,128}/[A-Za-z0-9._-]{1,128}\Z")
_FINGERPRINT = re.compile(r"[0-9a-f]{64}\Z")


class InstallationCredentialError(RuntimeError):
    """Nonsecret fail-closed installation credential result."""


@dataclass(frozen=True)
class EPInstallationCredentialScope:
    operation_id: str
    deployment_id: str
    binding_id: str
    forge_instance_id: str
    forge_runtime_id: str
    ep_instance_id: str
    consumer_id: str
    credential_reference: str
    reviewed_fingerprint: str
    forge_service_user_identity_sha256: str
    component_bindings_sha256: str

    def __post_init__(self):
        for value in (self.deployment_id,self.binding_id,self.forge_instance_id,
                      self.forge_runtime_id,self.ep_instance_id,self.consumer_id):
            if not isinstance(value,str) or _ID.fullmatch(value) is None:
                raise ValueError("installation credential identity invalid")
        if (not isinstance(self.operation_id,str) or _OP.fullmatch(self.operation_id) is None
                or not isinstance(self.credential_reference,str) or _REFERENCE.fullmatch(self.credential_reference) is None
                or any(not isinstance(value,str) or re.fullmatch(r"sha256:[0-9a-f]{64}",value) is None
                       for value in (self.reviewed_fingerprint,self.forge_service_user_identity_sha256,self.component_bindings_sha256))):
            raise ValueError("installation credential authority invalid")

    @property
    def issuance_operation_id(self):
        digest = sha256(json.dumps(asdict(self),sort_keys=True,separators=(",",":")).encode()).hexdigest()
        return "installation-issue-" + digest


@dataclass(frozen=True)
class EPInstallationCredentialRecord:
    scope: EPInstallationCredentialScope
    state: str
    credential_id: str | None = None
    credential_fingerprint: str | None = None


class InstallationCredentialProduct(Protocol):
    """Concrete product adapter owns commands and the bounded disclosure pipe."""
    scope: EPInstallationCredentialScope
    def register(self) -> None: ...
    def status(self) -> dict: ...
    def issue_to_store(self, store) -> None: ...


def _strict_object(pairs):
    value = {}
    for key,item in pairs:
        if key in value: raise ValueError("duplicate journal field")
        value[key] = item
    return value


class ManagedEPInstallationCredentialCoordinator:
    def __init__(self, *, operations_root: Path, registry: ManagedDeploymentRegistry,
                 currency_guard, product: InstallationCredentialProduct, store,
                 expected_owner_uid: int = 0):
        if (not isinstance(operations_root,Path) or not operations_root.is_absolute()
                or not isinstance(registry,ManagedDeploymentRegistry)
                or not callable(getattr(currency_guard,"require_current",None))
                or not isinstance(getattr(product,"scope",None),EPInstallationCredentialScope)
                or any(not callable(getattr(product,name,None)) for name in ("register","status","issue_to_store"))
                or any(not callable(getattr(store,name,None)) for name in ("fingerprint","put_verified"))
                or type(expected_owner_uid) is not int or expected_owner_uid < 0):
            raise TypeError("installation credential authority required")
        self.root,self.registry,self.guard,self.product,self.store,self.uid = (
            operations_root,registry,currency_guard,product,store,expected_owner_uid)

    def _currency(self):
        scope = self.product.scope
        self.guard.require_current(deployment_id=scope.deployment_id,mutation="ep-installation-credential",
                                   component=EP_COMPONENT,instance_id=scope.ep_instance_id,operation_id=scope.operation_id)
        current = self.registry.load(scope.deployment_id)
        if (not isinstance(current,ManagedDeployment) or current.peer_binding is not None
                or _deployment_fingerprint(current) != scope.reviewed_fingerprint
                or installation_component_digest(current) != scope.component_bindings_sha256
                or current.by_component.get(FORGE_COMPONENT) is None
                or current.by_component.get(EP_COMPONENT) is None
                or current.by_component[FORGE_COMPONENT].instance_id != scope.forge_instance_id
                or current.by_component[EP_COMPONENT].instance_id != scope.ep_instance_id):
            raise InstallationCredentialError("reviewed installation deployment changed")

    def _read(self,path, *, require_scope=True):
        if not os.path.lexists(path): return None
        fd = os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != self.uid or info.st_nlink != 1
                    or stat.S_IMODE(info.st_mode) != 0o600 or not 0 < info.st_size <= 16384):
                raise InstallationCredentialError("installation journal unsafe")
            raw = os.read(fd,16385); after = os.fstat(fd)
            if len(raw) != info.st_size or (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):
                raise InstallationCredentialError("installation journal changed")
        finally: os.close(fd)
        try:
            value = json.loads(raw,object_pairs_hook=_strict_object)
            if set(value) != {"scope","state","credential_id","credential_fingerprint"}: raise ValueError()
            record = EPInstallationCredentialRecord(EPInstallationCredentialScope(**value["scope"]),
                         value["state"],value["credential_id"],value["credential_fingerprint"])
            if require_scope and record.scope != self.product.scope or record.state not in {"PREPARED","REGISTERED","ISSUING","COMPLETE"}: raise ValueError()
            if record.state != "COMPLETE" and (record.credential_id is not None or record.credential_fingerprint is not None): raise ValueError()
            if record.state == "COMPLETE" and (not isinstance(record.credential_id,str)
                    or re.fullmatch(r"installation-[0-9a-f]{32}",record.credential_id) is None
                    or not isinstance(record.credential_fingerprint,str) or _FINGERPRINT.fullmatch(record.credential_fingerprint) is None): raise ValueError()
            return record
        except Exception:
            raise InstallationCredentialError("installation journal invalid") from None

    def _terminal(self,record):
        scope = record.scope
        status = self.product.status()
        expected = dict(binding_id=scope.binding_id,ep_instance_id=scope.ep_instance_id,
                        forge_instance_id=scope.forge_runtime_id,consumer_id=scope.consumer_id,
                        purpose="INSTALLATION_READBACK",status="ACTIVE")
        if not isinstance(status,dict) or set(status) != set(expected)|{"credentials"} or any(status.get(k) != v for k,v in expected.items()):
            raise InstallationCredentialError("installation product scope changed")
        credentials = status["credentials"]
        if not isinstance(credentials,list) or len(credentials) > 256:
            raise InstallationCredentialError("installation credential metadata invalid")
        seen = set()
        for item in credentials:
            if (not isinstance(item,dict) or set(item) != {"credential_id","operation_id","issued_at","status"}
                    or not isinstance(item["credential_id"],str) or re.fullmatch(r"installation-[0-9a-f]{32}",item["credential_id"]) is None
                    or not isinstance(item["operation_id"],str) or _OP.fullmatch(item["operation_id"]) is None
                    or not isinstance(item["issued_at"],str) or not item["issued_at"] or item["status"] not in {"ACTIVE","REVOKED"}
                    or item["credential_id"] in seen):
                raise InstallationCredentialError("installation credential metadata invalid")
            seen.add(item["credential_id"])
        matches = [item for item in credentials if item["operation_id"] == scope.issuance_operation_id]
        if len(matches) != 1 or matches[0]["status"] != "ACTIVE":
            raise InstallationCredentialError("installation issuance lacks exact active readback")
        fingerprint = self.store.fingerprint(scope.credential_reference,scope.operation_id)
        if not isinstance(fingerprint,str) or _FINGERPRINT.fullmatch(fingerprint) is None:
            raise InstallationCredentialError("installation disclosure not securely retained")
        complete = EPInstallationCredentialRecord(scope,"COMPLETE",matches[0]["credential_id"],fingerprint)
        if record.state == "COMPLETE" and complete != record:
            raise InstallationCredentialError("terminal installation credential changed")
        return complete

    def ensure(self) -> EPInstallationCredentialRecord:
        self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        info = os.lstat(self.root)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != self.uid or stat.S_IMODE(info.st_mode) != 0o700:
            raise InstallationCredentialError("installation journal root unsafe")
        # One lock covers every deployment and operation in this sealed root.
        fd = os.open(self.root/".installation-credential.lock",os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != self.uid or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
                raise InstallationCredentialError("installation journal lock unsafe")
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            scope = self.product.scope; path = self.root/(scope.operation_id+".json")
            self._currency()
            journals = list(self.root.glob("*.json"))
            if len(journals) > 256:
                raise InstallationCredentialError("installation journal inventory unbounded")
            for other_path in journals:
                other = self._read(other_path,require_scope=False)
                if other is None or other_path.name != other.scope.operation_id+".json":
                    raise InstallationCredentialError("installation journal identity changed")
                if other.scope.operation_id != scope.operation_id and (
                        other.scope.deployment_id == scope.deployment_id
                        or other.scope.credential_reference == scope.credential_reference
                        or other.scope.binding_id == scope.binding_id):
                    raise InstallationCredentialError("installation scope belongs to a retained operation")
            record = self._read(path)
            if record is None:
                if self.store.fingerprint(scope.credential_reference,scope.operation_id) is not None:
                    raise InstallationCredentialError("installation secure reference occupied")
                record = EPInstallationCredentialRecord(scope,"PREPARED"); _write(path,record)
            if record.state == "COMPLETE": return self._terminal(record)
            if record.state == "PREPARED":
                self._currency(); self.product.register()
                record = replace(record,state="REGISTERED"); _write(path,record)
            if record.state == "REGISTERED":
                self._currency()
                record = replace(record,state="ISSUING"); _write(path,record)
                try: self.product.issue_to_store(self.store)
                except Exception: raise InstallationCredentialError("installation issuance response uncertain; use same operation status") from None
            self._currency()
            complete = self._terminal(record); _write(path,complete)
            return complete
        finally: os.close(fd)


def installation_component_digest(deployment: ManagedDeployment) -> str:
    """Freeze actual component receipts independently of later pairing revision."""
    return "sha256:"+sha256(json.dumps([asdict(c) for c in sorted(deployment.components,key=lambda c:c.component)],
                                     sort_keys=True,separators=(",",":"),allow_nan=False).encode()).hexdigest()
