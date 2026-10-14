"""Read-only proof of the exact 0.4.20 pre-admission trust-format denial.

This recognizes pinned defective code, never a new trusted producer. Apple
signatures and the native signed descriptor gate independently bind its archive.
Absence of consumption alone is NEVER proof. No permit/claim is issued here.
"""
from __future__ import annotations
import ctypes,errno,json,os,plistlib,stat,subprocess,zipfile
from hashlib import sha256
from pathlib import Path
from .managed_historical_execution_evidence import (
    HistoricalExecutionExpectedBinding,decode_historical_execution_evidence,
    _canonical,_digest,_require,_trust_digest,HistoricalExecutionEvidenceError,
)
from .managed_historical_execution_record_reader import _PrivateHistoricalRecordReadback
from .managed_historical_product_evidence import reconstruct_original_product_evidence,inspect_original_recovery_preflight,_StableReadback,HistoricalProductEvidenceError
from .managed_installer_user_identity import resolve_identity_sha256
from .installer_helper_companion import no_extended_acl
from .product_worker_authority import PRODUCT_WORKER_ROOT

SCHEMA='forge-platform.historical-denied-attempt-inspection/v1'
LEGACY_VERSION='0.4.20'
# Exact reviewed code in 07d3b8d; all three stages must match. These hashes only
# recognize a denial; they cannot admit an executor, product or arbitrary code.
LEGACY_MODULES={
 'forge_platform/managed_historical_execution_evidence.py':'ca7ab2cca863c3fd6d64b38d5de498c3588157f01402c0482568c2de1cbb391b',
 'forge_platform/managed_historical_execution_admission.py':'7af9765cb68d4b999523825267f9975a6dcc33a6cfdd7d58bcaf69c3e8bb2eb4',
 'forge_platform/installer_product_worker.py':'f1e8e1e0518d56482723c53d5e08acff4445328f5ba9d838171b8cf4fb792e1a',
}


def decode_denied_intent(raw):
    from .managed_historical_product_evidence import decode_inspection_intent,INSPECTION_SCHEMA
    try:
        _require(isinstance(raw,bytes) and 0<len(raw)<=1024)
        value=json.loads(raw)
        _require(isinstance(value,dict) and set(value)=={'schema','operation_id'}
                 and value['schema']==SCHEMA and _canonical(value)==raw)
        return decode_inspection_intent(_canonical({'schema':INSPECTION_SCHEMA,'operation_id':value['operation_id']}))
    except (ValueError,TypeError,KeyError,HistoricalProductEvidenceError) as error:
        raise HistoricalExecutionEvidenceError('denied attempt inspection is unavailable') from error


def _no_other_recovery_processes(archived_helper):
    """Physical recovery worker/known-helper paths; no argv or env read."""
    libc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    libc.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    libc.proc_pidpath.restype=ctypes.c_int
    own=ctypes.create_string_buffer(4096)
    _require(libc.proc_pidpath(os.getpid(),own,4096)>0)
    current_helper=b'/Library/Application Support/ForgePlatformInstallerHelper/ForgePlatformInstaller.app/Contents/Resources/forge-platform-installer-helper'
    forbidden={own.value,os.fsencode(archived_helper),current_helper}
    result=subprocess.run(['/bin/ps','-axo','pid='],stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
    _require(result.returncode==0 and len(result.stdout)<=256*1024)
    for value in result.stdout.split():
        pid=int(value)
        # PID0 is the OS kernel, never a userspace installer child.
        if pid in {0,os.getpid()}:continue
        buffer=ctypes.create_string_buffer(4096)
        if libc.proc_pidpath(pid,buffer,4096)<=0:
            try:os.kill(pid,0)
            except OSError as error:
                _require(error.errno==errno.ESRCH)
            else:_require(False) # living unknown process is not quiescence
            continue
        if pid==os.getppid() and buffer.value==current_helper:continue
        _require(buffer.value not in forbidden)


def _archive_worker(state,record_digest,executor,stable):
    base=state/'historical-denied-executors';directory=base/record_digest[7:]
    app=directory/'ForgePlatformInstaller.app'
    for path,mode in [(base,0o700),(directory,0o700),(app,0o755),(app/'Contents',0o755),(app/'Contents/Resources',0o755)]:
        fd,s=stable.open(path,directory=True,acl=no_extended_acl)
        _require(stat.S_ISDIR(s.st_mode) and s.st_uid==0 and stat.S_IMODE(s.st_mode)==mode
                 and s.st_flags==0 and no_extended_acl(fd))
    _require(str(app.resolve())==str(app))
    info=app/'Contents/Info.plist'
    infofd,infos=stable.open(info,acl=no_extended_acl)
    _require(stat.S_ISREG(infos.st_mode) and infos.st_uid==0 and infos.st_nlink==1
             and infos.st_flags==0 and no_extended_acl(infofd) and stat.S_IMODE(infos.st_mode)==0o644 and infos.st_size<=64*1024)
    metadata=plistlib.loads(os.read(infofd,64*1024+1));expected_worker=metadata['ForgePlatformProductWorkerSHA256']
    _digest(expected_worker)
    worker=app/'Contents/Resources/forge-platform-product-worker.pyz'
    fd,before=stable.open(worker,acl=no_extended_acl)
    _require(stat.S_ISREG(before.st_mode) and before.st_uid==0 and before.st_nlink==1
             and before.st_flags==0 and stat.S_IMODE(before.st_mode)==0o644 and no_extended_acl(fd)
             and before.st_size<=16*1024*1024)
    raw=os.read(fd,16*1024*1024+1)
    _require(len(raw)==before.st_size and 'sha256:'+sha256(raw).hexdigest()==expected_worker)
    stable.verify()
    policy='anchor apple generic and identifier "com.autonomous-engineering-system.forge-platform-installer" and certificate leaf[subject.OU] = "ZEML4LPXH4"'
    env={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin'}
    check=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R='+policy,str(app)],
        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30,env=env)
    _require(check.returncode==0)
    result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(app)],
        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=30,env=env)
    _require(result.returncode==0 and len(result.stderr)<=8192)
    hashes=[line.split(b'=',1)[1].decode('ascii') for line in result.stderr.splitlines() if line.startswith(b'CandidateCDHashFull sha256=')]
    _require(hashes==[executor['code_directory_sha256'][7:]])
    import io
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        for name,digest in LEGACY_MODULES.items():
            info=archive.getinfo(name);_require(info.file_size<=512*1024)
            _require(sha256(archive.read(name)).hexdigest()==digest)
    stable.verify()
    # Revalidate the whole signed namespace while all selected inodes remain
    # held. A different directory generation or leaf is always rejected.
    confirmed=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R='+policy,str(app)],
        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30,env=env)
    _require(confirmed.returncode==0);stable.verify()
    return expected_worker


def denied_attempt_proof(operation_id,*,reserved_effect=None):
    """Evidence only. reserved_effect is internal current-record correlation."""
    _require(os.geteuid()==0)
    state=PRODUCT_WORKER_ROOT/'state';suffix=sha256(operation_id.encode()).hexdigest()+'.json'
    with _PrivateHistoricalRecordReadback(state) as private,_StableReadback() as stable:
        raw=private.read('historical-execution-'+suffix,256*1024)
        digest='sha256:'+sha256(raw).hexdigest();value=json.loads(raw)
        _require(value['schema']=='forge-platform.historical-product-execution-permit/v1')
        inspection=value['inspection'];old=inspection['current_executor']
        _require(old['version']==LEGACY_VERSION and old['source_revision']=='07d3b8d29091410bd6b4928a3f654bb8eed7e8d2' and old['sequence']==42)
        _trust_digest(old['release_trust_sha256'])
        # Pinned legacy _digest requires 71 tagged characters. Exact bare64 is
        # therefore rejected in ExpectedBinding BEFORE native-proof/consumption
        # and BEFORE load_historical/adapter construction. Do not execute it.
        _require(len(old['release_trust_sha256'])==64 and not old['release_trust_sha256'].startswith('sha256:'))
        original=reconstruct_original_product_evidence(PRODUCT_WORKER_ROOT,operation_id)
        from .product_worker_authority import ProductWorkerAuthorityLoader
        authority=ProductWorkerAuthorityLoader()._read_secure_authority()
        wires=json.loads(authority)['installation_routes'];_require(len(wires)==1)
        owner=resolve_identity_sha256(wires[0]['forge_service_account'])
        expected=HistoricalExecutionExpectedBinding(original.request,dict(original.protected_sha256_by_role),
            inspection['original_descriptor_sha256'],owner,old['release_trust_sha256'],old,
            value['worker_id'],value['nonce'],value['original_effect_sha256'],value['reserved_effect_sha256'])
        decode_historical_execution_evidence(raw,expected=expected)
        for prefix in ('historical-consumed-','historical-completion-'):
            try: private.read(prefix+suffix,8192)
            except FileNotFoundError: private.verify()
            else: _require(False)
        effects=private.read('product-worker-effects.json',8192);parsed=json.loads(effects)
        _require(parsed['uncertain'] is True)
        if reserved_effect is None:
            _require(parsed['activeIDs']==[] and 'sha256:'+sha256(effects).hexdigest()==value['original_effect_sha256'])
        else:
            worker_id,effect_digest=reserved_effect
            _require(parsed['activeIDs']==[worker_id] and 'sha256:'+sha256(effects).hexdigest()==effect_digest)
        worker_digest=_archive_worker(state,digest,old,stable)
        archived_helper=state/'historical-denied-executors'/digest[7:]/'ForgePlatformInstaller.app/Contents/Resources/forge-platform-installer-helper'
        _no_other_recovery_processes(archived_helper)
        inspect_original_recovery_preflight(PRODUCT_WORKER_ROOT,operation_id)
        _no_other_recovery_processes(archived_helper)
        _require(private.read('historical-execution-'+suffix,256*1024)==raw
                 and private.read('product-worker-effects.json',8192)==effects)
        private.verify();stable.verify()
        return _canonical({'schema':SCHEMA,'operation_id':operation_id,'previous_record_sha256':digest,
            'original_effect_sha256':value['original_effect_sha256'],'old_executor':old,
            'archived_worker_sha256':worker_digest,'legacy_module_sha256':LEGACY_MODULES,
            'original_descriptor_sha256':inspection['original_descriptor_sha256'],
            'original_operator_identity_sha256':owner,'original_request_fingerprint':original.request.request_fingerprint,
            'protected_sha256_by_role':dict(original.protected_sha256_by_role),
            'terminal_no_admitted_execution':True,'no_live_recovery_worker':True})
