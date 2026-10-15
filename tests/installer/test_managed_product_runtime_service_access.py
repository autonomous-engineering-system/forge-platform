"""Source schema/guard regressions; isolated kernel evidence is kept separately."""
from copy import deepcopy
from hashlib import sha256
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from forge_platform.managed_product_runtime_service_access import (
    ManagedProductRuntimeServiceAccess, RuntimeServiceAccessError, _Claim, _claims, _identity,
)


def authority():
    payload = json.loads(Path('compositions/forge-ep-2.8.1-2.3.113.json').read_bytes())
    canonical = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    artifacts = {c['identity']: c['artifact']['digest'] for c in payload['components']}
    return {'schema': 'forge-platform.product-worker-authority/v7', 'routes': [], 'single_routes': [],
        'candidate_manifests': [{'payload': payload, 'digest': 'sha256:' + sha256(canonical).hexdigest()}],
        'installed_manifests': [], 'installation_routes': [{'ep_instance_id': 'fpi-' + 'a' * 40,
        'forge_instance_id': 'fpi-' + 'b' * 40, 'ep_venv_slot':'venv-'+'a'*64,
        'forge_venv_slot':'venv-'+'b'*64, 'ep_service_account': '_fpi_' + 'a' * 20,
        'forge_service_account': 'sourceoperator', 'forge_service_user_identity_sha256': 'sha256:' + '1' * 64,
        'ep_artifact_sha256': artifacts['engineering-platform-server'],
        'forge_artifact_sha256': artifacts['forge-runtime']}]}


class RuntimeServiceClaimTests(unittest.TestCase):
    def test_exact_manifest_runtime_is_derived_for_both_distinct_claims(self):
        claims, versions = _claims(authority())
        self.assertEqual([c.name for c in claims], ['_fpi_' + 'a' * 20, 'sourceoperator'])
        self.assertEqual({c.runtime_identity for c in claims}, set(versions))
        self.assertEqual(list(versions.values()), ['3.14.7'])
        self.assertIsNone(claims[0].named_identity)
        self.assertEqual(claims[1].named_identity, 'sha256:' + '1' * 64)

    def test_old_or_mixed_authority_is_not_silently_widened(self):
        for change in [{'schema': 'forge-platform.product-worker-authority/v6'},
                       {'routes': [{}]}, {'single_routes': [{}]}, {'installation_routes': []}]:
            wire = authority(); wire.update(change)
            with self.assertRaises(RuntimeServiceAccessError): _claims(wire)

    def test_duplicate_user_or_unsafe_instance_rejected(self):
        for key, value in [('forge_service_account', '_fpi_' + 'a' * 20),
                           ('ep_instance_id', '../unrelated')]:
            wire = authority(); wire['installation_routes'][0][key] = value
            with self.assertRaises(RuntimeServiceAccessError): _claims(wire)

    def test_manifest_bytes_cannot_select_another_runtime_without_digest(self):
        wire = authority(); wire['candidate_manifests'][0]['payload']['python_runtime']['version'] = '3.14.6'
        with self.assertRaises(Exception): _claims(wire)

    def test_artifact_not_in_qualified_manifest_rejected(self):
        wire = authority(); wire['installation_routes'][0]['ep_artifact_sha256'] = 'sha256:' + '0' * 64
        with self.assertRaises(KeyError): _claims(wire)

    def test_constructor_performs_no_io_or_mutation(self):
        with patch('forge_platform.managed_product_runtime_service_access.os.open', side_effect=AssertionError('IO')):
            value = ManagedProductRuntimeServiceAccess(root=Path('/private/tmp/ForgePlatformInstaller'),
                base_python=None, authority_sha256='sha256:' + '0' * 64, selected_account='sourceoperator')
        self.assertIsNone(value.base_python)

    def test_named_identity_and_kernel_uuid_must_agree(self):
        from types import SimpleNamespace
        from forge_platform.managed_installer_user_identity import canonical_identity
        identity = '12345678-1234-1234-1234-123456789abc'
        wanted = 'sha256:' + sha256(canonical_identity('sourceoperator', 501, 20, identity)).hexdigest()
        claim = _Claim('sourceoperator', 'fpi-' + 'a' * 40, wanted, 'sha256:' + '0' * 64)
        with patch('forge_platform.managed_product_runtime_service_access.pwd.getpwnam',
                   return_value=SimpleNamespace(pw_name='sourceoperator', pw_uid=501, pw_gid=20)), \
             patch('forge_platform.managed_product_runtime_service_access.resolve_identity_sha256', return_value=wanted), \
             patch('forge_platform.managed_product_runtime_service_access._kernel_uuid', return_value=identity):
            self.assertEqual(_identity(Path('/private/tmp/ForgePlatformInstaller'), claim), (501, 20, wanted))
            with patch('forge_platform.managed_product_runtime_service_access._kernel_uuid',
                       return_value='00000000-0000-0000-0000-000000000001'):
                with self.assertRaises(RuntimeServiceAccessError): _identity(Path('/private/tmp/ForgePlatformInstaller'), claim)

    def test_dedicated_identity_uses_strict_existing_disabled_account_reader(self):
        from types import SimpleNamespace
        identity = '12345678-1234-1234-1234-123456789abc'
        claim = _Claim('_fpi_' + 'a' * 20, 'fpi-' + 'a' * 40, None, 'sha256:' + '0' * 64)
        reader = SimpleNamespace(bind_account=lambda: None, account_identity=(400000, 400000, identity))
        with patch('forge_platform.managed_product_runtime_service_access.pwd.getpwnam',
                   return_value=SimpleNamespace(pw_name=claim.name, pw_uid=400000, pw_gid=400000)), \
             patch('forge_platform.managed_ep_service_preparation.ManagedEPServicePreparation', return_value=reader), \
             patch('forge_platform.managed_product_runtime_service_access._kernel_uuid', return_value=identity):
            self.assertEqual(_identity(Path('/private/tmp/ForgePlatformInstaller'), claim), reader.account_identity)
            with patch('forge_platform.managed_product_runtime_service_access._kernel_uuid',
                       return_value='00000000-0000-0000-0000-000000000001'):
                with self.assertRaises(RuntimeServiceAccessError): _identity(Path('/private/tmp/ForgePlatformInstaller'), claim)




@unittest.skipUnless(__import__('sys').platform == 'darwin' and __import__('os').geteuid() == 0,
                     'isolated root-owned runtime kernel qualification')
class RuntimeServiceKernelRootTests(unittest.TestCase):
    """Real public interpreter/OS access; helper record and CI EP projection modeled."""
    @classmethod
    def setUpClass(cls):
        import os, stat, tempfile, urllib.request, tarfile, pwd
        from forge_platform.managed_forge_instance_bootstrap import _search
        from forge_platform.managed_installer_user_identity import resolve_identity_sha256
        cls.temp = tempfile.TemporaryDirectory(prefix='l1-runtime-repo-', dir='/private/tmp')
        cls.outer = Path(cls.temp.name); cls.outer.chmod(0o755)
        cls.root = cls.outer / 'ForgePlatformInstaller'; cls.root.mkdir(mode=0o700)
        try: cls.named = pwd.getpwnam('forgebuild')
        except KeyError: cls.named = pwd.getpwuid(501)
        cls.ep_uid = pwd.getpwnam('nobody').pw_uid; cls.ep_gid = pwd.getpwnam('nobody').pw_gid
        wire = authority(); route = wire['installation_routes'][0]
        route['forge_service_account'] = cls.named.pw_name
        route['forge_service_user_identity_sha256'] = resolve_identity_sha256(cls.named.pw_name)
        cls.ep_name = route['ep_service_account']
        cls.raw = json.dumps(wire, sort_keys=True, separators=(',', ':')).encode()
        cls.authority = cls.root / 'product-worker-authority.json'
        cls.authority.write_bytes(cls.raw); cls.authority.chmod(0o600)
        cls.digest = 'sha256:' + sha256(cls.raw).hexdigest()
        runtime = wire['candidate_manifests'][0]['payload']['python_runtime']
        cls.slots = cls.root / 'managed-python-runtime-slots'; cls.slots.mkdir(mode=0o700)
        cls.slot = cls.slots / ('sha256-' + runtime['identity_digest'][7:]); cls.slot.mkdir(mode=0o700)
        cache = Path(tempfile.gettempdir()).resolve() / ('fpi-runtime-source-cache-' + str(os.geteuid()))
        cache.mkdir(mode=0o700, exist_ok=True)
        details = cache.lstat()
        assert stat.S_ISDIR(details.st_mode) and details.st_uid == 0 and stat.S_IMODE(details.st_mode) == 0o700 and not cache.is_symlink()
        archive = cache / (runtime['artifact']['digest'][7:] + '.tar.gz')
        if not archive.exists():
            with urllib.request.urlopen(runtime['artifact']['url'], timeout=60) as response:
                data = response.read(128 * 1024 * 1024 + 1)
            assert len(data) <= 128 * 1024 * 1024 and 'sha256:' + sha256(data).hexdigest() == runtime['artifact']['digest']
            with archive.open('xb') as output:
                os.fchmod(output.fileno(), 0o600); output.write(data); output.flush(); os.fsync(output.fileno())
        details = archive.lstat()
        assert not archive.is_symlink() and details.st_uid == 0 and details.st_nlink == 1 and stat.S_IMODE(details.st_mode) == 0o600
        assert 'sha256:' + sha256(archive.read_bytes()).hexdigest() == runtime['artifact']['digest']
        with tarfile.open(archive, 'r:gz') as tar:
            members = tar.getmembers()
            assert all(not member.issym() and not member.islnk() and (member.isfile() or member.isdir())
                       and not Path(member.name).is_absolute() and '..' not in Path(member.name).parts for member in members)
            tar.extractall(cls.slot, filter='data')
        cls.slot.chmod(0o700); cls.python = cls.slot / 'bin/python3'
        import subprocess
        venvs=cls.root/'managed-python-product-venvs';venvs.mkdir(mode=0o700)
        for key in ('ep_venv_slot','forge_venv_slot'):
            venv=venvs/route[key]
            subprocess.run([str(cls.python),'-I','-m','venv','--without-pip','--copies',str(venv)],check=True,capture_output=True)
            venv.chmod(0o700)
        cls.host = cls.root / 'managed-python-host-state.json'
        cls.host_raw = json.dumps({'schema': 'forge-platform.managed-python-host-state/v1',
            'active_runtime_slot': cls.slot.name, 'active_runtime_identity': runtime['identity_digest']}, sort_keys=True).encode()
        cls.host.write_bytes(cls.host_raw); cls.host.chmod(0o600)
        fd = os.open(cls.root, os.O_RDONLY | os.O_DIRECTORY)
        try: _search(fd, [cls.ep_uid, cls.named.pw_uid])
        finally: os.close(fd)

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def projected_identity(self, root, claim):
        # The CI fixture EP name is not an invented OS account. Only this
        # source projection maps it to existing nobody for actual kernel IO.
        from forge_platform.managed_product_runtime_service_access import _kernel_uuid
        if claim.name == self.ep_name:
            return self.ep_uid, self.ep_gid, _kernel_uuid(self.ep_uid)
        return _identity(root, claim)

    def prep(self, **changes):
        values = dict(root=self.root, base_python=self.python, authority_sha256=self.digest,
                      selected_account=self.ep_name)
        values.update(changes)
        return ManagedProductRuntimeServiceAccess(**values)

    def acl(self, path):
        import subprocess
        return subprocess.check_output(['/bin/ls', '-lde', str(path)])

    def testActualPublicPythonAndVenvImportsUnderExistingNonrootUIDWithModeledEPClaim(self):
        import os, subprocess
        with patch('forge_platform.managed_product_runtime_service_access._identity', self.projected_identity):
            self.prep().prepare(); self.prep().prepare()
            self.prep(selected_account=self.named.pw_name).prepare()
        venv = self.outer / 'real-venv'
        subprocess.run([str(self.python), '-I', '-B', '-m', 'venv', '--without-pip', str(venv)],
                       check=True, stdout=subprocess.DEVNULL, env={'HOME': '/var/empty', 'PYTHONDONTWRITEBYTECODE': '1'})
        probe = "import ssl,sqlite3; ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); assert sqlite3.connect(':memory:').execute('select 7').fetchone()==(7,)"
        for uid, gid in [(self.ep_uid, self.ep_gid), (self.named.pw_uid, self.named.pw_gid)]:
            result = subprocess.run([str(venv / 'bin/python'), '-I', '-B', '-c', probe], user=uid, group=gid,
                extra_groups=(), capture_output=True, cwd='/var/empty', env={'HOME': '/var/empty'})
            self.assertEqual(result.returncode, 0, 'actual interpreter/stdlib access failed')
            result = subprocess.run(['/bin/test', '-w', str(self.slot)], user=uid, group=gid, extra_groups=())
            self.assertEqual(result.returncode, 1)
        self.assertEqual(self.authority.read_bytes(), self.raw)

    def testAuthorityHostAccountAndInterpreterDriftDenyBeforeGrant(self):
        import os
        with patch('forge_platform.managed_product_runtime_service_access._identity', self.projected_identity):
            for changes in [dict(selected_account='unselected-user'), dict(base_python=self.python.with_name('other')),
                            dict(authority_sha256='sha256:' + '0' * 64), dict(root=self.outer)]:
                before = self.acl(self.slots), self.acl(self.slot)
                with self.assertRaises(RuntimeServiceAccessError): self.prep(**changes).prepare()
                self.assertEqual(before, (self.acl(self.slots), self.acl(self.slot)))
            host = json.loads(self.host_raw); host['active_runtime_slot'] = 'sha256-' + '0' * 64
            self.host.write_text(json.dumps(host))
            try:
                before = self.acl(self.slots), self.acl(self.slot)
                with self.assertRaises(RuntimeServiceAccessError): self.prep().prepare()
                self.assertEqual(before, (self.acl(self.slots), self.acl(self.slot)))
            finally: self.host.write_bytes(self.host_raw)
            before = self.acl(self.slots), self.acl(self.slot)
            self.slot.chmod(0o755)
            try:
                with self.assertRaises(RuntimeServiceAccessError): self.prep().prepare()
            finally: self.slot.chmod(0o700)
            link = self.root / 'linked-python'; link.symlink_to(self.python)
            try:
                with self.assertRaises(RuntimeServiceAccessError): self.prep(base_python=link).prepare()
            finally: link.unlink()

    def testUnknownACLOnEitherRuntimeDirectoryIsPreservedAndRejected(self):
        import subprocess
        with patch('forge_platform.managed_product_runtime_service_access._identity', self.projected_identity):
            for path in [self.slots, self.slot]:
                subprocess.run(['/bin/chmod', '+a', 'everyone allow search', str(path)], check=True)
                before = self.acl(self.slots), self.acl(self.slot)
                try:
                    with self.assertRaises(RuntimeServiceAccessError): self.prep().prepare()
                    self.assertEqual(before, (self.acl(self.slots), self.acl(self.slot)))
                finally: subprocess.run(['/bin/chmod', '-a', 'everyone allow search', str(path)], check=True)

    def testSourceIdentityDriftAndActualKernelFailureDenyCompletion(self):
        import subprocess
        import forge_platform.managed_product_runtime_service_access as module
        calls = [0]
        def drift(root, claim):
            value = self.projected_identity(root, claim); calls[0] += 1
            return value if calls[0] <= 2 else (value[0] + 1, value[1], value[2])
        before = self.acl(self.slots), self.acl(self.slot)
        with patch.object(module, '_identity', drift):
            with self.assertRaises(RuntimeServiceAccessError): self.prep().prepare()
        self.assertEqual(before, (self.acl(self.slots), self.acl(self.slot)))
        actual = subprocess.run
        def fail_probe(*args, **kwargs):
            if args[0][0] == str(self.python): return subprocess.CompletedProcess(args[0], 1, b'', b'')
            return actual(*args, **kwargs)
        with patch.object(module, '_identity', self.projected_identity), patch.object(module.subprocess, 'run', fail_probe):
            with self.assertRaises(RuntimeServiceAccessError): self.prep().prepare()
    def testActualBaseInterpreterReplacementDeniesBeforeGrantOrUIDExecution(self):
        import os, subprocess
        import forge_platform.managed_product_runtime_service_access as module
        moved=self.python.with_name('python3.retained-test')
        original=self.python.read_bytes()
        actual_search=module._search;actual_run=subprocess.run
        def no_uid_probe(*args,**kwargs):
            if args[0][0]==str(self.python):raise AssertionError('UID probe must not start')
            return actual_run(*args,**kwargs)
        for stage in ('before-grant','before-probe'):
            identities=0;grants=0
            def replace():
                self.python.rename(moved);self.python.write_bytes(original);self.python.chmod(0o755)
            def identity(root,claim):
                nonlocal identities
                identities+=1
                if stage=='before-grant' and identities==3:replace()
                return self.projected_identity(root,claim)
            def search(fd,uids):
                nonlocal grants
                actual_search(fd,uids);grants+=1
                if stage=='before-probe' and grants==2:replace()
            try:
                with patch.object(module,'_identity',identity),patch.object(module,'_search',search), \
                     patch.object(module.subprocess,'run',no_uid_probe):
                    with self.assertRaises(RuntimeServiceAccessError):self.prep().prepare()
                self.assertEqual(grants,0 if stage=='before-grant' else 2)
            finally:
                if moved.exists():self.python.unlink();moved.rename(self.python)

    def testActualSelectedCopiedVenvDriftDeniesBeforeRuntimeGrants(self):
        import subprocess
        venv=self.root/'managed-python-product-venvs'/('venv-'+'a'*64)
        cfg=venv/'pyvenv.cfg';python=venv/'bin/python3'
        cfg_raw=cfg.read_bytes();python_raw=python.read_bytes()
        original=subprocess.check_output(['/bin/ls','-lde',str(self.slots),str(self.slot)])
        cases=[(python,b'foreign interpreter'),(cfg,b'home = /unbound\ninclude-system-site-packages = false\n'),
               (cfg,cfg_raw+b'home = /duplicate\n'),
               (cfg,cfg_raw.replace(b'include-system-site-packages = false',b'include-system-site-packages = true'))]
        try:
            for path,raw in cases:
                path.write_bytes(raw)
                with patch('forge_platform.managed_product_runtime_service_access._identity',self.projected_identity):
                    with self.assertRaises(RuntimeServiceAccessError):self.prep().prepare()
                self.assertEqual(subprocess.check_output(['/bin/ls','-lde',str(self.slots),str(self.slot)]),original)
                cfg.write_bytes(cfg_raw);python.write_bytes(python_raw)
        finally:cfg.write_bytes(cfg_raw);python.write_bytes(python_raw)

    def testActualRuntimeNamespaceReplacementDeniesBeforeGrantAndAfterProbe(self):
        import os, subprocess
        import forge_platform.managed_product_runtime_service_access as module
        moved=self.slot.with_name(self.slot.name+'.retained-test')
        before=subprocess.check_output(['/bin/ls','-lde',str(self.slots)]).splitlines()[1:]
        calls=0
        def replace_before_grant(root,claim):
            nonlocal calls
            calls+=1
            if calls==3:
                self.slot.rename(moved);self.slot.mkdir(mode=0o700)
            return self.projected_identity(root,claim)
        try:
            with patch.object(module,'_identity',replace_before_grant):
                with self.assertRaises(RuntimeServiceAccessError):self.prep().prepare()
            self.assertEqual(subprocess.check_output(['/bin/ls','-lde',str(self.slots)]).splitlines()[1:],before)
        finally:
            if moved.exists():self.slot.rmdir();moved.rename(self.slot)
        actual=subprocess.run
        def replace_after_probe(*args,**kwargs):
            result=actual(*args,**kwargs)
            if args[0][0]==str(self.python):
                self.slot.rename(moved);self.slot.mkdir(mode=0o700)
            return result
        try:
            with patch.object(module,'_identity',self.projected_identity),patch.object(module.subprocess,'run',replace_after_probe):
                with self.assertRaises(RuntimeServiceAccessError):self.prep().prepare()
        finally:
            if moved.exists():self.slot.rmdir();moved.rename(self.slot)



if __name__ == '__main__':
    unittest.main()
