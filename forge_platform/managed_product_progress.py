"""Closed component progress, without product streams or authentication data."""
from __future__ import annotations
import json
import os
from pathlib import Path
import secrets
import stat
from .installer_helper_companion import no_extended_acl
from .managed_product_operation_admission import AdmittedNativeProductOperation

SCHEMA="forge-platform.product-component-progress/v1"
STATES={"pending","running","installed","passed","failed"}
CODES={"none","preflight","installing","awaiting-pairing","ready",
       "ep-service-start-failed","component-failed","pairing-failed","readiness-failed"}
class ProductProgressError(RuntimeError):pass

class FileProductProgress:
    def __init__(self,root:Path,admitted):
        if not isinstance(admitted,AdmittedNativeProductOperation):
            raise ProductProgressError("component progress lacks native admission")
        request=admitted.request
        self.root=root
        self.claim={"schema":SCHEMA,"operation_id":request.operation_id,
            "deployment_id":request.deployment_id,"session_id":request.session_id,
            "stable_plan_fingerprint":request.stable_plan_fingerprint,
            "request_fingerprint":request.request_fingerprint,
            "installer_version":request.installer_release.version,
            "installer_release_sha256":request.installer_release.sha256.removeprefix("sha256:")}
        self.rows={c.identity:{"component_id":c.identity,"state":"pending","code":"none"}
                   for c in request.components}
        for component in (("pairing","readiness") if len(self.rows)==2 else ("readiness",)):
            self.rows[component]={"component_id":component,"state":"pending","code":"none"}
    def fail_active(self):
        for component,row in tuple(self.rows.items()):
            if row["state"]=="running":
                code="pairing-failed" if component=="pairing" else "readiness-failed" if component=="readiness" else "component-failed"
                self.update(component,"failed",code)
    def update(self,component,state,code):
        if component not in self.rows or state not in STATES or code not in CODES:
            raise ProductProgressError("invalid component progress")
        allowed={"pending":{"none"},"running":{"preflight","installing"},
                 "installed":{"awaiting-pairing"},"passed":{"ready"},
                 "failed":{"ep-service-start-failed","component-failed","pairing-failed","readiness-failed"}}
        if (code not in allowed[state]
                or code=="awaiting-pairing" and component!="forge-runtime"
                or code=="ep-service-start-failed" and component!="engineering-platform-server"
                or code=="pairing-failed" and component!="pairing"
                or code=="readiness-failed" and component!="readiness"):
            raise ProductProgressError("component progress state/code mismatch")
        self.rows[component]={"component_id":component,"state":state,"code":code}
        value={**self.claim,"rows":[self.rows[k] for k in sorted(self.rows)]}
        raw=json.dumps(value,sort_keys=True,separators=(",",":"),allow_nan=False).encode()
        flags=os.O_RDONLY|os.O_CLOEXEC|os.O_DIRECTORY|getattr(os,"O_NOFOLLOW_ANY",0x20000000)
        fd=os.open(self.root/"state",flags);parent=None
        try:
            self._directory(fd)
            try:os.mkdir("product-progress",0o700,dir_fd=fd)
            except FileExistsError:pass
            parent=os.open("product-progress",flags,dir_fd=fd);self._directory(parent)
            name=self.claim["operation_id"]+".json"
            try:old=os.open(name,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=parent)
            except FileNotFoundError:old=None
            if old is not None:
                try:
                    s=os.fstat(old)
                    if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_nlink!=1 or stat.S_IMODE(s.st_mode)!=0o600 or not 0<s.st_size<=8192 or not no_extended_acl(old):
                        raise ProductProgressError("unsafe prior progress")
                    from .managed_ep_partial_create import _json
                    from hashlib import sha256
                    prior, prior_digest = _json(self.root/"state/product-progress"/name,maximum=8192)
                    prior_raw=json.dumps(prior,sort_keys=True,separators=(",",":"),allow_nan=False).encode()
                    if "sha256:"+sha256(prior_raw).hexdigest()!=prior_digest:
                        raise ProductProgressError("prior progress is not canonical")
                    if set(prior)!=set(value) or any(prior.get(k)!=v for k,v in self.claim.items()):
                        raise ProductProgressError("progress operation changed")
                    rows=prior.get("rows")
                    if (not isinstance(rows,list) or len(rows)!=len(self.rows)
                            or {r.get("component_id") for r in rows if isinstance(r,dict)}!=set(self.rows)
                            or any(not isinstance(r,dict) or set(r)!={"component_id","state","code"}
                                   or r["state"] not in STATES or r["code"] not in CODES for r in rows)):
                        raise ProductProgressError("prior progress shape changed")
                finally:os.close(old)
            temporary=".progress-"+secrets.token_hex(8)
            out=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW,0o600,dir_fd=parent)
            try:
                with os.fdopen(out,"wb",closefd=False) as stream:
                    stream.write(raw);stream.flush();os.fsync(out)
                if old is not None:
                    from hashlib import sha256
                    # Keep every superseded snapshot inside this private route.
                    archive="history-"+sha256(prior_raw).hexdigest()+".json"
                    try:os.link(name,archive,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False)
                    except FileExistsError:pass
                os.replace(temporary,name,src_dir_fd=parent,dst_dir_fd=parent);os.fsync(parent)
            finally:
                os.close(out)
                try:os.unlink(temporary,dir_fd=parent)
                except FileNotFoundError:pass
        finally:
            if parent is not None:os.close(parent)
            os.close(fd)
    @staticmethod
    def _directory(fd):
        s=os.fstat(fd)
        if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or stat.S_IMODE(s.st_mode)!=0o700 or not no_extended_acl(fd):
            raise ProductProgressError("unsafe progress directory")

class ProgressProductAdapter:
    def __init__(self,adapter,progress,component):
        self.adapter,self.progress,self.component=adapter,progress,component
        self.did_execute=False
    def readback(self,request):
        if not self.did_execute and self.progress.rows[self.component]["state"]!="passed":
            self.progress.update(self.component,"running","preflight")
        try:result=self.adapter.readback(request)
        except Exception:
            self.progress.update(self.component,"failed","component-failed");raise
        if self.did_execute or result.artifact==request.artifact.correlation:
            if result.health_state=="HEALTHY":self.progress.update(self.component,"passed","ready")
            elif result.health_state=="AWAITING_PEER":self.progress.update(self.component,"installed","awaiting-pairing")
        return result
    def assess_update(self,request):return self.adapter.assess_update(request)
    def execute(self,request):
        self.progress.update(self.component,"running","installing")
        try:result=self.adapter.execute(request)
        except Exception as error:
            from .engineering_platform_system_adapter import EPIdentityHealthUnavailableError
            code="ep-service-start-failed" if isinstance(error,EPIdentityHealthUnavailableError) else "component-failed"
            self.progress.update(self.component,"failed",code);raise
        self.did_execute=True
        return result
    def resume(self,request,prior):
        self.progress.update(self.component,"running","installing")
        try:result=self.adapter.resume(request,prior)
        except Exception:
            self.progress.update(self.component,"failed","component-failed");raise
        self.did_execute=True
        return result
