"""Current-proof codec source tests, not a signed installed helper attestation."""
import json,unittest
from forge_platform.managed_historical_current_executor import SCHEMA,decode_current_native_proof
from forge_platform.managed_historical_execution_evidence import HistoricalExecutionEvidenceError
from tests.installer.test_managed_historical_execution_evidence import fixture,canonical


class HistoricalCurrentExecutorProofTests(unittest.TestCase):
    def testOnlyExactActualNativeIdentityCanCorrelate(self):
        expected,_=fixture();current=dict(expected.current_executor)
        value={'schema':SCHEMA,'current_executor':current}
        self.assertTrue(decode_current_native_proof(canonical(value),current).startswith('sha256:'))
        for key in current:
            other=dict(current);other[key]=True if key=='sequence' else 'changed'
            with self.assertRaises(HistoricalExecutionEvidenceError):decode_current_native_proof(canonical({'schema':SCHEMA,'current_executor':other}),current)

    def testOldSnapshotAndMalformedOrCallerExtendedProofCannotSupplyCurrentness(self):
        expected,_=fixture();current=dict(expected.current_executor)
        for raw in [canonical(current),canonical({'schema':SCHEMA,'current_executor':current,'root':'/tmp'}),canonical({'schema':'old','current_executor':current}),canonical({'schema':SCHEMA,'current_executor':current})+b'\n',b'{"schema":"one","schema":"two"}',b' '*8193]:
            with self.assertRaises(HistoricalExecutionEvidenceError):decode_current_native_proof(raw,current)



@unittest.skipUnless(__import__('os').geteuid()==0,'isolated root-owned native-proof IO qualification')
class HistoricalNativeProofRootIOTests(unittest.TestCase):
    def testRealPublicParentAndHelperRequireInlinePolicyWhileProofCaptureIsOnlyModeled(self):
        from pathlib import Path
        from unittest.mock import patch
        import subprocess
        from forge_platform import managed_historical_current_executor as module
        from tests.installer.historical_public_signed_artifacts import public_signed_app,require_wrong_identity_rejected,POLICY
        app,cd=public_signed_app('0.4.21');helper=app/'Contents/Resources/forge-platform-installer-helper'
        require_wrong_identity_rejected(app)
        expected,_=fixture();current=dict(expected.current_executor);current['code_directory_sha256']='sha256:'+cd
        raw=canonical({'schema':SCHEMA,'current_executor':current})
        actual_run=subprocess.run;verifications=[]
        def observed(args,**kwargs):
            if args[0]=='/usr/bin/codesign' and '--verify' in args:
                self.assertNotIn('-R',args)
                requirements=[arg for arg in args if arg.startswith('-R=')]
                self.assertEqual(len(requirements),1)
                self.assertIn('certificate leaf[subject.OU] = "ZEML4LPXH4"',requirements[0])
                verifications.append(args)
            return actual_run(args,**kwargs)
        # Every Apple verification is REAL against the frozen signed carrier.
        # Only current proof capture is modeled to avoid invoking any installed
        # helper/acceptance-store authority during these source tests.
        with patch.object(module,'APP',app),patch.object(module,'HELPER',helper),patch.object(module,'_capture_helper_proof',return_value=raw),patch.object(module.subprocess,'run',side_effect=observed):
            self.assertTrue(module.require_current_native_executor(current).startswith('sha256:'))
        self.assertEqual(len(verifications),3)
        self.assertEqual(verifications[0],['/usr/bin/codesign','--verify','--deep','--strict','-R='+POLICY,str(app)])
        self.assertEqual(verifications[1][-1],str(helper))
        self.assertEqual(verifications[2],verifications[0])

    def testActualBoundedChildAndFileProfilesWithModeledAppleSigning(self):
        from unittest.mock import patch
        from pathlib import Path
        import tempfile,subprocess
        from forge_platform import managed_historical_current_executor as module
        expected,_=fixture();current=dict(expected.current_executor)
        raw=canonical({'schema':SCHEMA,'current_executor':current})
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            app=Path(tmp)/'Source.app';app.mkdir(mode=0o700)
            helper=app/'source-proof';helper.write_text('#!/usr/bin/python3\nimport sys\nsys.stdout.buffer.write('+repr(raw)+')\n');helper.chmod(0o755)
            def signing(args,**kwargs):
                if '--display' in args:return subprocess.CompletedProcess(args,0,stderr=('CandidateCDHashFull sha256='+current['code_directory_sha256'][7:]+'\n').encode())
                return subprocess.CompletedProcess(args,0,stderr=b'')
            with patch.object(module,'HELPER',helper),patch.object(module,'APP',app),patch.object(module.subprocess,'run',side_effect=signing):
                result=module.require_current_native_executor(current)
                self.assertTrue(result.startswith('sha256:'))
                helper.chmod(0o744)
                with self.assertRaises(HistoricalExecutionEvidenceError):module.require_current_native_executor(current)
                helper.chmod(0o755)
                with patch.object(module,'_verify_sealed_parent',side_effect=HistoricalExecutionEvidenceError('source signing denial')):
                    with self.assertRaises(HistoricalExecutionEvidenceError):module.require_current_native_executor(current)

if __name__ == "__main__": unittest.main()
