from hashlib import sha256
import os
from pathlib import Path
import tempfile
import unittest

from forge_platform.component_operations import QualifiedArtifact
from forge_platform.managed_product_wheel_cli_staging import stage_product_cli_wheel


class NamedProductWheelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.data = b'exact cached wheel bytes'
        self.digest = 'sha256:' + sha256(self.data).hexdigest()
        self.name = 'engineering_platform-2.3.106-py3-none-any.whl'
        self.artifact = QualifiedArtifact('2.3.106', 'a' * 40,
            'https://release.example.invalid/' + self.name, self.digest,
            'https://evidence.example.invalid/release')
        self.path = self.root / (self.digest[7:] + '.artifact')
        self.path.write_bytes(self.data)
        self.path.chmod(0o600)

    def tearDown(self):
        self.temp.cleanup()

    def test_exact_named_publication_and_replay_preserve_original(self):
        named = stage_product_cli_wheel(self.path, self.artifact)
        self.assertEqual(named.name, self.name)
        self.assertEqual(named.read_bytes(), self.data)
        self.assertEqual(stage_product_cli_wheel(self.path, self.artifact), named)
        self.assertEqual(self.path.read_bytes(), self.data)
        self.assertEqual(named.stat().st_nlink, 1)
        self.assertEqual(named.stat().st_mode & 0o777, 0o600)

    def test_changed_source_bytes_fail_before_publication(self):
        self.path.write_bytes(b'changed')
        with self.assertRaises(ValueError):
            stage_product_cli_wheel(self.path, self.artifact)
        self.assertEqual(list(self.root.iterdir()), [self.path])

    def test_symlinked_source_and_namespace_are_rejected(self):
        saved = self.root / 'saved'
        self.path.rename(saved)
        self.path.symlink_to(saved)
        with self.assertRaises((OSError, ValueError)):
            stage_product_cli_wheel(self.path, self.artifact)
        self.path.unlink()
        saved.rename(self.path)
        foreign = self.root / 'foreign'
        foreign.mkdir(mode=0o700)
        (self.root / (self.digest[7:] + '.wheel')).symlink_to(foreign)
        with self.assertRaises((OSError, ValueError)):
            stage_product_cli_wheel(self.path, self.artifact)
        self.assertEqual(list(foreign.iterdir()), [])

    def test_foreign_named_file_is_preserved_and_blocks(self):
        named = stage_product_cli_wheel(self.path, self.artifact)
        named.write_bytes(b'foreign')
        with self.assertRaises(ValueError):
            stage_product_cli_wheel(self.path, self.artifact)
        self.assertEqual(named.read_bytes(), b'foreign')

    def test_unsafe_source_name_and_public_staging_root_are_rejected(self):
        bad = QualifiedArtifact('2.3.106', 'a' * 40,
            'https://release.example.invalid/%2fescape.whl', self.digest,
            'https://evidence.example.invalid/release')
        with self.assertRaises(ValueError):
            stage_product_cli_wheel(self.path, bad)
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            stage_product_cli_wheel(self.path, self.artifact)


if __name__ == '__main__':
    unittest.main()
