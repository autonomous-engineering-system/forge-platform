"""Filesystem safety of installer-owned identity evidence; no product fixture runs."""
from pathlib import Path
import hashlib
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from forge_platform.managed_forge_instance_bootstrap import (
    ForgeInstanceBootstrapError, ManagedForgeInstanceBootstrap,
    _canonical, _publish, _record, binding_path, read_runtime_binding,
    _credential_account_uids,
)


class CredentialAccountAuthorityTests(unittest.TestCase):
    def authority(self, name='alice', identity='sha256:'+'a'*64):
        return {'schema':'forge-platform.product-worker-authority/v6',
                'routes':[{'forge_service_account':name,
                           'forge_service_user_identity_sha256':identity}]}

    def test_v7_installation_cohort_requires_same_actual_named_identity(self):
        identity='sha256:'+'a'*64
        route={'forge_service_account':'alice','forge_service_user_identity_sha256':identity}
        a={'schema':'forge-platform.product-worker-authority/v7','installation_routes':[route,dict(route)]}
        with patch('forge_platform.managed_forge_instance_bootstrap.resolve_identity_sha256',return_value=identity), \
             patch('forge_platform.managed_forge_instance_bootstrap.pwd.getpwnam',return_value=SimpleNamespace(pw_uid=1203)):
            self.assertEqual(_credential_account_uids(a,'alice'),[1203])
            conflicting=dict(a,installation_routes=[route,dict(route,forge_service_user_identity_sha256='sha256:'+'b'*64)])
            with self.assertRaises(ForgeInstanceBootstrapError):_credential_account_uids(conflicting,'alice')
            with self.assertRaises(ForgeInstanceBootstrapError):_credential_account_uids(a,'bob')
        with patch('forge_platform.managed_forge_instance_bootstrap.resolve_identity_sha256',return_value='sha256:'+'b'*64):
            with self.assertRaises(ForgeInstanceBootstrapError):_credential_account_uids(a,'alice')

    def test_named_account_requires_matching_real_identity_and_v6(self):
        a=self.authority()
        with patch('forge_platform.managed_forge_instance_bootstrap.resolve_identity_sha256',return_value='sha256:'+'a'*64), \
             patch('forge_platform.managed_forge_instance_bootstrap.pwd.getpwnam',return_value=SimpleNamespace(pw_uid=1203)):
            self.assertEqual(_credential_account_uids(a,'alice'),[1203])
            for changed in [self.authority(identity=None),self.authority(identity='sha256:'+'b'*64),
                            {**a,'schema':'forge-platform.product-worker-authority/v5'}]:
                with self.assertRaises(ForgeInstanceBootstrapError):
                    _credential_account_uids(changed,'alice')

    def test_unselected_or_duplicated_accounts_are_rejected(self):
        a=self.authority()
        with self.assertRaises(ForgeInstanceBootstrapError):_credential_account_uids(a,'bob')
        a['routes']*=2
        with self.assertRaises(ForgeInstanceBootstrapError):_credential_account_uids(a,'alice')

    def test_dedicated_account_retains_historical_route(self):
        name='_fpi_'+'b'*20
        with patch('forge_platform.managed_forge_instance_bootstrap.pwd.getpwnam',return_value=SimpleNamespace(pw_uid=230045)):
            self.assertEqual(_credential_account_uids(self.authority(name,None),name),[230045])
            with self.assertRaises(ForgeInstanceBootstrapError):
                _credential_account_uids(self.authority(name),name)


class ForgeInstanceBootstrapSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.owner = os.geteuid()
        original_open = __import__('forge_platform.managed_forge_instance_bootstrap', fromlist=['_open'])._open
        # Only filesystem ownership projection differs in this unit harness;
        # production still requires root. No CLI/backend/credential execution.
        def owned_open(path, *, directory=False, owners=(0,), modes=(0o700,)):
            return original_open(path, directory=directory, owners=(self.owner,), modes=modes)
        self.patcher = patch('forge_platform.managed_forge_instance_bootstrap._open', side_effect=owned_open)
        self.patcher.start()
    def tearDown(self):
        self.patcher.stop(); self.temp.cleanup()
    def target(self):
        instance = 'fpi-' + 'a' * 40
        return SimpleNamespace(instance_id=instance, service_account='_fpi_'+'b'*20,
            instances_root=self.root/'instances/forge', data_root=self.root/'instances/forge'/instance)
    def value(self, target):
        return {'schema':'forge-platform.forge-runtime-binding/v1','selector':target.instance_id,
            'data_root':str(target.data_root),'service_account':target.service_account,
            'runtime_id':'forge-runtime-12345678-1234-1234-1234-123456789abc',
            'artifact':{'version':'2.7.39','digest':'sha256:'+'c'*64,'source_revision':'d'*40},
            'provider_context_digest':'sha256:'+'e'*64}
    def test_exact_product_uuid_is_bound_without_replacing_installer_selector(self):
        target=self.target();path=binding_path(target)
        path.parent.mkdir(parents=True,mode=0o700)
        value=self.value(target);_publish(path,value)
        self.assertEqual(read_runtime_binding(target)['runtime_id'],value['runtime_id'])
        self.assertEqual(read_runtime_binding(target)['selector'],target.instance_id)
        self.assertNotEqual(value['runtime_id'],target.instance_id)
    def test_foreign_target_mapping_is_rejected(self):
        target=self.target();path=binding_path(target);path.parent.mkdir(parents=True,mode=0o700)
        value=self.value(target);value['data_root']=str(self.root/'foreign')
        _publish(path,value)
        with self.assertRaises(ForgeInstanceBootstrapError):read_runtime_binding(target)
    def test_conflicting_publication_preserves_original_bytes(self):
        p=self.root/'binding.json';_publish(p,{'identity':'original'});before=p.read_bytes()
        _publish(p,{'identity':'original'})
        with self.assertRaises(ForgeInstanceBootstrapError):_publish(p,{'identity':'replacement'})
        self.assertEqual(p.read_bytes(),before)
        self.assertEqual(p.stat().st_nlink,1)
        self.assertEqual(p.stat().st_mode&0o777,0o600)
    def test_symlink_and_hardlink_evidence_is_not_admitted(self):
        p=self.root/'binding.json';_publish(p,{'identity':'original'})
        link=self.root/'link.json';link.symlink_to(p)
        with self.assertRaises(OSError):_record(link)
        hard=self.root/'hard.json';os.link(p,hard)
        with self.assertRaises(ForgeInstanceBootstrapError):_record(p)
    def test_bootstrap_cannot_choose_an_external_credential_route(self):
        target=self.target();target.api_credential_file=self.root/'foreign.token'
        artifact=SimpleNamespace(version='2.7.39')
        with self.assertRaises(ForgeInstanceBootstrapError):
            ManagedForgeInstanceBootstrap(root=self.root,target=target,artifact=artifact,
                executable=self.root/'bin/forge',codex_executable=self.root/'bin/codex',
                codex_home=self.root/'home',codex_digest='sha256:'+'a'*64)


class StandaloneReadinessBoundaryTests(unittest.TestCase):
    def probe(self, strict, standalone):
        import json
        from forge_platform.forge_server_adapter import ForgeHTTPReadinessProbe
        class Response:
            def __init__(self, value): self.value=value
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self,n): return json.dumps(self.value).encode()
        temp=tempfile.TemporaryDirectory(dir='/private/tmp')
        token=Path(temp.name)/'local-api-token';token.write_text('unrelated-unit-test-service-token')
        target=SimpleNamespace(api_credential_file=token,bind_port=12345,product_runtime_id='expected-runtime')
        return temp,target,Response,ForgeHTTPReadinessProbe(allow_standalone=True)
    def test_only_unconfigured_peer_allows_explicit_standalone_contract(self):
        peer={'state':'NOT_CONFIGURED','ready':False}
        strict={'ready':False,'instance_id':'expected-runtime','execution_host_peer':peer}
        standalone={**strict,'ready':True,'service_ready':True,'execution_ready':False,
            'mode':'STANDALONE','contract_version':'forge-server-standalone-readiness/v1'}
        temp,target,response,probe=self.probe(strict,standalone)
        with temp,patch('forge_platform.forge_server_adapter.urllib_request.urlopen',side_effect=[response(strict),response(standalone)]) as transport:
            self.assertTrue(probe.readiness(target)['ready'])
            self.assertEqual(transport.call_count,2)
            self.assertTrue(transport.call_args.args[0].full_url.endswith('/v1/readiness/standalone'))
    def test_stale_configured_peer_never_falls_back_to_standalone(self):
        strict={'ready':False,'instance_id':'expected-runtime','execution_host_peer':{'state':'NOT_READY','ready':False}}
        temp,target,response,probe=self.probe(strict,{})
        with temp,patch('forge_platform.forge_server_adapter.urllib_request.urlopen',return_value=response(strict)) as transport:
            self.assertFalse(probe.readiness(target)['ready'])
            self.assertEqual(transport.call_count,1)
    def test_foreign_instance_or_execution_readiness_is_rejected(self):
        from forge_platform.forge_server_adapter import ForgeServerAdapterError
        peer={'state':'NOT_CONFIGURED','ready':False}
        strict={'ready':False,'instance_id':'expected-runtime','execution_host_peer':peer}
        for replacement in [{'instance_id':'foreign'},{'execution_ready':True}]:
            standalone={**strict,'ready':True,'execution_ready':False,'mode':'STANDALONE',
                'contract_version':'forge-server-standalone-readiness/v1',**replacement}
            temp,target,response,probe=self.probe(strict,standalone)
            with temp,patch('forge_platform.forge_server_adapter.urllib_request.urlopen',side_effect=[response(strict),response(standalone)]):
                with self.assertRaises(ForgeServerAdapterError):probe.readiness(target)


if __name__=='__main__':unittest.main()
