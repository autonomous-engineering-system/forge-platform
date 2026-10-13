"""Private one-shot admission for an original dual CREATE, never a retry flag.

The native authenticated gate owns the reservation and record. The worker
independently pins the current signed helper, correlates the unchanged original
request and consumes one immutable operation-bound claim before constructing
product adapters. Historical uncertainty and original journal bytes stay intact.
"""
from __future__ import annotations

from hashlib import sha256
import json
import os

from .managed_historical_execution_evidence import (
    HistoricalExecutionExpectedBinding, HistoricalExecutionEvidenceError,
    NativeInstallerReleaseBinding, _canonical, _component_id, _require,
)
from .managed_historical_execution_record_reader import (
    _PrivateHistoricalRecordReadback, read_historical_execution_evidence,
)
from .managed_historical_current_executor import require_current_native_executor
from .managed_historical_product_evidence import (
    reconstruct_original_product_evidence, inspect_original_recovery_preflight,
)
from .product_worker_authority import PRODUCT_WORKER_ROOT

SCHEMA = 'forge-platform.historical-product-execute/v1'
_SEAL = object()


def decode_execution_intent(raw):
    def pairs(items):
        result={}
        for key,value in items:_require(key not in result);result[key]=value
        return result
    value=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    _require(_canonical(value)==raw and isinstance(value,dict)
             and set(value)=={'schema','operation_id','nonce','record_sha256'}
             and value['schema']==SCHEMA)
    from .managed_historical_execution_evidence import _uuid, _digest
    from .managed_historical_product_evidence import decode_inspection_intent, INSPECTION_SCHEMA
    decode_inspection_intent(_canonical({'schema':INSPECTION_SCHEMA,'operation_id':value['operation_id']}))
    _uuid(value['nonce']);_digest(value['record_sha256'])
    return value


class HistoricalExecutionAdmission:
    """Not constructible from decoded evidence; factory consumes private claim."""
    def __init__(self, seal, expected, record_digest, claim_name, claim_bytes, scopes):
        _require(seal is _SEAL)
        self.expected=expected;self.record_digest=record_digest
        self._claim_name=claim_name;self._claim_bytes=claim_bytes
        self._scopes=frozenset(scopes)
        c=expected.current_executor
        self.current_release=NativeInstallerReleaseBinding(*(c[k] for k in
            ('version','release_page','asset_name','sha256','signing_key_id')))

    def require_valid(self):
        _require(os.geteuid()==0)
        require_current_native_executor(self.expected.current_executor)
        evidence=read_historical_execution_evidence(self.expected)
        _require(evidence.record_sha256==self.record_digest)
        with _PrivateHistoricalRecordReadback(PRODUCT_WORKER_ROOT/'state') as private:
            _require(private.read(self._claim_name,8192)==self._claim_bytes)
        return evidence

    def require_current(self, *, deployment_id, mutation, component, instance_id, operation_id):
        scope=(deployment_id,mutation,component,instance_id,operation_id)
        _require(scope in self._scopes)
        self.require_valid()
        return 'currency:'+sha256(_canonical(list(scope))+self._claim_bytes).hexdigest()


def _allowed_scopes(request, wire):
    d=request.deployment_id;parent=request.operation_id
    scopes={(d,m,None,None,parent) for m in
            ('deployment-create','deployment-replace','forge-ep-pairing','composition-commit')}
    for component,key in (('engineering-platform-server','ep_instance_id'),('forge-runtime','forge_instance_id')):
        for m in ('product-install','product-install-resume'):
            scopes.add((d,m,component,wire[key],_component_id(request,component)))
    binding=wire['installation_pairing']
    for m in ('ep-installation-credential','ep-installation-credential-readback'):
        scopes.add((d,m,'engineering-platform-server',wire['ep_instance_id'],binding['operation_id']))
    return scopes


def _consume_once(state, name, raw, *, owner=0):
    # Internal temporary-IO qualification seam; production supplies fixed root
    # and root ownership. A partial write remains a blocker, never a retry.
    with _PrivateHistoricalRecordReadback(state,owner=owner) as private:
        initial=os.fstat(private.fd)
        fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC
                   |getattr(os,'O_NOFOLLOW_ANY',0x20000000),0o600,dir_fd=private.fd)
        try:
            os.fchmod(fd,0o600)
            offset=0
            while offset<len(raw):
                count=os.write(fd,raw[offset:]);_require(count>0);offset+=count
            os.fsync(fd)
        finally:os.close(fd)
        os.fsync(private.fd)
        current=os.fstat(private.fd);named=state.lstat()
        keys=('st_dev','st_ino','st_uid','st_gid','st_mode','st_flags')
        _require(all(getattr(initial,k)==getattr(current,k)==getattr(named,k) for k in keys))
    with _PrivateHistoricalRecordReadback(state,owner=owner) as private:
        _require(private.read(name,8192)==raw)


def admit_historical_execution(raw):
    _require(os.geteuid()==0)
    intent=decode_execution_intent(raw);op=intent['operation_id']
    name='historical-execution-'+sha256(op.encode()).hexdigest()+'.json'
    with _PrivateHistoricalRecordReadback(PRODUCT_WORKER_ROOT/'state') as private:
        record=private.read(name,256*1024)
    _require('sha256:'+sha256(record).hexdigest()==intent['record_sha256'])
    # Closed decoder below rejects duplicate/unknown fields. These preliminary
    # fields only build correlation inputs; no execution is permitted yet.
    value=json.loads(record);inspection=value['inspection']
    original=reconstruct_original_product_evidence(PRODUCT_WORKER_ROOT,op)
    from .product_worker_authority import ProductWorkerAuthorityLoader
    from .managed_installer_user_identity import resolve_identity_sha256
    authority=ProductWorkerAuthorityLoader()._read_secure_authority()
    _require('sha256:'+sha256(authority).hexdigest()==dict(original.protected_sha256_by_role)['authority'])
    wires=[w for w in json.loads(authority)['installation_routes'] if w['deployment_id']==original.request.deployment_id]
    _require(len(wires)==1)
    expected=HistoricalExecutionExpectedBinding(
        original.request,dict(original.protected_sha256_by_role),
        inspection['original_descriptor_sha256'],resolve_identity_sha256(wires[0]['forge_service_account']),
        inspection['current_executor']['release_trust_sha256'],inspection['current_executor'],
        value['worker_id'],intent['nonce'],value['original_effect_sha256'],value['reserved_effect_sha256'])
    require_current_native_executor(expected.current_executor)
    decoded=read_historical_execution_evidence(expected)
    _require(decoded.record_sha256==intent['record_sha256'])
    inspect_original_recovery_preflight(PRODUCT_WORKER_ROOT,op)
    claim_name='historical-consumed-'+sha256(op.encode()).hexdigest()+'.json'
    claim=_canonical({'schema':'forge-platform.historical-execution-consumption/v1',
                      'nonce':expected.nonce,'record_sha256':decoded.record_sha256})
    _consume_once(PRODUCT_WORKER_ROOT/'state',claim_name,claim)
    admitted=HistoricalExecutionAdmission(_SEAL,expected,decoded.record_sha256,claim_name,claim,
                                         _allowed_scopes(original.request,wires[0]))
    admitted.require_valid()
    return admitted


def execute_historical_request(raw, *, worker_path, base_python):
    from .product_worker_authority import ProductWorkerAuthorityLoader
    admission=admit_historical_execution(raw)
    service=ProductWorkerAuthorityLoader(worker_path=worker_path,base_python=base_python).load_historical(admission)
    return service.execute_historical(admission)
