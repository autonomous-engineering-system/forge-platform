"""Integrated source admission/worker checks; no installed or signed PASS."""
from pathlib import Path
from unittest.mock import patch,Mock
import io,json,os,tempfile,unittest
from forge_platform.managed_historical_execution_admission import (
    decode_execution_intent,_consume_once,_allowed_scopes,HistoricalExecutionAdmission,SCHEMA,
)
from forge_platform.managed_historical_execution_evidence import HistoricalExecutionEvidenceError,_component_id
from tests.installer.test_managed_historical_execution_evidence import fixture,canonical,digest


class HistoricalExecutionAdmissionTests(unittest.TestCase):
    def testClosedIntentAllowsNoCallerAuthority(self):
        expected,_=fixture();value={'schema':SCHEMA,'operation_id':expected.request.operation_id,
            'nonce':expected.nonce,'record_sha256':digest('a')}
        self.assertEqual(decode_execution_intent(canonical(value)),value)
        for key in ('current_executor','root','command','credentials','execution_authorized'):
            with self.assertRaises(HistoricalExecutionEvidenceError):decode_execution_intent(canonical(dict(value,**{key:True})))
        with self.assertRaises(HistoricalExecutionEvidenceError):HistoricalExecutionAdmission(object(),None,None,None,None,())

    def testActualConsumptionIsImmutableAndPartialPublicationCannotReplay(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            state=Path(tmp);state.chmod(0o700);name='claim.json';raw=b'bounded source claim'
            _consume_once(state,name,raw,owner=os.geteuid())
            self.assertEqual((state/name).read_bytes(),raw)
            self.assertEqual((state/name).stat().st_mode&0o7777,0o600)
            with self.assertRaises(FileExistsError):_consume_once(state,name,raw,owner=os.geteuid())
            name='partial.json'
            with patch('forge_platform.managed_historical_execution_admission.os.fsync',side_effect=OSError('source sync failure')):
                with self.assertRaises(OSError):_consume_once(state,name,raw,owner=os.geteuid())
            with self.assertRaises(FileExistsError):_consume_once(state,name,raw,owner=os.geteuid())

    def testConsumptionRefusesDirectoryNamespaceSwap(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root=Path(tmp);state=root/'state';state.mkdir(mode=0o700);moved=root/'old'
            real=os.fsync;swapped=False
            def swap(fd):
                nonlocal swapped
                real(fd)
                if not swapped:
                    swapped=True;state.rename(moved);state.mkdir(mode=0o700)
            with patch('forge_platform.managed_historical_execution_admission.os.fsync',side_effect=swap):
                with self.assertRaises(HistoricalExecutionEvidenceError):_consume_once(state,'claim.json',b'claim',owner=os.geteuid())
            self.assertFalse((state/'claim.json').exists());self.assertTrue((moved/'claim.json').exists())

    def testScopeCannotExpandToUpdateRemovalOrAnotherOperation(self):
        expected,_=fixture();r=expected.request
        wire={'ep_instance_id':'ep-source','forge_instance_id':'forge-source','installation_pairing':{'operation_id':'pair-source'}}
        allowed=_allowed_scopes(r,wire)
        self.assertIn((r.deployment_id,'product-install-resume','engineering-platform-server','ep-source',_component_id(r,'engineering-platform-server')),allowed)
        self.assertIn((r.deployment_id,'forge-ep-pairing',None,None,r.operation_id),allowed)
        for m in ('product-update','product-repair','product-remove','deployment-remove','ep-credential-issue'):
            self.assertFalse(any(scope[1]==m for scope in allowed))
        self.assertFalse(any(scope[4]=='other' for scope in allowed))

    def testIntegratedHistoricalServiceRunsEPForgePairingAndReadinessWhileOrdinaryRejectsOldRelease(self):
        from forge_platform.managed_historical_execution_admission import _SEAL
        from forge_platform.managed_product_operation_service import ManagedProductOperationAuthorities,ManagedProductOperationServiceError
        from tests.installer.test_managed_product_operation_service import ManagedProductOperationHelperServiceTests
        from tests.installer.test_managed_product_operation_dispatch import manifests
        from tests.installer.test_managed_product_operation_admission import request_payload,decoded,canonical as request_json
        from dataclasses import replace
        expected,value=fixture();_,candidate=manifests()
        request=decoded(request_payload(candidate,installed=None,exists=False))
        expected=replace(expected,request=request)
        wire={'ep_instance_id':'ep-new','forge_instance_id':'forge-new','installation_pairing':{'operation_id':'pair-source'}}
        cap=HistoricalExecutionAdmission(_SEAL,expected,digest('a'),'claim',b'source-model',_allowed_scopes(request,wire))
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            helper=ManagedProductOperationHelperServiceTests()
            service,registry,authority,routes=helper.fixture(Path(tmp),authorities=ManagedProductOperationAuthorities(candidate,cap.current_release))
            service.dispatcher.coordinator.currency_guard=cap
            with patch.object(HistoricalExecutionAdmission,'require_valid',return_value=None) as validate:
                with self.assertRaises(ManagedProductOperationServiceError):service.execute(request_json(request_payload(candidate,installed=None,exists=False)))
                self.assertEqual(routes.requests,[])
                result=json.loads(service.execute_historical(cap))
                self.assertEqual(result['operation_id'],request.operation_id)
                self.assertEqual({c['component_identity'] for c in result['completions']},{'engineering-platform-server','forge-runtime'})
                self.assertTrue(result['pairing_receipt_reference'])
                self.assertEqual(len(result['readiness_receipt_references']),2)
                self.assertIsNotNone(registry.load(request.deployment_id).peer_binding)
                self.assertGreater(validate.call_count,3)
                self.assertEqual(len(routes.requests),1)

    def testWorkerHistoricalEntryCannotUseOrdinaryInjectedService(self):
        from forge_platform.installer_product_worker import run
        expected,_=fixture();intent=canonical({'schema':SCHEMA,'operation_id':expected.request.operation_id,
            'nonce':expected.nonce,'record_sha256':digest('a')})
        ordinary=Mock(side_effect=AssertionError('ordinary route must not load'))
        with patch('forge_platform.managed_historical_execution_admission.execute_historical_request',return_value=b'{"source_only":true}') as execution:
            output=io.BytesIO();self.assertEqual(run(io.BytesIO(intent),output,service_loader=ordinary),0)
            execution.assert_called_once();ordinary.assert_not_called()


@unittest.skipUnless(os.geteuid()==0,'isolated root-private factory IO qualification')
class HistoricalRootFactoryIntegrationTests(unittest.TestCase):
    def testActualPrivateFactoryConsumesOnceOnlyAfterIndependentProofAndOriginalPreflight(self):
        from dataclasses import replace
        from hashlib import sha256
        from forge_platform.managed_historical_product_evidence import HistoricalProductEvidence
        from forge_platform.managed_historical_execution_admission import admit_historical_execution
        expected,value=fixture()
        wire={'deployment_id':expected.request.deployment_id,'forge_service_account':'source-operator',
              'ep_instance_id':'ep-source','forge_instance_id':'forge-source',
              'installation_pairing':{'operation_id':'pair-source'}}
        authority=canonical({'installation_routes':[wire]})
        effects=canonical({'schema':'forge-platform.product-worker-effects/v1','uncertain':True,'activeIDs':[expected.worker_id]})
        roles=dict(expected.protected_sha256_by_role);roles['authority']='sha256:'+sha256(authority).hexdigest()
        expected=replace(expected,protected_sha256_by_role=roles,reserved_effect_sha256='sha256:'+sha256(effects).hexdigest())
        value['inspection']['protected_sha256_by_role']=roles
        value['inspection_sha256']='sha256:'+sha256(canonical(value['inspection'])).hexdigest()
        value['reserved_effect_sha256']=expected.reserved_effect_sha256
        record=canonical(value);record_digest='sha256:'+sha256(record).hexdigest()
        intent=canonical({'schema':SCHEMA,'operation_id':expected.request.operation_id,'nonce':expected.nonce,'record_sha256':record_digest})
        original=HistoricalProductEvidence(expected.request,canonical(value['inspection']['original_request']),
            value['inspection']['original_ep_operation_id'],tuple(sorted(roles.items())))
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root=Path(tmp);root.chmod(0o700);state=root/'state';state.mkdir(mode=0o700)
            name='historical-execution-'+sha256(expected.request.operation_id.encode()).hexdigest()+'.json'
            for n,raw in [(name,record),('product-worker-effects.json',effects)]:
                (state/n).write_bytes(raw);(state/n).chmod(0o600)
            with patch('forge_platform.managed_historical_execution_admission.PRODUCT_WORKER_ROOT',root), \
                 patch('forge_platform.managed_historical_execution_record_reader.PRODUCT_WORKER_ROOT',root), \
                 patch('forge_platform.managed_historical_execution_admission.reconstruct_original_product_evidence',return_value=original), \
                 patch('forge_platform.managed_historical_execution_record_reader.reconstruct_original_product_evidence',return_value=original), \
                 patch('forge_platform.managed_historical_execution_admission.inspect_original_recovery_preflight',return_value=None) as preflight, \
                 patch('forge_platform.managed_historical_execution_admission.require_current_native_executor',return_value=digest('b')) as current, \
                 patch('forge_platform.product_worker_authority.ProductWorkerAuthorityLoader._read_secure_authority',return_value=authority), \
                 patch('forge_platform.managed_installer_user_identity.resolve_identity_sha256',return_value=expected.operator_sha256), \
                 patch.dict(os.environ,{'FORGE_PLATFORM_PRODUCT_WORKER_EFFECT_ID':expected.worker_id}):
                # The real closed private reader and O_EXCL/fsync claim run.
                # Only signed-executor/physical-original observations are
                # modeled; this is explicitly source qualification.
                with patch('forge_platform.managed_historical_execution_admission.require_current_native_executor',side_effect=HistoricalExecutionEvidenceError('unavailable')):
                    with self.assertRaises(HistoricalExecutionEvidenceError):admit_historical_execution(intent)
                self.assertFalse(list(state.glob('historical-consumed-*')))
                cap=admit_historical_execution(intent)
                self.assertEqual(cap.expected.request,expected.request)
                self.assertNotEqual(cap.current_release,expected.request.installer_release)
                self.assertTrue(current.called);self.assertTrue(preflight.called)
                claims=list(state.glob('historical-consumed-*'));self.assertEqual(len(claims),1)
                frozen=claims[0].read_bytes()
                with self.assertRaises(FileExistsError):admit_historical_execution(intent)
                self.assertEqual(claims[0].read_bytes(),frozen)
                self.assertEqual((state/name).read_bytes(),record)
                self.assertEqual((state/'product-worker-effects.json').read_bytes(),effects)

if __name__ == "__main__": unittest.main()
