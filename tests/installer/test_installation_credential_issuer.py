"""Source fixtures for saga integration; no installed or credential proof."""
from dataclasses import replace
from hashlib import sha256
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

from forge_platform.installation_credential_issuer import ManagedEPInstallationCredentialIssuer
from forge_platform.managed_ep_installation_credential import InstallationCredentialError
from forge_platform.managed_ep_credential_issuance import _deployment_fingerprint, _EP_FINGERPRINT_DOMAIN
from forge_platform.managed_deployments import ManagedDeployment, ManagedDeploymentRegistry, ManagedComponentBinding, ManagedPeerBinding
from forge_platform.managed_system_keychain_store import ManagedSystemKeychainCredentialStore
from forge_platform.forge_server_adapter import ForgeServerProductAdapter
from forge_platform.engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from forge_platform.forge_ep_pairing_executor import ForgeEPInstallationPairingBinding
from forge_platform.component_operations import QualifiedArtifact
from tests.installer.test_ep_installation_pairing_adapter import ARTIFACT


class Product:
    def __init__(self,scope):self.scope=scope;self.credentials=[];self.calls=0
    def register(self):pass
    def status(self):
        s=self.scope
        return dict(binding_id=s.binding_id,ep_instance_id=s.ep_instance_id,forge_instance_id=s.forge_runtime_id,
                    consumer_id=s.consumer_id,purpose='INSTALLATION_READBACK',status='ACTIVE',credentials=self.credentials)
    def issue_to_store(self,store):
        self.calls+=1;s=self.scope
        self.credentials=[dict(credential_id='installation-'+'4'*32,operation_id=s.issuance_operation_id,
                               issued_at='2026-10-08T10:00:00+00:00',status='ACTIVE')]
        store.put_verified(s.credential_reference,s.operation_id,'SOURCE_FIXTURE_ONLY')


class InstallationIssuerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.registry=ManagedDeploymentRegistry(self.root/'registry')
        self.current=ManagedDeployment('deployment',1,None,(
            ManagedComponentBinding('forge-runtime','forge-selector','receipt:forge'),
            ManagedComponentBinding('engineering-platform-server','ep-instance','receipt:ep')))
        self.registry.create(self.current);self.guard=Mock()
        self.binding=ForgeEPInstallationPairingBinding('installer-op','binding','http://127.0.0.1:26685',
            'ep-instance','consumer','keychain://installation/new',True)
        self.forge=object.__new__(ForgeServerProductAdapter)
        self.forge.target=SimpleNamespace(instance_id='forge-selector',product_runtime_id='forge-runtime-uuid',
            service_user_identity_sha256='sha256:'+'1'*64)
        self.forge.installed_artifact=QualifiedArtifact('2.8.1','c8833ffa4754800de451cce94b109ef1ad07123f','published-wheel',
            'sha256:7e4b6cf2bd4544865ca980ff9c5c0f7e4b104cd9a47f11dc6d1e3e944e1942c0','release-complete')
        self.ep=object.__new__(EngineeringPlatformSystemProvisionerAdapter);self.ep.target=SimpleNamespace(instance_id='ep-instance')
        self.store=object.__new__(ManagedSystemKeychainCredentialStore);self.fingerprint=None
        self.store.fingerprint=lambda ref,op:self.fingerprint
        def put(ref,op,material):self.fingerprint=sha256(_EP_FINGERPRINT_DOMAIN+material.encode()).hexdigest();return True
        self.store.put_verified=put;self.products={}
        def product(**kwargs):
            scope=kwargs['scope'];key=scope.issuance_operation_id
            if key not in self.products:self.products[key]=Product(scope)
            return self.products[key]
        self.patch=patch('forge_platform.installation_credential_issuer.EPInstallationPairingProductAdapter',side_effect=product)
        self.patch.start();self.addCleanup(self.patch.stop)
        self.issuer=ManagedEPInstallationCredentialIssuer(operations_root=self.root/'issuance',deployment_id='deployment',
            binding=self.binding,registry=self.registry,currency_guard=self.guard,forge=self.forge,ep=self.ep,
            ep_artifact=ARTIFACT,store=self.store,expected_owner_uid=os.getuid())
    def tearDown(self):self.tmp.cleanup()
    def ensure(self,**changes):
        args=dict(operation_id='installer-op',reviewed_current=self.current,
                  reviewed_fingerprint=_deployment_fingerprint(self.current),credential_reference=self.binding.credential_reference)
        args.update(changes);return self.issuer.ensure(**args)
    def paired(self):
        p=replace(self.current,revision=2,peer_binding=ManagedPeerBinding('forge-selector','ep-instance','receipt:pairing'))
        self.registry.replace(p,expected_revision=1);return p

    def test_saga_issuer_freezes_real_post_product_receipts(self):
        record=self.ensure();self.assertEqual(record.state,'COMPLETE')
        self.assertEqual(record.scope.forge_runtime_id,'forge-runtime-uuid')
        self.assertEqual(record,self.ensure())
        self.assertEqual(sum(p.calls for p in self.products.values()),1)

    def test_terminal_read_after_pairing_preserves_original_issue(self):
        record=self.ensure();paired=self.paired()
        self.assertEqual(record,self.issuer.read_terminal(operation_id=None,deployment=paired))
        self.assertEqual(sum(p.calls for p in self.products.values()),1)

    def test_changed_component_receipt_cannot_reuse_terminal_credential(self):
        self.ensure();p=replace(self.current,revision=2,components=(
            ManagedComponentBinding('forge-runtime','forge-selector','receipt:changed'),self.current.components[1]))
        self.registry.replace(p,expected_revision=1)
        with self.assertRaises(InstallationCredentialError):self.issuer.read_terminal(operation_id=None,deployment=p)

    def test_wrong_operation_reference_or_fingerprint_prevents_issuance(self):
        for changed in (dict(operation_id='other'),dict(credential_reference='keychain://installation/other'),
                        dict(reviewed_fingerprint='sha256:'+'0'*64)):
            with self.subTest(changed=changed):
                with self.assertRaises(InstallationCredentialError):self.ensure(**changed)
        self.assertFalse(self.products)

    def test_unqualified_forge_or_changed_operator_prevents_terminal_reuse(self):
        self.ensure();self.forge.target.service_user_identity_sha256='sha256:'+'2'*64
        with self.assertRaises(InstallationCredentialError):self.issuer.read_terminal(operation_id=None,deployment=self.current)
        self.forge.target.service_user_identity_sha256='sha256:'+'1'*64
        self.forge.installed_artifact=replace(self.forge.installed_artifact,version='2.7.39')
        with self.assertRaises(InstallationCredentialError):self.ensure()

    def test_registry_or_currency_change_stops_terminal_read(self):
        self.ensure();self.guard.require_current.side_effect=RuntimeError('source fixture stale authority')
        with self.assertRaises(RuntimeError):self.issuer.read_terminal(operation_id=None,deployment=self.current)

    def test_missing_operation_journal_has_no_fallback(self):
        with self.assertRaises(InstallationCredentialError):self.issuer.read_terminal(operation_id=None,deployment=self.current)
        self.assertEqual(sum(p.calls for p in self.products.values()),0)

    def test_resolved_route_requires_exact_installation_issuer_without_legacy_scope(self):
        from forge_platform.managed_product_operation_dispatch import ResolvedManagedProductRoute
        from forge_platform.forge_ep_pairing_executor import ForgeEPInstallationPairingExecutor
        pairer=ForgeEPInstallationPairingExecutor(self.binding)
        adapters={'forge-runtime':self.forge,'engineering-platform-server':self.ep}
        with self.assertRaises(ValueError):
            ResolvedManagedProductRoute('forge-selector','ep-instance',adapters,pairer)
        route=ResolvedManagedProductRoute('forge-selector','ep-instance',adapters,pairer,
                                          installation_credential_issuer=self.issuer)
        self.assertIs(route.installation_credential_issuer,self.issuer)
        self.assertIsNone(route.ep_consumer_revoker)
        self.issuer.binding=replace(self.binding,consumer_id='other-consumer')
        with self.assertRaises(ValueError):
            ResolvedManagedProductRoute('forge-selector','ep-instance',adapters,pairer,
                                          installation_credential_issuer=self.issuer)

    def test_invalid_reviewed_current_rejected_before_product_effect(self):
        with self.assertRaises(InstallationCredentialError):self.ensure(reviewed_current=object())
        self.assertFalse(self.products)

if __name__=='__main__':unittest.main()
