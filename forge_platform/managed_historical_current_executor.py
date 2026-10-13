"""Independent actual signed-native currentness proof for historical execution.

The fixed helper diagnostic admits its own sealed parent against the latest
signed feed. No old authority snapshot, caller flag or proposed identity can
replace that proof. A timeout never kills a helper process or claims its exit.
"""
from __future__ import annotations

from hashlib import sha256
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import threading
import time

from .installer_helper_companion import no_extended_acl
from .managed_historical_execution_evidence import HistoricalExecutionEvidenceError

HELPER = Path('/Library/Application Support/ForgePlatformInstallerHelper/ForgePlatformInstaller.app/Contents/Resources/forge-platform-installer-helper')
APP = HELPER.parents[2]
FLAG = '--historical-current-executor-proof'
SCHEMA = 'forge-platform.historical-current-executor-proof/v1'


def _require(ok):
    if not ok: raise HistoricalExecutionEvidenceError('current native executor proof is unavailable')


def _profile(s):
    return (s.st_dev,s.st_ino,s.st_uid,s.st_gid,s.st_mode,s.st_nlink,s.st_flags,
            s.st_size,s.st_mtime_ns,s.st_ctime_ns)


def decode_current_native_proof(raw, expected_executor):
    _require(isinstance(raw,bytes) and 0<len(raw)<=8192)
    def pairs(items):
        value={}
        for key,item in items:_require(key not in value);value[key]=item
        return value
    try:
        value=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        canonical=json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()
        _require(canonical==raw and isinstance(value,dict) and set(value)=={'schema','current_executor'}
                 and value['schema']==SCHEMA and isinstance(value['current_executor'],dict)
                 and type(value['current_executor'].get('sequence')) is int
                 and value['current_executor']==dict(expected_executor))
        return 'sha256:'+sha256(raw).hexdigest()
    except (ValueError,TypeError,UnicodeError,RecursionError) as error:
        raise HistoricalExecutionEvidenceError('current native executor proof is unavailable') from error


def _retain_until_real_exit(process):
    # Non-daemon reaping prevents the product worker from reporting actual exit
    # while its root diagnostic child can still run. Drain only, never log bytes.
    def reap():
        try:
            if process.stdout is not None:
                while process.stdout.read(8192): pass
            process.wait()
        finally:
            if process.stdout is not None: process.stdout.close()
    threading.Thread(target=reap,name='historical-current-proof-reap',daemon=False).start()


def _capture_helper_proof():
    process=subprocess.Popen([str(HELPER),FLAG],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,cwd='/var/empty',env={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
    deadline=time.monotonic()+90;data=bytearray()
    try:
        while True:
            remaining=deadline-time.monotonic();_require(remaining>0)
            readable,_,_=select.select([process.stdout],[],[],remaining)
            _require(readable)
            chunk=os.read(process.stdout.fileno(),min(8192,8193-len(data)))
            if not chunk:break
            data.extend(chunk);_require(len(data)<=8192)
        remaining=deadline-time.monotonic();_require(remaining>0)
        _require(process.wait(timeout=remaining)==0)
        process.stdout.close()
        return bytes(data)
    except BaseException:
        _retain_until_real_exit(process)
        raise


def _verify_sealed_parent(expected_executor):
    environment={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin'}
    policy='anchor apple generic and identifier "com.autonomous-engineering-system.forge-platform-installer" and certificate leaf[subject.OU] = "ZEML4LPXH4"'
    result=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','-R',policy,str(APP)],
        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30,env=environment)
    _require(result.returncode==0)
    result=subprocess.run(['/usr/bin/codesign','--display','--verbose=4',str(APP)],
        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=30,env=environment)
    _require(result.returncode==0 and len(result.stderr)<=8192)
    hashes=[line.split(b'=',1)[1].decode('ascii') for line in result.stderr.splitlines()
            if line.startswith(b'CandidateCDHashFull sha256=')]
    _require(hashes==[expected_executor['code_directory_sha256'][7:]])


def require_current_native_executor(expected_executor):
    _require(os.geteuid()==0)
    fd=os.open(HELPER,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC|getattr(os,'O_NOFOLLOW_ANY',0x20000000))
    try:
        before=os.fstat(fd)
        _require(stat.S_ISREG(before.st_mode) and before.st_uid==0 and before.st_nlink==1
                 and stat.S_IMODE(before.st_mode)==0o755 and before.st_flags==0 and no_extended_acl(fd))
        # Pin the signed enclosing app and its sealed helper resource as well
        # as the helper identifier. Same-team code cannot self-report authority.
        parent_before=APP.lstat()
        _verify_sealed_parent(expected_executor)
        # Existing Developer ID team, no new trustkey or caller-supplied policy.
        checked=subprocess.run(['/usr/bin/codesign','--verify','--strict','-R',
            'anchor apple generic and identifier "com.autonomous-engineering-system.forge-platform-installer.helper" and certificate leaf[subject.OU] = "ZEML4LPXH4"',str(HELPER)],
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
            timeout=30,env={'HOME':'/var/empty','LANG':'C','LC_ALL':'C','PATH':'/usr/bin:/bin:/usr/sbin:/sbin'})
        _require(checked.returncode==0 and _profile(before)==_profile(os.fstat(fd))
                 and _profile(before)==_profile(HELPER.lstat()) and no_extended_acl(fd))
        raw=_capture_helper_proof()
        digest=decode_current_native_proof(raw,expected_executor)
        _require(_profile(before)==_profile(os.fstat(fd)) and _profile(before)==_profile(HELPER.lstat()) and no_extended_acl(fd))
        _verify_sealed_parent(expected_executor)
        _require(_profile(parent_before)==_profile(APP.lstat()))
        return digest
    finally:os.close(fd)
