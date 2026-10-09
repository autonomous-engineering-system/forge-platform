"""Source fixture qualification only; no real secret, product or trust bypass."""
from dataclasses import replace
from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from forge_platform.ep_installation_pairing_adapter import EPInstallationPairingProductAdapter, EPInstallationCommandResult, SubprocessEPInstallationCommandRunner
from forge_platform.managed_ep_installation_credential import EPInstallationCredentialScope, InstallationCredentialError
from forge_platform.managed_ep_credential_issuance import _EP_FINGERPRINT_DOMAIN
from forge_platform.managed_system_keychain_store import ManagedSystemKeychainCredentialStore
from forge_platform.qualified_ep_lifecycle import qualified_ep_installation_pairing_artifact, qualified_ep_lifecycle_artifact


ARTIFACT=QualifiedArtifact('2.3.113','9318636060706534635954e9131e42e2f63928ef','published-wheel',
    'sha256:878e36323e37b29d97a188c02257283c3dc322c60755d57dc9017259f8ac386e','release-complete')


class InstallationProductDriverTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.data=Path(self.tmp.name);self.data.chmod(0o700)
        self.scope=EPInstallationCredentialScope('installer-op','deployment','binding','forge-selector','forge-runtime-uuid',
            'ep-instance','consumer','keychain://installation/new','sha256:'+'1'*64,'sha256:'+'2'*64,'sha256:'+'3'*64)
        self.provisioner=object.__new__(EngineeringPlatformSystemProvisionerAdapter)
        self.provisioner.target=SimpleNamespace(instance_id='ep-instance')
        self.runner=Mock();self.metadata=[];self.calls=[];self.material='SOURCE_FIXTURE_'+'x'*32
        self.driver=EPInstallationPairingProductAdapter(provisioner=self.provisioner,scope=self.scope,
            expected_artifact=ARTIFACT,runner=self.runner,expected_owner_uid=os.getuid())
        self.runner.run.side_effect=self.run_command
        self.authority=patch('forge_platform.ep_installation_pairing_adapter._exact_ep_instance_runtime',
            return_value=(Path('/qualified/bin/python'),self.data/'epdata.sqlite',os.getuid(),os.getgid()))
        self.authority.start();self.addCleanup(self.authority.stop)
    def tearDown(self):self.tmp.cleanup()
    def status(self):
        s=self.scope
        return dict(binding_id=s.binding_id,ep_instance_id=s.ep_instance_id,forge_instance_id=s.forge_runtime_id,
                    consumer_id=s.consumer_id,purpose='INSTALLATION_READBACK',status='ACTIVE',credentials=self.metadata)
    def run_command(self,argv,**kwargs):
        self.calls.append((argv,kwargs));action=argv[4]
        if action=='installation-pairing-issue':
            self.metadata=[dict(credential_id='installation-'+'3'*32,operation_id=self.scope.issuance_operation_id,
                                issued_at='2026-10-08T10:00:00+00:00',status='ACTIVE')]
            value=dict(credential_id=self.metadata[0]['credential_id'],binding_id=self.scope.binding_id,
                       operation_id=self.scope.issuance_operation_id,purpose='INSTALLATION_READBACK',credential=self.material)
        else:value=self.status()
        return EPInstallationCommandResult(0,json.dumps(value).encode())
    def store(self):
        store=object.__new__(ManagedSystemKeychainCredentialStore)
        fingerprint=sha256(_EP_FINGERPRINT_DOMAIN+self.material.encode()).hexdigest()
        store.fingerprint=Mock(side_effect=[None,fingerprint]);store.put_verified=Mock(return_value=True)
        return store

    def test_release_pin_is_separate_from_historical_project_lifecycle(self):
        self.assertTrue(qualified_ep_installation_pairing_artifact(ARTIFACT))
        self.assertFalse(qualified_ep_lifecycle_artifact(ARTIFACT))
        for changed in (None,replace(ARTIFACT,version='2.3.106'),replace(ARTIFACT,source_revision='0'*40),
                        replace(ARTIFACT,digest='sha256:'+'0'*64)):
            self.assertFalse(qualified_ep_installation_pairing_artifact(changed))

    def test_register_uses_exact_runtime_identity_and_no_project_or_repository(self):
        self.driver.register();self.assertEqual(len(self.calls),2)
        argv,kwargs=self.calls[0]
        self.assertEqual(argv[:5],('/qualified/bin/python','-IB','-m','engineering_platform.server','installation-pairing-register'))
        self.assertIn(self.scope.forge_runtime_id,argv)
        self.assertNotIn('--project-id',argv);self.assertNotIn('--repository-id',argv)
        self.assertNotIn(self.material,argv);self.assertEqual(kwargs['uid'],os.getuid())
        self.assertEqual(kwargs['data_root'],self.data)

    def test_issue_moves_disclosure_only_to_native_store_and_returns_none(self):
        store=self.store();self.assertIsNone(self.driver.issue_to_store(store))
        store.put_verified.assert_called_once_with(self.scope.credential_reference,self.scope.operation_id,self.material)
        self.assertNotIn(self.material,str(self.calls))
        self.assertEqual(self.driver.status()['credentials'][0]['operation_id'],self.scope.issuance_operation_id)

    def test_wrong_store_or_occupied_reference_prevents_issue(self):
        with self.assertRaises(TypeError):self.driver.issue_to_store(Mock())
        store=self.store();store.fingerprint=Mock(return_value='4'*64)
        with self.assertRaises(InstallationCredentialError):self.driver.issue_to_store(store)
        self.runner.run.assert_not_called()

    def test_changed_scope_duplicate_fields_or_nonfinite_output_rejected(self):
        for raw in (b'{"binding_id":"a","binding_id":"b"}',b'{"value":NaN}',
                    json.dumps(dict(self.status(),consumer_id='other')).encode()):
            self.runner.run.side_effect=None;self.runner.run.return_value=EPInstallationCommandResult(0,raw)
            with self.assertRaises(InstallationCredentialError):self.driver.status()

    def test_root_owned_private_data_uses_published_owner_administration(self):
        self.driver.expected_owner_uid=0
        with patch("forge_platform.ep_installation_pairing_adapter.os.lstat",
                   return_value=SimpleNamespace(st_uid=0,st_mode=0o40700)):
            self.driver.register()
        self.assertEqual(self.calls[0][1]["uid"],0)
        self.assertEqual(self.calls[0][1]["gid"],0)
        self.calls.clear()
        with patch("forge_platform.ep_installation_pairing_adapter.os.lstat",
                   return_value=SimpleNamespace(st_uid=999999,st_mode=0o40700)):
            with self.assertRaises(InstallationCredentialError):
                self.driver.register()
        self.assertEqual(self.calls,[])


    def test_subprocess_runner_allows_only_matching_root_data_owner(self):
        runner=SubprocessEPInstallationCommandRunner()
        argv=('/qualified/bin/python','-IB','-m','engineering_platform.server',
              'installation-pairing-status','--data-root',str(self.data),
              '--expected-instance-id','ep-instance','--peer-binding-id','binding','--operation-id','operation')
        with patch('forge_platform.ep_installation_pairing_adapter.os.geteuid',return_value=0), \
             patch('forge_platform.ep_installation_pairing_adapter.os.lstat',
                   return_value=SimpleNamespace(st_uid=0,st_mode=0o40700)), \
             patch('forge_platform.ep_installation_pairing_adapter.subprocess.run',
                   return_value=SimpleNamespace(returncode=0,stdout=b'{}')) as process:
            self.assertEqual(runner.run(argv,data_root=self.data,uid=0,gid=0).returncode,0)
            self.assertEqual(process.call_args.kwargs['user'],0)
            self.assertEqual(process.call_args.kwargs['group'],0)
            with patch('forge_platform.ep_installation_pairing_adapter.os.lstat',
                       return_value=SimpleNamespace(st_uid=501,st_mode=0o40700)):
                with self.assertRaises(InstallationCredentialError):
                    runner.run(argv,data_root=self.data,uid=0,gid=0)
            self.assertEqual(process.call_count,1)

    def test_subprocess_runner_rejects_foreign_owner_or_noninstallation_command(self):
        runner=SubprocessEPInstallationCommandRunner()
        argv=('/qualified/bin/python','-IB','-m','engineering_platform.server',
              'installation-pairing-status','--data-root',str(self.data),
              '--expected-instance-id','ep-instance','--peer-binding-id','binding','--operation-id','operation')
        with patch('forge_platform.ep_installation_pairing_adapter.os.geteuid',return_value=0), \
             patch('forge_platform.ep_installation_pairing_adapter.subprocess.run') as process:
            for command,uid in ((argv,999999),(argv[:4]+('other-command',)+argv[5:],os.getuid())):
                with self.assertRaises(InstallationCredentialError):
                    runner.run(command,data_root=self.data,uid=uid,gid=os.getgid())
            process.assert_not_called()

    def test_private_data_owner_and_mode_checked_before_command(self):
        self.data.chmod(0o755)
        with self.assertRaises(InstallationCredentialError):self.driver.status()
        self.runner.run.assert_not_called()

    def test_bad_disclosure_cannot_reach_native_store(self):
        self.runner.run.side_effect=None
        self.runner.run.return_value=EPInstallationCommandResult(0,b'{"credential":"SOURCE_FIXTURE_ONLY"}')
        store=self.store()
        with self.assertRaises(InstallationCredentialError):self.driver.issue_to_store(store)
        store.put_verified.assert_not_called()

    def test_store_failure_is_uncertain_and_does_not_return_material(self):
        store=self.store();store.put_verified.return_value=False
        with self.assertRaises(InstallationCredentialError) as caught:self.driver.issue_to_store(store)
        self.assertNotIn(self.material,str(caught.exception));self.assertIsNone(caught.exception.__cause__)

if __name__=='__main__':unittest.main()
