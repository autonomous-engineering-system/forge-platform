"""Real Darwin ACL/inheritance qualification on isolated non-product paths."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from forge_platform.managed_ep_service_preparation import (
    EPServicePreparationError, ManagedEPServicePreparation, _acl, _open,
)


@unittest.skipUnless(sys.platform == "darwin", "Darwin ACL qualification")
class EPServiceACLTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="l1-ep-acl-",dir="/private/tmp")
        self.root = Path(self.temp.name)
        self.fd = os.open(self.root,os.O_RDONLY|os.O_DIRECTORY)
    def tearDown(self):
        os.close(self.fd);self.temp.cleanup()
    def test_root_style_creation_chmod_and_atomic_replace_keep_exact_file_access(self):
        _acl(self.fd,os.getuid(),directory=True)
        for name in ("server.json",".replacement"):
            fd=os.open(self.root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            os.fchmod(fd,0o600);os.close(fd)
        os.replace(self.root/".replacement",self.root/"server.json")
        fd=os.open(self.root/"server.json",os.O_RDONLY)
        try:_acl(fd,os.getuid(),directory=False,read_only=True)
        finally:os.close(fd)
        _acl(self.fd,os.getuid(),directory=True)
    def test_nested_directory_and_file_inherit_distinct_profiles(self):
        _acl(self.fd,os.getuid(),directory=True)
        nested=self.root/"nested";nested.mkdir(mode=0o700)
        fd=os.open(nested,os.O_RDONLY|os.O_DIRECTORY)
        try:_acl(fd,os.getuid(),directory=True,read_only=True)
        finally:os.close(fd)
        p=nested/"file";p.write_bytes(b"nonsecret qualification");p.chmod(0o600)
        fd=os.open(p,os.O_RDONLY)
        try:_acl(fd,os.getuid(),directory=False,read_only=True)
        finally:os.close(fd)
    def test_unknown_acl_is_preserved_and_rejected(self):
        added=subprocess.run(["/bin/chmod","+a","everyone allow read",str(self.root)],capture_output=True)
        self.assertEqual(added.returncode,0)
        before=subprocess.check_output(["/bin/ls","-lde",str(self.root)])
        with self.assertRaises(EPServicePreparationError):_acl(self.fd,os.getuid(),directory=True)
        self.assertEqual(subprocess.check_output(["/bin/ls","-lde",str(self.root)]),before)
    def test_zero_uid_rejected_without_acl_mutation(self):
        with self.assertRaises(EPServicePreparationError):_acl(self.fd,0,directory=True)
    def test_symlink_and_nonregular_target_are_rejected(self):
        p=self.root/"link";p.symlink_to(self.root)
        with self.assertRaises(OSError):_open(p,directory=True)
        with self.assertRaises(EPServicePreparationError):_open(self.root,directory=False)


class EPServicePreparationSelectionTests(unittest.TestCase):
    def test_unbounded_product_path_and_nonservice_identity_rejected(self):
        for root,account in ((Path("/tmp/unrelated"),"_fpi_"+"a"*20),
                             (Path("/tmp/products/engineering-platform"),"root")):
            with self.assertRaises(EPServicePreparationError):
                ManagedEPServicePreparation(product_root=root,instance_id="fpi-"+"a"*40,
                    service_account=account,uid=501,gid=20)



@unittest.skipUnless(sys.platform=='darwin' and os.geteuid()==0,'isolated root service-directory qualification')
class EPServiceRootAssemblyTests(unittest.TestCase):
    def testActualThreeFolderPreparationRetainsDataAndKnownACLsWithModeledOSAccountProjection(self):
        from unittest.mock import patch
        from hashlib import sha256
        import uuid
        from forge_platform.managed_ep_partial_create import _json
        uid=501;gid=20;identity=(uid,gid,str(uuid.uuid4()))
        account='_fpi_'+'a'*20
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root=Path(tmp);root.chmod(0o700);products=root/'products';products.mkdir(mode=0o700)
            product=products/'engineering-platform';product.mkdir(mode=0o700)
            instances=product/'instances';instances.mkdir(mode=0o700)
            instance=instances/('fpi-'+'a'*40);instance.mkdir(mode=0o700)
            data=instance/'data';data.mkdir(mode=0o700)
            server=data/'server.json';server.write_bytes(b'{"source_only":true}');server.chmod(0o600)
            authority=root/'product-worker-authority.json';authority.write_bytes(b'{"source_only":true}');authority.chmod(0o600)
            _,digest=_json(authority)
            prep=ManagedEPServicePreparation(product_root=product,instance_id=instance.name,service_account=account,
                uid=uid,gid=gid,cohort_accounts=(account,),authority_sha256=digest)
            prep.account_identity=identity
            def bind(value):value.uid=uid;value.gid=gid;value.account_identity=identity
            def recheck(value):
                if value.service_account!=account or value.account_identity!=identity:raise EPServicePreparationError('source OS drift')
            with patch.object(ManagedEPServicePreparation,'bind_account',bind),patch.object(ManagedEPServicePreparation,'_account',recheck):
                prep.prepare();prep.prepare()
                self.assertEqual(server.read_bytes(),b'{"source_only":true}')
                self.assertTrue((instance/'logs/server-launchdaemon.err.log').is_file())
                self.assertEqual(list((instance/'service-home').iterdir()),[])
                for folder in ('data','logs','service-home'):
                    fd=_open(instance/folder,directory=True)
                    try:_acl(fd,uid,directory=True,read_only=True)
                    finally:os.close(fd)
                foreign=data/'unknown.json';foreign.write_bytes(b'unknown');foreign.chmod(0o600)
                with self.assertRaises(EPServicePreparationError):prep.prepare()
                self.assertEqual(foreign.read_bytes(),b'unknown')

    def testBoundServiceAccountProjectionMustRemainExactWithoutCreatingAccount(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        from hashlib import sha256
        import uuid
        account='_fpi_'+'b'*20;uid=200000+int.from_bytes(sha256(account.encode()).digest()[:4],'big')%500000
        value=SimpleNamespace(pw_name=account,pw_uid=uid,pw_gid=uid)
        body='GeneratedUID: '+str(uuid.uuid4())+'\nUniqueID: '+str(uid)+'\nPrimaryGroupID: '+str(uid)+'\nNFSHomeDirectory: /var/empty\nUserShell: /usr/bin/false\nAuthenticationAuthority: ;DisabledUser;\n'
        prep=ManagedEPServicePreparation(product_root=Path('/private/tmp/source/products/engineering-platform'),instance_id='fpi-source',service_account=account)
        with patch('forge_platform.managed_ep_service_preparation.pwd.getpwnam',return_value=value),patch('forge_platform.managed_ep_service_preparation.pwd.getpwuid',return_value=value),patch('forge_platform.managed_ep_service_preparation.grp.getgrgid',return_value=SimpleNamespace(gr_name='_fpi_g_'+account[5:])),patch('forge_platform.managed_ep_service_preparation.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=body)):
            prep.bind_account();prep._account()
            with patch('forge_platform.managed_ep_service_preparation.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=body.replace('/usr/bin/false','/bin/sh'))):
                with self.assertRaises(EPServicePreparationError):prep._account()

if __name__ == "__main__": unittest.main()
