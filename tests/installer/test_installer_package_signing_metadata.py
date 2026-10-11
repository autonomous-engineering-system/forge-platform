"""Source-only metadata policy and inert library admission, no signing."""
import json
from hashlib import sha256
import os
import re
import shlex
import sys
import tempfile
from unittest.mock import patch
from scripts import verified_installer_helper_package as trusted
from tests.installer.helper_package_source_fixture import create
from pathlib import Path
import subprocess
import unittest
from scripts import installer_package_signing_metadata as policy
ROOT=Path(__file__).resolve().parents[2]
TEAM="ZEML4LPXH4"
HASH="A"*40
NAME="Developer ID Installer: source-only qualification ("+TEAM+")"
RAW='  1) '+HASH+' "'+NAME+'"\n     1 valid identities found\n'
ID="12345678-1234-1234-1234-123456789abc"

class SigningMetadataTests(unittest.TestCase):
    def test_exact_installer_name_and_fingerprint_selection(self):
        self.assertEqual(policy.select_installer_identity(RAW,NAME,TEAM),HASH)
        self.assertEqual(policy.select_installer_identity(RAW,HASH.lower(),TEAM),HASH)
        self.assertEqual(policy.select_installer_identity('not an identity\n'+RAW,NAME,TEAM),HASH)

    def test_absent_ambiguous_wrong_class_or_team_refused(self):
        for raw in ['',RAW+RAW,RAW.replace('Installer:','Application:'),RAW.replace(TEAM,'OTHERTEAM1'),RAW.replace('source-only','source\tonly')]:
            with self.subTest(raw_length=len(raw)),self.assertRaises(ValueError):policy.select_installer_identity(raw,HASH,TEAM)
        for selection in ['missing',HASH[:-1]]:
            with self.assertRaises(ValueError):policy.select_installer_identity(RAW,selection,TEAM)

    def test_selection_and_public_metadata_are_bounded(self):
        for raw,selection,team in [(None,NAME,TEAM),('x'*65537,NAME,TEAM),(RAW,None,TEAM),(RAW,'',TEAM),(RAW,'x'*513,TEAM),(RAW,'bad\nselector',TEAM),(RAW,NAME,'invalid'),(RAW,NAME,None)]:
            with self.assertRaises(ValueError):policy.select_installer_identity(raw,selection,team)

    def test_only_actual_accepted_canonical_uuid_metadata_can_be_used(self):
        value=dict(status='Accepted',id=ID)
        self.assertEqual(policy.accepted_notary_identifier(json.dumps(value).encode()),ID)
        value['id']=ID.upper()
        self.assertEqual(policy.accepted_notary_identifier(json.dumps(value).encode()),ID)

    def test_notary_uncertainty_malformed_and_ambiguous_metadata_refused(self):
        cases=[None,b'',b' '*65537,b'\xff',b'{',b'[]',b'{"status":"Accepted","status":"Rejected"}',b'{"status":"Accepted","id":NaN}']
        for status,identifier in [('In Progress',ID),('Rejected',ID),('Accepted',None),('Accepted','not an id'),('Accepted',ID.replace('-','')),('Accepted','{'+ID+'}')]:
            cases.append(json.dumps(dict(status=status,id=identifier)).encode())
        for raw in cases:
            with self.subTest(kind=type(raw).__name__),self.assertRaises(ValueError):policy.accepted_notary_identifier(raw)

    def test_shell_library_cannot_run_as_standalone_signer(self):
        result=subprocess.run(['/bin/bash',str(ROOT/'scripts/ci/macos_installer_helper_package_signing.sh')],capture_output=True,text=True,check=False)
        self.assertEqual(result.returncode,64)
        self.assertEqual(result.stdout,'')
        self.assertIn('protected-caller-required',result.stderr)

    def test_library_source_is_inert_without_a_function_call(self):
        result=subprocess.run(['/bin/bash','-c','source "$1"; declare -F select_helper_package_identity sign_helper_package','source-only',str(ROOT/'scripts/ci/macos_installer_helper_package_signing.sh')],capture_output=True,text=True,check=False)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(set(result.stdout.split()),{'select_helper_package_identity','sign_helper_package'})
        self.assertEqual(result.stderr,'')

    def stage(self,selector,values):
        library=(ROOT/'scripts/ci/macos_installer_helper_package_signing.sh').read_text()
        stages=re.findall(r"  python3 - ([^\n]+) <<'PYCODE'\n(.*?)\nPYCODE",library,re.S)
        selected=[(args,body) for args,body in stages if selector in body]
        self.assertEqual(len(selected),1)
        args,body=selected[0]
        # Execute the actual program with argument order derived from its shell
        # call. Inspector substitution is a source-only wire check, never trust.
        argv=['-']+[str(values[token]) for token in shlex.split(args)]
        with patch.object(sys,'argv',argv):exec(compile(body,'source-only helper signing handoff','exec'),{})

    def test_candidate_stage_uses_exact_captured_digest_before_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            package,archive,preparation=create(Path(temporary))
            values=dict({'$unsigned':package,'$archive':archive,'$version':preparation.installer_version,'$source':preparation.source_revision,'$archive_digest':'sha256:'+sha256(archive.read_bytes()).hexdigest()})
            self.stage('try:verify_payload',values)
            values['$archive_digest']='sha256:'+'1'*64
            with self.assertRaises(ValueError):self.stage('try:verify_payload',values)

    def test_final_actual_handoff_cannot_confuse_team_and_archive_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);package,archive,preparation=create(root)
            digest='sha256:'+sha256(archive.read_bytes()).hexdigest()
            receipt=root/'source-only-evidence.json'
            values={'$package':package,'$archive':archive,'$version':preparation.installer_version,'$source':preparation.source_revision,'$team':TEAM,'$notary':ID,'$receipt':receipt,'$archive_digest':digest}
            result={'asset_name':trusted.ASSET_NAME,'digest':'sha256:'+'2'*64,'bytes':package.stat().st_size,'notarization_receipt_reference':'receipt:apple-notary-'+ID}
            with patch.object(trusted,'read_descriptor',return_value=result) as inspect:self.stage('value=read_descriptor',values)
            kwargs=inspect.call_args.kwargs
            self.assertEqual(kwargs['archive_digest'],digest)
            self.assertEqual(kwargs['team'],TEAM)
            self.assertEqual(kwargs['archive'],archive)
            self.assertEqual(kwargs['preparation'].source_revision,preparation.source_revision)
            self.assertEqual(json.loads(receipt.read_bytes()),result)
            self.assertEqual(receipt.stat().st_mode&0o777,0o600)
            receipt.unlink()
            with patch.object(trusted,'read_descriptor',side_effect=ValueError('source-only actual rejection')):
                with self.assertRaises(ValueError):self.stage('value=read_descriptor',values)
            self.assertFalse(receipt.exists())

if __name__=='__main__':unittest.main()
