from hashlib import sha256
import json
import unittest
from forge_platform.managed_installer_user_identity import canonical_identity, InstallerUserIdentityError

class InstallerUserIdentityTests(unittest.TestCase):
    def test_names_and_user_numbers_are_not_hardcoded(self):
        for name, uid in (('alice',501),('bob.mac',1203)):
            raw=canonical_identity(name,uid,20,'12345678-1234-1234-1234-123456789ABC')
            self.assertEqual(json.loads(raw)['account_name'],name)
            self.assertEqual(json.loads(raw)['uid'],uid)
            self.assertEqual(json.loads(raw)['generated_uid'],'12345678-1234-1234-1234-123456789abc')
            self.assertEqual(len(sha256(raw).hexdigest()),64)
    def test_root_system_accounts_paths_and_invalid_identity_are_rejected(self):
        for args in (('root',0,0,'bad'),('_fpi_service',200000,200000,'bad'),
                     ('../alice',501,20,'bad'),('alice',501,20,'not-a-uuid')):
            with self.assertRaises(InstallerUserIdentityError):canonical_identity(*args)
