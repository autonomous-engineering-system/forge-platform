"""Read-only admission of one exact receiptless EP CREATE, never a new install.

Only an already admitted native request can bind this helper-owned route. The
historical effect journal is intentionally neither read as authority nor cleared.
"""
from __future__ import annotations

from hashlib import sha256
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid

from .component_operations import ArtifactCorrelation, ProductInstallationReadback
from .managed_product_operation_admission import AdmittedNativeProductOperation
from .installer_helper_companion import no_extended_acl


class EPPartialCreateError(RuntimeError):
    pass


def _require(ok):
    if not ok: raise EPPartialCreateError("EP partial CREATE evidence conflicts")


def _json(path: Path, *, maximum=128*1024):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
                 | getattr(os, "O_NOFOLLOW_ANY", 0x20000000))
    try:
        before = os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid == 0
                 and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
                 and 0 < before.st_size <= maximum and before.st_flags == 0 and no_extended_acl(fd))
        raw = os.read(fd, maximum + 1)
        after = os.fstat(fd)
        named = path.lstat()
        def profile(s):
            return (s.st_dev,s.st_ino,s.st_uid,s.st_gid,s.st_mode,s.st_nlink,
                    s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_flags)
        _require(profile(before) == profile(after) == profile(named)
                 and len(raw) == before.st_size and no_extended_acl(fd))
        def pairs(items):
            result = {}
            for key,value in items:
                _require(key not in result); result[key] = value
            return result
        def invalid_constant(value):
            raise EPPartialCreateError("EP evidence contains a non-JSON constant")
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)
        _require(isinstance(value,dict))
        return value, "sha256:" + sha256(raw).hexdigest()
    finally: os.close(fd)


class BoundEPCreateOperation:
    def __init__(self, *, helper_root: Path, target, artifact, admitted):
        _require(isinstance(admitted, AdmittedNativeProductOperation))
        request = admitted.request
        # A fresh canonical native request intentionally carries no installed
        # instance IDs. The sealed route supplies the deterministic target;
        # verify it below rather than requiring installed topology in CREATE.
        _require(not request.deployment_exists and request.engineering_platform_instance_id is None)
        component = next((c for c in request.components if c.identity == "engineering-platform-server"),None)
        selected = next((c for c in admitted.manifest.components if c.identity == "engineering-platform-server"),None)
        _require(component is not None and component.change == "install" and selected is not None
                 and selected.artifact == artifact and component.artifact_sha256 == artifact.digest
                 and component.candidate_version == artifact.version)
        def identity(domain,*fields):
            values=(domain,*fields)
            return sha256(b"".join(len(s.encode()).to_bytes(8,"big")+s.encode() for s in values)).hexdigest()
        _require(target.instance_id == "fpi-"+identity("forge-platform-product-instance/v1",
                 request.deployment_id,"engineering-platform-server")[:40]
                 and target.service_account == "_fpi_"+identity("forge-platform-service-account/v1",
                 request.deployment_id,"engineering-platform-server",target.instance_id)[:20])
        self.root, self.target, self.artifact = helper_root, target, artifact
        self.parent_path = helper_root / "state/active-installer-operation.json"
        self.parent_claim = {
            "schema": "forge-platform.managed-python-parent-journal/v1",
            "operation_id": request.operation_id,
            "session_id": request.session_id,
            "deployment_id": request.deployment_id,
            "stable_plan_fingerprint": request.stable_plan_fingerprint,
            "composition_identity": request.composition_identity,
            "manifest_sha256": request.manifest_sha256,
            "state": "MANAGED_TOOLS",
        }
        self.component_operation_id = "product-" + sha256(
            f"{request.request_fingerprint}\x1fengineering-platform-server\x1fmutation".encode()).hexdigest()
        self.parent_sha256 = self._parent()
        self.pending_proof = None

    def _parent(self):
        value, digest = _json(self.parent_path)
        _require(all(value.get(k) == v for k,v in self.parent_claim.items()))
        return digest

    def assert_current(self, request):
        _require(request.kind == "install" and request.component == "engineering-platform-server"
                 and request.operation_id == self.component_operation_id
                 and request.installation_identity == self.target.instance_id
                 and request.artifact == self.artifact
                 and self._parent() == self.parent_sha256)

    def pending_readback(self, request, inventory):
        self.assert_current(request)
        target, artifact = self.target, self.artifact
        instance = self.root / "products/engineering-platform/instances" / target.instance_id
        operation = instance / "operations" / request.operation_id
        terminal = self.root/"products/engineering-platform/receipts"/target.instance_id/(request.operation_id+".json")
        _require(not os.path.lexists(terminal))
        product_request, request_digest = _json(operation / "request.json")
        release = {"version":artifact.version,"artifact_digest":artifact.digest,
                   "source_revision":artifact.source_revision}
        _require(product_request == {
            "contract":"engineering-platform.system-provisioner/v1","operation":"INSTALL",
            "operation_id":request.operation_id,"instance_id":target.instance_id,
            "display_label":target.display_label,"service_account":target.service_account,
            "bind_port":target.bind_port,"release":release})
        descriptor, descriptor_digest = _json(instance / "instance.json")
        selected = descriptor.get("selected_runtime")
        _require(isinstance(selected,dict) and set(selected)==set(release)|{"interpreter"}
                 and all(selected.get(k)==v for k,v in release.items()))
        interpreter = str(self.root / "products/engineering-platform/runtimes/slots"
                          / artifact.digest.replace("sha256:","sha256-") / "venv/bin/python")
        _require(selected["interpreter"] == interpreter
                 and descriptor.get("instance_id") == target.instance_id
                 and descriptor.get("display_label") == target.display_label
                 and descriptor.get("service_account") == target.service_account
                 and descriptor.get("data_root") == str(instance / "data")
                 and descriptor.get("endpoint") == f"http://127.0.0.1:{target.bind_port}"
                 and descriptor.get("service_label") == "com.engineeringplatform.server.instance-"
                     + sha256(target.instance_id.encode()).hexdigest()[:32]
                 and descriptor.get("desired_state") == "ACTIVE")
        _require(inventory.get("state") == "OBSERVED" and isinstance(inventory.get("instances"),list))
        matches = [x for x in inventory["instances"] if isinstance(x,dict)
                   and x.get("instance_id")==target.instance_id]
        _require(len(matches)==1 and matches[0].get("selected_runtime")==selected
                 and matches[0].get("service_account")==target.service_account
                 and matches[0].get("endpoint")==descriptor["endpoint"])
        material = "\x1f".join((self.parent_sha256,request_digest,descriptor_digest))
        proof = "ep-partial-create:" + sha256(material.encode()).hexdigest()
        self.assert_quiescent()
        self.pending_proof = {"parent_sha256":self.parent_sha256,
                              "product_request_sha256":request_digest,
                              "descriptor_sha256":descriptor_digest,"proof":proof,
                              "identity_kind":"SELECTED_RUNTIME"}
        self.assert_current(request)
        return ProductInstallationReadback(
            "engineering-platform-server",target.instance_id,"UNHEALTHY",
            interpreter,interpreter,str(descriptor["service_label"]),target.instance_id,
            ArtifactCorrelation(artifact.version,artifact.source_revision,artifact.digest),
            "UNHEALTHY","MACHINE_WIDE","NONE",proof,proof)

    def assert_quiescent(self):
        assert_ep_partial_create_quiescent(
            helper_root=self.root, instance_id=self.target.instance_id,
            service_account=self.target.service_account)

    def assert_worker_reservation(self):
        identifier = os.environ.get("FORGE_PLATFORM_PRODUCT_WORKER_EFFECT_ID")
        _require(isinstance(identifier,str) and str(uuid.UUID(identifier))==identifier)
        effects, digest = _json(self.root/"state/product-worker-effects.json",maximum=8192)
        _require(set(effects)=={"schema","activeIDs","uncertain"}
                 and effects["schema"]=="forge-platform.product-worker-effects/v1"
                 and type(effects["uncertain"]) is bool
                 and effects["activeIDs"]==[identifier])
        return identifier,digest

    def before_preparation(self, request, preparation):
        self.assert_current(request)
        worker_id,effects_digest = self.assert_worker_reservation()
        preparation._account()
        self.assert_quiescent()
        instance = self.root/"products/engineering-platform/instances"/self.target.instance_id
        if self.pending_proof is None:
            # Fresh managed installs have an EP-owned bootstrap before CREATE:
            # the official provider-register command created it during verified
            # provider preparation. Never invent an unknown product namespace.
            bootstrap, bootstrap_digest = _json(instance/"provider-bootstrap.json")
            _require(type(bootstrap.get("schema_version")) is int and bootstrap == {
                "schema_version":1,"instance_id":self.target.instance_id,
                "display_label":self.target.display_label,"service_account":self.target.service_account,
                "service_label":"com.engineeringplatform.server.instance-"+
                    sha256(self.target.instance_id.encode()).hexdigest()[:32],
                "state":"PROVIDER_BOOTSTRAP_PENDING"})
            product_request_path = instance/"operations"/request.operation_id/"request.json"
            if os.path.lexists(product_request_path):
                value, request_digest = _json(product_request_path)
                release={"version":self.artifact.version,"artifact_digest":self.artifact.digest,
                         "source_revision":self.artifact.source_revision}
                _require(type(value.get("bind_port")) is int and value == {
                    "contract":"engineering-platform.system-provisioner/v1","operation":"INSTALL",
                    "operation_id":request.operation_id,"instance_id":self.target.instance_id,
                    "display_label":self.target.display_label,"service_account":self.target.service_account,
                    "bind_port":self.target.bind_port,"release":release})
            else:request_digest=None
            self.pending_proof={"parent_sha256":self.parent_sha256,
                "product_request_sha256":request_digest,"descriptor_sha256":bootstrap_digest,
                "identity_kind":"PROVIDER_BOOTSTRAP_PENDING"}
        if self.pending_proof is not None:
            request_path = instance/"operations"/request.operation_id/"request.json"
            if self.pending_proof["product_request_sha256"] is not None:
                _,request_digest = _json(request_path)
            else:
                _require(not os.path.lexists(request_path));request_digest=None
            descriptor_name = "provider-bootstrap.json" if self.pending_proof.get("identity_kind")=="PROVIDER_BOOTSTRAP_PENDING" else "instance.json"
            _,descriptor_digest = _json(instance/descriptor_name)
            _require(request_digest == self.pending_proof["product_request_sha256"]
                     and descriptor_digest == self.pending_proof["descriptor_sha256"])
            from .managed_forge_instance_bootstrap import _publish
            state = self.root/"state"
            fd = os.open(state,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC
                         |getattr(os,"O_NOFOLLOW_ANY",0x20000000))
            try:
                s = os.fstat(fd)
                _require(s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o700 and no_extended_acl(fd))
                try:os.mkdir("ep-create-recovery",0o700,dir_fd=fd)
                except FileExistsError:pass
                os.fsync(fd)
            finally:os.close(fd)
            recovery = state/"ep-create-recovery"
            fd = os.open(recovery,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC
                         |getattr(os,"O_NOFOLLOW_ANY",0x20000000))
            try:
                s=os.fstat(fd)
                _require(s.st_uid==0 and stat.S_IMODE(s.st_mode)==0o700 and no_extended_acl(fd))
            finally:os.close(fd)
            record = {
                "schema":("forge-platform.ep-partial-create-admission/v1"
                          if self.pending_proof["product_request_sha256"] is not None
                          else "forge-platform.ep-create-preparation-admission/v1"),
                "component_operation_id":request.operation_id,
                "instance_id":self.target.instance_id,
                "service_account":self.target.service_account,
                "account_uid":preparation.uid,"account_gid":preparation.gid,
                "account_generated_uid":preparation.account_identity[2],
                "authority_sha256":preparation.authority_sha256,
                "worker_effect_id":worker_id,"worker_effect_snapshot_sha256":effects_digest,
                "quiescence":"UNREGISTERED_NO_ACCOUNT_OR_ROOT_PRODUCT_CHILD",**self.pending_proof}
            path = recovery/(request.operation_id+"-"+worker_id.lower()+".json")
            if os.path.lexists(path):
                prior,_ = _json(path);_require(prior==record)
            _publish(path,record)
            observed,_ = _json(path);_require(observed==record)
        self.assert_current(request)
        self.assert_worker_reservation()
        self.assert_quiescent()


def assert_ep_partial_create_quiescent(*, helper_root: Path, instance_id: str, service_account: str):
    """Read-only physical denial gate shared by preflight and actual recovery.

    Callers derive all three inputs from fixed helper-owned original authority;
    this function neither stops a job nor grants product execution authority.
    """
    import re
    _require(isinstance(helper_root, Path) and helper_root.is_absolute()
             and isinstance(instance_id, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", instance_id)
             and isinstance(service_account, str) and re.fullmatch(r"_[a-z][a-z0-9_]{0,30}", service_account))
    label = "com.engineeringplatform.server.instance-"+sha256(instance_id.encode()).hexdigest()[:32]
    # An unloaded job is required. A loaded job without a current PID can
    # respawn during rights preparation and is therefore not quiescent.
    result = subprocess.run(["/bin/launchctl","print","system/"+label],
        stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=5,
        env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin"})
    _require(result.returncode == 113 and not result.stdout
             and f'Could not find service "{label}" in domain for system' in result.stderr)
    import pwd
    uid = pwd.getpwnam(service_account).pw_uid
    result = subprocess.run(["/bin/ps","-ww","-axo","pid=,ppid=,uid=,comm="],stdin=subprocess.DEVNULL,
        capture_output=True,text=True,timeout=5,env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin"})
    _require(result.returncode == 0 and len(result.stdout) <= 128*1024)
    import re
    for line in result.stdout.splitlines():
        fields = line.strip().split(None,3)
        _require(len(fields)==4)
        pid,ppid,owner = map(int,fields[:3]); command=fields[3]
        _require(owner != uid)
        if pid == os.getpid():continue
        basename=Path(command).name
        managed = any(command.startswith(str(helper_root/segment)+"/") for segment in (
            "managed-python-runtime-slots","managed-python-product-venvs",
            "products/engineering-platform/runtimes"))
        # Conservatively reject root interpreter/provisioner/launchctl
        # remnants, including already orphaned children; never kill them.
        _require(not (owner==0 and (managed or re.fullmatch(r"python(?:3(?:\.\d+)?)?",basename)
            or basename in {"engineering-platform-system-provisioner","launchctl"})))
