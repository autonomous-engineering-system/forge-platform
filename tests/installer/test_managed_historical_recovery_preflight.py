"""Read-only source gate checks. Mocks are not installed/runtime qualification."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch, MagicMock
import io,json,unittest

from forge_platform.managed_ep_partial_create import EPPartialCreateError, assert_ep_partial_create_quiescent
from forge_platform.managed_historical_product_evidence import HistoricalProductEvidenceError, RECOVERY_PREFLIGHT_SCHEMA, decode_recovery_preflight_intent
from forge_platform import installer_product_worker as worker
from forge_platform import managed_historical_product_evidence as historical


class HistoricalRecoveryPreflightTests(unittest.TestCase):
    def testOnlyCanonicalClosedReadOnlyIntentIsAccepted(self):
        value = {"schema": RECOVERY_PREFLIGHT_SCHEMA, "operation_id": "managed-python-original"}
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(decode_recovery_preflight_intent(raw), "managed-python-original")
        for data in [raw+b"\n", raw.replace(b'managed-python-original', b'../other'), b'{"schema":"one","schema":"two"}', json.dumps(dict(value, root="/tmp/other"), sort_keys=True, separators=(",", ":")).encode()]:
            with self.assertRaises((HistoricalProductEvidenceError, ValueError)):
                decode_recovery_preflight_intent(data)

    def testRegisteredJobDeniesBeforeAccountOrProcessInspection(self):
        with patch('forge_platform.managed_ep_partial_create.subprocess.run', return_value=SimpleNamespace(returncode=0, stdout='state = spawn scheduled', stderr='')) as run, patch('pwd.getpwnam') as account:
            with self.assertRaises(EPPartialCreateError):
                assert_ep_partial_create_quiescent(helper_root=Path('/private/test-root'), instance_id='fpi-original', service_account='_fpi_original')
            account.assert_not_called()
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:2], ['/bin/launchctl', 'print'])

    def testUnloadedJobStillDeniesServiceUserAndOrphanRootProcesses(self):
        from hashlib import sha256
        label = 'com.engineeringplatform.server.instance-' + sha256(b'fpi-original').hexdigest()[:32]
        absent = SimpleNamespace(returncode=113, stdout='', stderr=f'Could not find service "{label}" in domain for system')
        for line in ['999 1 1234 /bin/service', '999 1 0 /usr/bin/python3', '999 1 0 /private/test-root/products/engineering-platform/runtimes/slot/provisioner']:
            with patch('forge_platform.managed_ep_partial_create.subprocess.run', side_effect=[absent, SimpleNamespace(returncode=0, stdout=line, stderr='')]), patch('pwd.getpwnam', return_value=SimpleNamespace(pw_uid=1234)):
                with self.assertRaises(EPPartialCreateError):
                    assert_ep_partial_create_quiescent(helper_root=Path('/private/test-root'), instance_id='fpi-original', service_account='_fpi_original')

    def testJobStartingDuringRepeatedEvidenceScanPreventsPositivePreflight(self):
        # Source orchestration race check only; no fabricated runtime PASS.
        evidence = SimpleNamespace(request=SimpleNamespace(deployment_id='original'),
            protected_sha256_by_role=(('authority', 'sha256:'+'a'*64),),
            canonical_readback=lambda: b'{}')
        wire = {'deployment_id': 'original', 'ep_instance_id': 'fpi-original', 'ep_service_account': '_fpi_original'}
        stable = MagicMock()
        with patch.object(historical, '_StableReadback', return_value=stable), patch.object(historical, '_reconstruct_original_product_evidence', return_value=evidence) as reconstruct, patch.object(historical, '_json', return_value=({'installation_routes': [wire]}, 'sha256:'+'a'*64)), patch.object(historical, 'assert_ep_partial_create_quiescent', side_effect=[None, EPPartialCreateError('job started during evidence scan')]) as physical:
            with self.assertRaises(EPPartialCreateError):
                historical.inspect_original_recovery_preflight(Path('/private/test-root'), 'managed-python-original')
            self.assertEqual(reconstruct.call_count, 2)
            self.assertEqual(physical.call_count, 2)

    def testReadonlyWorkerRouteCannotFallThroughToServiceOrProductExecution(self):
        raw = json.dumps({'schema': RECOVERY_PREFLIGHT_SCHEMA, 'operation_id': 'managed-python-original'}, sort_keys=True, separators=(',', ':')).encode()
        def forbid(): raise AssertionError('service must not load')
        with patch.object(worker, 'inspect_original_recovery_preflight', return_value=b'{"source_only":true}') as inspector:
            out = io.BytesIO()
            self.assertEqual(worker.run(io.BytesIO(raw), out, service_loader=forbid), 0)
            inspector.assert_called_once_with(worker.PRODUCT_WORKER_ROOT, 'managed-python-original')
        with patch.object(worker, 'inspect_original_recovery_preflight', side_effect=EPPartialCreateError('physical denial')):
            self.assertNotEqual(worker.run(io.BytesIO(raw), io.BytesIO(), service_loader=forbid), 0)


if __name__ == '__main__': unittest.main()
