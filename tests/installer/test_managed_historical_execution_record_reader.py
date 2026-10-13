"""Isolated private reader IO; no native admission or installed qualification."""
from pathlib import Path
import os,stat,tempfile,unittest
from forge_platform.managed_historical_execution_record_reader import _PrivateHistoricalRecordReadback
from forge_platform.managed_historical_execution_evidence import HistoricalExecutionEvidenceError


class HistoricalPrivateRecordReadbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='l1-execution-reader-',dir='/private/tmp')
        self.root=Path(self.tmp.name);self.root.chmod(0o700)
        self.file=self.root/'record.json';self.file.write_bytes(b'opaque source-only bytes');self.file.chmod(0o600)
        self.addCleanup(self.tmp.cleanup)

    def testPrivateBoundedReadPreservesBytesAndRejectsUnsafeMetadata(self):
        frozen=self.file.read_bytes()
        with _PrivateHistoricalRecordReadback(self.root,owner=os.geteuid()) as read:
            self.assertEqual(read.read('record.json',1024),frozen)
            with self.assertRaises(HistoricalExecutionEvidenceError):read.read('record.json',1)
        self.file.chmod(0o644)
        with _PrivateHistoricalRecordReadback(self.root,owner=os.geteuid()) as read:
            with self.assertRaises(HistoricalExecutionEvidenceError):read.read('record.json',1024)
        self.assertEqual(self.file.read_bytes(),frozen)

    def testHardlinkAndSymlinkCannotSupplyARecord(self):
        os.link(self.file,self.root/'linked.json')
        with _PrivateHistoricalRecordReadback(self.root,owner=os.geteuid()) as read:
            with self.assertRaises(HistoricalExecutionEvidenceError):read.read('record.json',1024)
        (self.root/'linked.json').unlink();self.file.unlink();self.file.symlink_to('/etc/hosts')
        with _PrivateHistoricalRecordReadback(self.root,owner=os.geteuid()) as read:
            with self.assertRaises(OSError):read.read('record.json',1024)

    def testNamedDirectorySwapRejectsTheDetachedOldRecord(self):
        old=self.root/'record.json'
        moved=self.root.with_name(self.root.name+'-moved')
        with _PrivateHistoricalRecordReadback(self.root,owner=os.geteuid()) as read:
            self.root.rename(moved)
            try:
                self.root.mkdir(mode=0o700)
                (self.root/'record.json').write_bytes(b'other generation');(self.root/'record.json').chmod(0o600)
                with self.assertRaises(HistoricalExecutionEvidenceError):read.read('record.json',1024)
            finally:
                (self.root/'record.json').unlink();self.root.rmdir();moved.rename(self.root)
        self.assertEqual(old.read_bytes(),b'opaque source-only bytes')


if __name__=='__main__':unittest.main()
