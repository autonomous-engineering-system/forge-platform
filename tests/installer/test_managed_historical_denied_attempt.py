"""Denial/continuation source boundaries only; no installed PASS or permits."""
from dataclasses import replace
from hashlib import sha256
import json,unittest
from forge_platform.managed_historical_execution_evidence import (
    HistoricalExecutionEvidenceError,CONTINUATION_SCHEMA,decode_historical_execution_evidence,
)
from forge_platform.managed_historical_denied_attempt import decode_denied_intent,SCHEMA
from forge_platform.managed_historical_execution_admission import decode_execution_intent,CONTINUATION_SCHEMA as INTENT_SCHEMA
from tests.installer.test_managed_historical_execution_evidence import fixture,canonical,digest

class HistoricalDeniedAttemptContractTests(unittest.TestCase):
    def testReadOnlyIntentCannotSupplyArchivesCredentialsOrAuthority(self):
        intent={'schema':SCHEMA,'operation_id':'managed-python-original'}
        self.assertEqual(decode_denied_intent(canonical(intent)),intent['operation_id'])
        for extra in ['root','archive','credentials','execution_authorized','previous_record_sha256']:
            with self.assertRaises(HistoricalExecutionEvidenceError):decode_denied_intent(canonical(dict(intent,**{extra:True})))
        for raw in [canonical(intent)+b'\n',canonical(dict(intent,operation_id='../other')),b'{"schema":null}',b'{}']:
            with self.assertRaises((HistoricalExecutionEvidenceError,KeyError)):decode_denied_intent(raw)

    def testContinuationIsAClosedDistinctRecordWithExactPredecessorAndProof(self):
        expected,value=fixture()
        value['schema']=CONTINUATION_SCHEMA
        value['previous_record_sha256']=digest('1');value['denial_proof_sha256']=digest('2')
        continuation=replace(expected,previous_record_sha256=digest('1'),denial_proof_sha256=digest('2'))
        self.assertEqual(decode_historical_execution_evidence(canonical(value),expected=continuation).request,expected.request)
        # A v1 expectation cannot read a continuation; a continuation cannot
        # reinterpret a v1 permit or choose any other predecessor/proof.
        with self.assertRaises(HistoricalExecutionEvidenceError):decode_historical_execution_evidence(canonical(value),expected=expected)
        for k,v in [('schema','forge-platform.historical-product-execution-permit/v1'),('previous_record_sha256',digest('0')),('denial_proof_sha256',digest('0'))]:
            with self.assertRaises(HistoricalExecutionEvidenceError):decode_historical_execution_evidence(canonical(dict(value,**{k:v})),expected=continuation)
        for fields in [{'previous_record_sha256':digest('1')},{'denial_proof_sha256':digest('2')},{'previous_record_sha256':'1'*64,'denial_proof_sha256':digest('2')}]:
            with self.assertRaises(HistoricalExecutionEvidenceError):replace(expected,**fields)

    def testContinuationIntentCannotInjectPredecessorOrExecutionCapability(self):
        expected,_=fixture()
        value={'schema':INTENT_SCHEMA,'operation_id':expected.request.operation_id,'nonce':expected.nonce,'record_sha256':digest('a')}
        self.assertEqual(decode_execution_intent(canonical(value)),value)
        with self.assertRaises(HistoricalExecutionEvidenceError):decode_execution_intent(canonical(dict(value,previous_record_sha256=digest('1'))))

if __name__=='__main__':unittest.main()

# Actual root-only filesystem IO; OS signing/physical-original observations
# below are explicitly source models, never installed denial admission.
import os,tempfile
from pathlib import Path
from unittest.mock import patch
@unittest.skipUnless(os.geteuid()==0,'isolated root-private denial IO qualification')
class HistoricalDeniedAttemptRootIOTests(unittest.TestCase):
    def setupEvidence(self,root):
        from dataclasses import replace
        from forge_platform.managed_product_operation_admission import decode_native_product_operation_request
        from forge_platform.managed_historical_product_evidence import HistoricalProductEvidence
        expected,value=fixture()
        payload=value['inspection']['original_request']
        payload['installer_release']['version']='0.4.14'
        payload.pop('request_fingerprint');payload['request_fingerprint']=sha256(canonical(payload)).hexdigest()
        request=decode_native_product_operation_request(canonical(payload))
        current=dict(expected.current_executor,version='0.4.20',sequence=42,source_revision='07d3b8d29091410bd6b4928a3f654bb8eed7e8d2')
        effects=canonical({'schema':'forge-platform.product-worker-effects/v1','uncertain':True,'activeIDs':[]})
        expected=replace(expected,request=request,current_executor=current,original_effect_sha256='sha256:'+sha256(effects).hexdigest())
        from forge_platform.managed_historical_execution_evidence import _component_id
        value['inspection']['original_request']=payload
        value['inspection']['current_executor']=current
        value['inspection']['original_ep_operation_id']=_component_id(request,'engineering-platform-server')
        value['inspection_sha256']='sha256:'+sha256(canonical(value['inspection'])).hexdigest()
        value['original_effect_sha256']=expected.original_effect_sha256
        value['original_forge_operation_id']=_component_id(request,'forge-runtime')
        state=root/'state';state.mkdir(mode=0o700)
        name='historical-execution-'+sha256(request.operation_id.encode()).hexdigest()+'.json'
        for n,raw in [(name,canonical(value)),('product-worker-effects.json',effects)]:
            (state/n).write_bytes(raw);(state/n).chmod(0o600)
        original=HistoricalProductEvidence(request,canonical(payload),value['inspection']['original_ep_operation_id'],tuple(sorted(expected.protected_sha256_by_role.items())))
        return expected,value,state,name,original

    def testExactDeniedRecordRequiresIndependentQuiescenceAndPreservesEveryByte(self):
        from forge_platform import managed_historical_denied_attempt as module
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root=Path(tmp);root.chmod(0o700)
            expected,value,state,name,original=self.setupEvidence(root)
            frozen=(state/name).read_bytes();effect=(state/'product-worker-effects.json').read_bytes()
            authority=canonical({'installation_routes':[{'forge_service_account':'source-admin'}]})
            with patch.object(module,'PRODUCT_WORKER_ROOT',root),patch.object(module,'reconstruct_original_product_evidence',return_value=original), \
                 patch('forge_platform.product_worker_authority.ProductWorkerAuthorityLoader._read_secure_authority',return_value=authority), \
                 patch.object(module,'resolve_identity_sha256',return_value=expected.operator_sha256), \
                 patch.object(module,'_archive_worker',return_value=digest('a')) as archive, \
                 patch.object(module,'_no_other_recovery_processes') as quiet, \
                 patch.object(module,'inspect_original_recovery_preflight') as physical:
                proof=module.denied_attempt_proof(expected.request.operation_id)
                self.assertTrue(json.loads(proof)['terminal_no_admitted_execution'])
                self.assertEqual(quiet.call_count,2);physical.assert_called_once();archive.assert_called_once()
                self.assertEqual((state/name).read_bytes(),frozen);self.assertEqual((state/'product-worker-effects.json').read_bytes(),effect)
                with patch.object(module,'_no_other_recovery_processes',side_effect=HistoricalExecutionEvidenceError('source unknown live process')):
                    with self.assertRaises(HistoricalExecutionEvidenceError):module.denied_attempt_proof(expected.request.operation_id)
                with patch.object(module,'_archive_worker',side_effect=HistoricalExecutionEvidenceError('source signing denial')):
                    with self.assertRaises(HistoricalExecutionEvidenceError):module.denied_attempt_proof(expected.request.operation_id)
                # Any consumption blocks; neither equal bytes nor an operator
                # acknowledgement can turn it into another continuation.
                claim=state/('historical-consumed-'+sha256(expected.request.operation_id.encode()).hexdigest()+'.json')
                claim.write_bytes(b'{}');claim.chmod(0o600)
                with self.assertRaises(HistoricalExecutionEvidenceError):module.denied_attempt_proof(expected.request.operation_id)
                self.assertEqual(claim.read_bytes(),b'{}');self.assertEqual((state/name).read_bytes(),frozen)

    def testWrongOriginalEffectsOrUnknownLegacyExecutorCannotUseDenialRoute(self):
        from forge_platform import managed_historical_denied_attempt as module
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root=Path(tmp);root.chmod(0o700)
            expected,value,state,name,original=self.setupEvidence(root)
            with patch.object(module,'PRODUCT_WORKER_ROOT',root),patch.object(module,'reconstruct_original_product_evidence',return_value=original), \
                 patch('forge_platform.product_worker_authority.ProductWorkerAuthorityLoader._read_secure_authority',return_value=canonical({'installation_routes':[{'forge_service_account':'source-admin'}]})), \
                 patch.object(module,'resolve_identity_sha256',return_value=expected.operator_sha256):
                effects=state/'product-worker-effects.json'
                effects.write_bytes(canonical({'schema':'forge-platform.product-worker-effects/v1','uncertain':False,'activeIDs':[]}))
                with self.assertRaises(HistoricalExecutionEvidenceError):module.denied_attempt_proof(expected.request.operation_id)
                value['inspection']['current_executor']['version']='0.4.19'
                (state/name).write_bytes(canonical(value))
                with self.assertRaises(HistoricalExecutionEvidenceError):module.denied_attempt_proof(expected.request.operation_id)

class HistoricalPhysicalProcessBoundaryTests(unittest.TestCase):
    def observe(self,paths,*,gone=False,kill_error=None):
        import subprocess,errno
        from forge_platform import managed_historical_denied_attempt as module
        class Probe:
            def __call__(self,pid,buffer,size):
                value=paths.get(pid)
                if value is None:return 0
                buffer.value=value;return len(value)
        class Lib:proc_pidpath=Probe()
        pids=b'101\n'+b'\n'.join(str(p).encode() for p in paths if p!=101)+b'\n'
        error=ProcessLookupError(errno.ESRCH,'source gone') if gone else kill_error
        with patch.object(module.ctypes,'CDLL',return_value=Lib()),patch.object(module.os,'getpid',return_value=101), \
             patch.object(module.os,'getppid',return_value=1),patch.object(module.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=pids)), \
             patch.object(module.os,'kill',side_effect=error):
            module._no_other_recovery_processes(Path('/private/source/archive/helper'))

    def testLivingUnknownAndAnyOtherWorkerOrDiagnosticChildAreDenied(self):
        own=b'/private/source/managed-python'
        for other in [own,b'/private/source/archive/helper',b'/Library/Application Support/ForgePlatformInstallerHelper/ForgePlatformInstaller.app/Contents/Resources/forge-platform-installer-helper',None]:
            with self.subTest(path=other):
                with self.assertRaises(HistoricalExecutionEvidenceError):self.observe({101:own,202:other})

    def testOnlyIndependentlyGonePidAndKnownCurrentParentCanBeSkipped(self):
        own=b'/private/source/managed-python'
        self.observe({101:own,202:None},gone=True)
        helper=b'/Library/Application Support/ForgePlatformInstallerHelper/ForgePlatformInstaller.app/Contents/Resources/forge-platform-installer-helper'
        self.observe({101:own,1:helper,303:b'/usr/bin/source-unrelated'})
        import errno
        with self.assertRaises(HistoricalExecutionEvidenceError):self.observe({101:own,202:None},kill_error=PermissionError(errno.EPERM,'source unknown'))

@unittest.skipUnless(os.geteuid()==0,'isolated root-private archive IO qualification')
class HistoricalArchiveIdentityRootIOTests(unittest.TestCase):
    def testHeldPrivateArchiveBindsWholeWorkerToSealedMetadataAndPinnedModules(self):
        import io,plistlib,subprocess,zipfile
        from forge_platform import managed_historical_denied_attempt as module
        from forge_platform.managed_historical_product_evidence import _StableReadback
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            state=Path(tmp);state.chmod(0o700);base=state/'historical-denied-executors';base.mkdir(mode=0o700)
            directory=base/('a'*64);directory.mkdir(mode=0o700)
            app=directory/'ForgePlatformInstaller.app';app.mkdir(mode=0o755)
            contents=app/'Contents';contents.mkdir(mode=0o755);resources=contents/'Resources';resources.mkdir(mode=0o755)
            source=b'unsigned source-only module'
            stream=io.BytesIO()
            with zipfile.ZipFile(stream,'w') as archive:archive.writestr('source.py',source)
            worker=resources/'forge-platform-product-worker.pyz';worker.write_bytes(stream.getvalue());worker.chmod(0o644)
            worker_sha='sha256:'+sha256(worker.read_bytes()).hexdigest()
            info=contents/'Info.plist';info.write_bytes(plistlib.dumps({'ForgePlatformProductWorkerSHA256':worker_sha}));info.chmod(0o644)
            executor={'code_directory_sha256':digest('b')}
            def signing(args,**kw):
                return subprocess.CompletedProcess(args,0,stderr=(b'CandidateCDHashFull sha256='+b'b'*64+b'\n') if '--display' in args else b'')
            # Real FD/ACL/inode/hash IO; Apple signing observations modeled.
            with patch.object(module,'LEGACY_MODULES',{'source.py':sha256(source).hexdigest()}),patch.object(module.subprocess,'run',side_effect=signing):
                with _StableReadback() as held:
                    self.assertEqual(module._archive_worker(state,digest('a'),executor,held),worker_sha)
                    held.verify()
                info.write_bytes(plistlib.dumps({'ForgePlatformProductWorkerSHA256':digest('0')}))
                with _StableReadback() as held:
                    with self.assertRaises(HistoricalExecutionEvidenceError):module._archive_worker(state,digest('a'),executor,held)
                info.write_bytes(plistlib.dumps({'ForgePlatformProductWorkerSHA256':worker_sha}))
                def replaced(args,**kw):
                    if '--verify' in args:
                        renamed=resources/'moved.pyz';worker.rename(renamed);worker.write_bytes(renamed.read_bytes());worker.chmod(0o644)
                    return signing(args,**kw)
                with patch.object(module.subprocess,'run',side_effect=replaced),_StableReadback() as held:
                    with self.assertRaises(Exception):module._archive_worker(state,digest('a'),executor,held)
