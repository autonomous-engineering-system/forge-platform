"""Exact EP installation-only owner commands and bounded native disclosure.

No public command accepts a product path, credential body, project or account.
The helper supplies its sealed provisioner and frozen scope. Plaintext travels
only from the selected EP process to the existing signed Keychain child pipe.
"""
from dataclasses import dataclass
from hashlib import sha256
import hmac
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess

from .component_operations import QualifiedArtifact
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .ep_consumer_revocation import _exact_ep_instance_runtime
from .managed_ep_installation_credential import EPInstallationCredentialScope, InstallationCredentialError, _strict_object
from .managed_ep_credential_issuance import _EP_FINGERPRINT_DOMAIN
from .managed_system_keychain_store import ManagedSystemKeychainCredentialStore
from .qualified_ep_lifecycle import qualified_ep_installation_pairing_artifact


@dataclass(frozen=True)
class EPInstallationCommandResult:
    returncode: int
    stdout: bytes


class SubprocessEPInstallationCommandRunner:
    def run(self,argv, *, data_root, uid, gid):
        try:
            account=pwd.getpwuid(uid)
            info=os.lstat(data_root)
            command=tuple(argv)
            if (os.geteuid()!=0 or type(uid) is not int or uid<0
                    or type(gid) is not int or gid!=account.pw_gid
                    or not Path(account.pw_dir).is_absolute()
                    or not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode)!=0o700
                    or info.st_uid!=uid or not Path(data_root).is_absolute()
                    or len(command) not in {13,17} or not Path(command[0]).is_absolute()
                    or command[1:4]!=('-IB','-m','engineering_platform.server')
                    or command[4] not in {'installation-pairing-register','installation-pairing-status','installation-pairing-issue'}
                    or command[5:7]!=('--data-root',str(data_root))
                    or command[7]!='--expected-instance-id' or command[9]!='--peer-binding-id'
                    or command[11]!='--operation-id'
                    or (command[4]=='installation-pairing-register')!=(len(command)==17)
                    or (len(command)==17 and (command[13]!='--peer-runtime-id' or command[15]!='--consumer-id'))):
                raise ValueError()
            result=subprocess.run(tuple(argv),stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,timeout=30,check=False,user=uid,group=gid,extra_groups=(),
                cwd=str(data_root),env={'HOME':account.pw_dir,'PATH':'/usr/bin:/bin:/usr/sbin:/sbin',
                    'PYTHONNOUSERSITE':'1','PYTHONSAFEPATH':'1'})
            if not 0<len(result.stdout)<=16384: raise ValueError()
            return EPInstallationCommandResult(result.returncode,result.stdout)
        except Exception:
            raise InstallationCredentialError('EP installation command unavailable') from None


class EPInstallationPairingProductAdapter:
    def __init__(self, *, provisioner: EngineeringPlatformSystemProvisionerAdapter,
                 scope: EPInstallationCredentialScope, expected_artifact: QualifiedArtifact,
                 runner=None, expected_owner_uid=0):
        if (not isinstance(provisioner,EngineeringPlatformSystemProvisionerAdapter)
                or not isinstance(scope,EPInstallationCredentialScope)
                or not qualified_ep_installation_pairing_artifact(expected_artifact)
                or scope.ep_instance_id!=provisioner.target.instance_id
                or type(expected_owner_uid) is not int or expected_owner_uid<0):
            raise TypeError('exact released EP installation authority required')
        self.provisioner,self.scope,self.expected_artifact,self.expected_owner_uid=(
            provisioner,scope,expected_artifact,expected_owner_uid)
        self.runner=runner or SubprocessEPInstallationCommandRunner()

    def _command(self,action):
        if action not in {'register','status','issue'}:
            raise InstallationCredentialError('EP installation action invalid')
        stage="runtime_readback"
        try:
            interpreter,database,uid,gid=_exact_ep_instance_runtime(
                self.provisioner,self.expected_artifact,self.expected_owner_uid)
            stage="data_ownership"
            info=os.lstat(database.parent)
            # EP's published installation administration requires the data
            # owner. The daemon keeps its separately qualified service account.
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in {self.expected_owner_uid,uid}
                    or stat.S_IMODE(info.st_mode)!=0o700):
                raise ValueError()
            owner=pwd.getpwuid(info.st_uid)
            s=self.scope
            operation=s.issuance_operation_id if action=='issue' else 'installation-register-'+sha256(s.binding_id.encode()).hexdigest()
            argv=(str(interpreter),'-IB','-m','engineering_platform.server','installation-pairing-'+action,
                  '--data-root',str(database.parent),'--expected-instance-id',s.ep_instance_id,
                  '--peer-binding-id',s.binding_id,'--operation-id',operation)
            if action=='register':argv+=('--peer-runtime-id',s.forge_runtime_id,'--consumer-id',s.consumer_id)
            stage="service_command"
            result=self.runner.run(argv,data_root=database.parent,uid=owner.pw_uid,gid=owner.pw_gid)
            stage="command_result"
            if result.returncode!=0 or not isinstance(result.stdout,bytes) or not 0<len(result.stdout)<=16384:
                raise ValueError()
            stage="metadata_decode"
            value=json.loads(result.stdout,object_pairs_hook=_strict_object,
                             parse_constant=lambda value: (_ for _ in ()).throw(ValueError()))
            if not isinstance(value,dict):raise ValueError()
            return value
        except Exception:
            failure=InstallationCredentialError('EP installation command rejected')
            # Fixed metadata only. Native diagnostics whitelist these stages;
            # no command output or credential body is attached.
            failure.ep_installation_stage=stage
            if stage=='command_result':
                failure.ep_installation_exit_code=result.returncode
            raise failure from None

    def _status(self,value):
        s=self.scope
        expected=dict(binding_id=s.binding_id,ep_instance_id=s.ep_instance_id,forge_instance_id=s.forge_runtime_id,
                      consumer_id=s.consumer_id,purpose='INSTALLATION_READBACK',status='ACTIVE')
        if (set(value)!=set(expected)|{'credentials'} or any(value.get(k)!=v for k,v in expected.items())
                or not isinstance(value.get('credentials'),list) or len(value['credentials'])>256):
            raise InstallationCredentialError('EP installation scope changed')
        seen=set()
        for c in value['credentials']:
            if (not isinstance(c,dict) or set(c)!={'credential_id','operation_id','issued_at','status'}
                    or not isinstance(c['credential_id'],str) or re.fullmatch(r'installation-[0-9a-f]{32}',c['credential_id']) is None
                    or c['credential_id'] in seen or not isinstance(c['operation_id'],str)
                    or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}',c['operation_id']) is None
                    or not isinstance(c['issued_at'],str) or not c['issued_at'] or c['status'] not in {'ACTIVE','REVOKED'}):
                raise InstallationCredentialError('EP installation metadata invalid')
            seen.add(c['credential_id'])
        return value

    def status(self):return self._status(self._command('status'))

    def register(self):
        registered=self._status(self._command('register'))
        if registered!=self.status():
            raise InstallationCredentialError('EP installation registration not durable')

    def issue_to_store(self,store):
        if not isinstance(store,ManagedSystemKeychainCredentialStore):
            raise TypeError('existing signed native Keychain pipe required')
        s=self.scope
        if store.fingerprint(s.credential_reference,s.operation_id) is not None:
            raise InstallationCredentialError('EP installation secure reference occupied')
        value=self._command('issue')
        try:
            if (set(value)!={'credential_id','binding_id','operation_id','purpose','credential'}
                    or value['binding_id']!=s.binding_id or value['operation_id']!=s.issuance_operation_id
                    or value['purpose']!='INSTALLATION_READBACK' or not isinstance(value['credential_id'],str)
                    or re.fullmatch(r'installation-[0-9a-f]{32}',value['credential_id']) is None
                    or not isinstance(value['credential'],str) or re.fullmatch(r'[A-Za-z0-9_-]{32,128}',value['credential']) is None):
                raise ValueError()
            matches=[c for c in self.status()['credentials'] if c['operation_id']==s.issuance_operation_id]
            if len(matches)!=1 or matches[0]['credential_id']!=value['credential_id'] or matches[0]['status']!='ACTIVE':raise ValueError()
            fingerprint=sha256(_EP_FINGERPRINT_DOMAIN+value['credential'].encode('ascii')).hexdigest()
            if not store.put_verified(s.credential_reference,s.operation_id,value['credential']):raise ValueError()
            if not hmac.compare_digest(store.fingerprint(s.credential_reference,s.operation_id) or '',fingerprint):raise ValueError()
        except Exception:
            raise InstallationCredentialError('EP installation disclosure lacks secure readback') from None
        finally:value.clear()
