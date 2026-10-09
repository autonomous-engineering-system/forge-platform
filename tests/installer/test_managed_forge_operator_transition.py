"""Concrete filesystem rejection gates for reviewed ownership preparation."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from forge_platform.managed_forge_operator_transition import ReviewedForgeOwnershipPreparation
from forge_platform.managed_forge_instance_bootstrap import ForgeInstanceBootstrapError

class OwnershipPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir='/private/tmp')
        self.root=Path(self.temp.name)
        self.data=self.root/'data';self.home=self.root/'home'
        self.data.mkdir(mode=0o700);self.home.mkdir(mode=0o700)
        self.token=self.root/'api.token';self.token.write_bytes(b'unit-test-only')
        self.token.chmod(0o600)
        self.file=self.data/'state';self.file.write_bytes(b'product-state');self.file.chmod(0o600)
        self.executable=self.root/'codex'
        for path in (self.data,self.home,self.token,self.file):
            os.chown(path,-1,os.getegid())
    def tearDown(self):self.temp.cleanup()
    def prepare(self):
        return ReviewedForgeOwnershipPreparation(data_root=self.data,provider_home=self.home,
            api_credential=self.token,provider_executable=self.executable,
            old_uid=os.geteuid(),old_gid=os.getegid(),new_uid=os.geteuid()+1,new_gid=os.getegid())
    def test_metadata_review_does_not_read_credentials_or_mutate_files(self):
        before=self.token.stat()
        with patch('os.read',side_effect=AssertionError('no file contents')),self.prepare() as review:
            self.assertEqual(len(review.nodes),4)
        after=self.token.stat()
        self.assertEqual((before.st_uid,before.st_mode,before.st_mtime_ns),(after.st_uid,after.st_mode,after.st_mtime_ns))
    def test_running_service_blocks_before_any_ownership_change(self):
        with self.prepare() as review,patch('os.fchown',side_effect=AssertionError('must not mutate')):
            with self.assertRaises(ForgeInstanceBootstrapError):
                review.apply_after_service_stop(selected_service_is_stopped=lambda:False)
    def test_directory_and_root_replacement_are_rejected(self):
        with self.prepare() as review:
            (self.data/'new').write_bytes(b'new')
            with self.assertRaises(ForgeInstanceBootstrapError):review.validate()
        (self.data/'new').unlink()
        with self.prepare() as review:
            self.data.rename(self.root/'preserved');self.data.mkdir(mode=0o700)
            with self.assertRaises(ForgeInstanceBootstrapError):review.validate()
    def test_symlinks_in_product_or_credential_routes_and_hardlinks_are_rejected(self):
        self.file.unlink();self.file.symlink_to(self.token)
        with self.assertRaises((OSError,ForgeInstanceBootstrapError)):self.prepare()
        self.file.unlink();os.link(self.token,self.file)
        with self.assertRaises(ForgeInstanceBootstrapError):self.prepare()
    def test_only_exact_provider_wrapper_is_preserved(self):
        wrapper=self.home/'apply_patch';wrapper.symlink_to(self.executable)
        os.chown(wrapper,-1,os.getegid(),follow_symlinks=False)
        with self.prepare() as review:self.assertEqual(len(review.links),1)
        wrapper.unlink();wrapper.symlink_to(self.token)
        with self.assertRaises(ForgeInstanceBootstrapError):self.prepare()
    def test_world_writable_child_rejects_complete_preparation(self):
        self.file.chmod(0o666)
        with self.assertRaises(ForgeInstanceBootstrapError):self.prepare()

if __name__=='__main__':unittest.main()
