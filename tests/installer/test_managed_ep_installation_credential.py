"""Isolated source fixtures only; no real credential or installed proof."""
from dataclasses import asdict, replace
from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from forge_platform.managed_deployments import ManagedDeployment, ManagedDeploymentRegistry, ManagedComponentBinding
from forge_platform.managed_ep_credential_issuance import _deployment_fingerprint
from forge_platform.managed_ep_installation_credential import (
    EPInstallationCredentialScope, InstallationCredentialError, ManagedEPInstallationCredentialCoordinator, installation_component_digest,
)


class Store:
    def __init__(self): self.value = None
    def fingerprint(self,reference,operation_id): return self.value
    def put_verified(self,reference,operation_id,material):
        self.value = sha256(material.encode()).hexdigest(); return True


class Product:
    def __init__(self,scope):
        self.scope=scope; self.register_calls=0; self.issue_calls=0; self.credentials=[]; self.failure=None
    def register(self): self.register_calls+=1
    def status(self):
        s=self.scope
        return dict(binding_id=s.binding_id,ep_instance_id=s.ep_instance_id,forge_instance_id=s.forge_runtime_id,
                    consumer_id=s.consumer_id,purpose='INSTALLATION_READBACK',status='ACTIVE',credentials=self.credentials)
    def issue_to_store(self,store):
        self.issue_calls+=1
        if self.failure=='before': raise RuntimeError('fixture before issue')
        s=self.scope
        self.credentials=[dict(credential_id='installation-'+'1'*32,operation_id=s.issuance_operation_id,
                               issued_at='2026-10-08T10:00:00+00:00',status='ACTIVE')]
        if self.failure=='after_product': raise RuntimeError('fixture after issue')
        store.put_verified(s.credential_reference,s.operation_id,'SOURCE_FIXTURE_MATERIAL_ONLY')
        if self.failure=='after_store': raise RuntimeError('fixture after secure store')


class InstallationCredentialJournalTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)
        self.registry=ManagedDeploymentRegistry(self.root/'registry')
        self.deployment=ManagedDeployment('deployment',1,None,(
            ManagedComponentBinding('forge-runtime','forge-selector','receipt:forge'),
            ManagedComponentBinding('engineering-platform-server','ep-instance','receipt:ep')))
        self.registry.create(self.deployment)
        self.scope=EPInstallationCredentialScope('installer-op','deployment','binding','forge-selector','forge-runtime-uuid',
            'ep-instance','consumer','keychain://installation/new-credential',_deployment_fingerprint(self.deployment),'sha256:'+'2'*64,installation_component_digest(self.deployment))
        self.product=Product(self.scope);self.store=Store();self.guard=Mock()
        self.coordinator=ManagedEPInstallationCredentialCoordinator(operations_root=self.root/'journal',registry=self.registry,
            currency_guard=self.guard,product=self.product,store=self.store,expected_owner_uid=os.getuid())
    def tearDown(self): self.tmp.cleanup()
    def journal(self): return json.loads((self.root/'journal/installer-op.json').read_text())

    def test_complete_retains_only_metadata_and_replay_never_issues_again(self):
        record=self.coordinator.ensure();self.assertEqual(record.state,'COMPLETE')
        self.assertEqual(record,self.coordinator.ensure())
        self.assertEqual(self.product.issue_calls,1);self.assertEqual(self.product.register_calls,1)
        raw=(self.root/'journal/installer-op.json').read_text()
        self.assertNotIn('SOURCE_FIXTURE_MATERIAL_ONLY',raw)
        self.assertNotIn('project_id',raw)
        self.assertEqual(self.journal()['scope']['forge_runtime_id'],'forge-runtime-uuid')

    def _lost_product_response(self,failure):
        self.product.failure=failure
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.journal()['state'],'ISSUING')
        count=self.product.issue_calls
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.product.issue_calls,count)

    def test_lost_response_before_product_issue_never_reissues(self):
        self._lost_product_response('before')

    def test_lost_response_after_product_issue_never_reissues(self):
        self._lost_product_response('after_product')

    def test_lost_response_after_secure_store_recovers_same_product_operation(self):
        self.product.failure='after_store'
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.journal()['state'],'ISSUING')
        record=self.coordinator.ensure();self.assertEqual(record.state,'COMPLETE')
        self.assertEqual(self.product.issue_calls,1)

    def test_changed_review_or_occupied_store_prevents_product_mutation(self):
        self.store.value='3'*64
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.product.register_calls,0)
        self.store.value=None;self.guard.require_current.side_effect=RuntimeError('review changed')
        with self.assertRaises(RuntimeError):self.coordinator.ensure()
        self.assertEqual(self.product.register_calls,0)

    def test_foreign_retained_operation_cannot_be_replaced(self):
        self.coordinator.ensure()
        self.product.scope=replace(self.scope,operation_id='other-op')
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.product.issue_calls,1)
        self.assertFalse((self.root/'journal/other-op.json').exists())

    def test_unsafe_or_changed_journal_rejects_before_product_mutation(self):
        self.coordinator.ensure();p=self.root/'journal/installer-op.json';p.chmod(0o644)
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        p.chmod(0o600);v=self.journal();v['scope']['consumer_id']='other';p.write_text(json.dumps(v))
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.product.issue_calls,1)

    def test_revoked_or_wrong_operation_metadata_cannot_complete(self):
        self.product.failure='after_store'
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.product.credentials[0]['operation_id']='wrong'
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.product.credentials[0]['operation_id']=self.scope.issuance_operation_id
        self.product.credentials[0]['status']='REVOKED'
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.journal()['state'],'ISSUING')

    def test_duplicate_product_credential_metadata_is_rejected(self):
        self.product.failure='after_store'
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.product.credentials.append(dict(self.product.credentials[0],operation_id='other-operation'))
        with self.assertRaises(InstallationCredentialError):self.coordinator.ensure()
        self.assertEqual(self.journal()['state'],'ISSUING')

if __name__=='__main__':unittest.main()
