"""Source-only native evidence tests using real temporary files/ZIP/JSON.
GitHub facts are explicit models; no runtime PASS or account grant.
"""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from scripts import protected_swift_qualification as subject
from scripts import protected_root_qualification as provenance
from scripts import check_managed_installer_swift_coverage as gate
from tests.installer.test_protected_root_qualification import fixture, archive, ENV, SHA, TREE

TARGET='/Sources/Test.swift'
PAYLOAD={'data':[{'files':[{'filename':'/checkout'+TARGET,'summary':{'lines':{'count':1,'covered':1,'percent':100}}}]}]}


class NativeQualificationTests(unittest.TestCase):
    def source(self, root):
        file=root/'macos/ForgePlatformInstaller'/TARGET.lstrip('/');file.parent.mkdir(parents=True);file.write_text('let actual = 1\n')
        return file

    def testActualFileHashCountsAndClosedAdmission(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();file=self.source(root)
            counts=subject.compact(PAYLOAD,root,(TARGET,),80.2)
            self.assertEqual(subject.admitted_payload(counts,root,(TARGET,))['data'][0]['files'][0]['filename'],TARGET)
            self.assertEqual(counts['files'][TARGET]['source_sha256'],hashlib.sha256(file.read_bytes()).hexdigest())
            bads=[{},dict(counts,schema='wrong'),dict(counts,extra=True),dict(counts,files={})]
            for bad in bads:
                with self.assertRaises(ValueError):subject.admitted_payload(bad,root,(TARGET,))
            for change in ({'source_sha256':'bad'}, {'lines':{'count':True,'covered':1,'percent':100}},
                           {'lines':{'count':2**63,'covered':2**63,'percent':100}}, {'lines':{'count':1}}, {'extra':True}):
                bad=copy.deepcopy(counts);bad['files'][TARGET].update(change)
                with self.assertRaises(ValueError):subject.admitted_payload(bad,root,(TARGET,))
            file.write_text('let changed = 2\n')
            with self.assertRaises(ValueError):subject.admitted_payload(counts,root,(TARGET,))
            low=copy.deepcopy(PAYLOAD);low['data'][0]['files'][0]['summary']['lines'].update(covered=0,percent=0)
            with self.assertRaises(ValueError):subject.compact(low,root,(TARGET,),80.2)

    def testMeasuredMultiplicityUsesUnchangedStrictCountValidation(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();self.source(root)
            counts=subject.compact(PAYLOAD,root,(TARGET,),80.2)
            # Exported LLVM summaries can count more measured lines than source
            # text rows. Do not replace that denominator with text-line counts.
            counts['files'][TARGET]['lines']={'count':4226,'covered':3467,'percent':100*3467/4226}
            admitted=subject.admitted_payload(counts,root,(TARGET,))
            self.assertEqual(admitted['data'][0]['files'][0]['summary']['lines']['count'],4226)
            for lines in ({'count':0,'covered':0,'percent':0},
                          {'count':True,'covered':1,'percent':100},
                          {'count':2**63,'covered':2**63,'percent':100},
                          {'count':1,'covered':2,'percent':100},
                          {'count':1000,'covered':802,'percent':80.2},
                          {'count':4226,'covered':3467,'percent':100}):
                bad=copy.deepcopy(counts);bad['files'][TARGET]['lines']=lines
                with self.subTest(lines=lines),self.assertRaises(ValueError):subject.admitted_payload(bad,root,(TARGET,))

    def testLiveConsumerRequiresContextAndPreservesSourceSnapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();file=self.source(root);counts=subject.compact(PAYLOAD,root,(TARGET,),80.2)
            low=copy.deepcopy(PAYLOAD);low['data'][0]['files'][0]['summary']['lines'].update(covered=0,percent=0)
            with patch.object(provenance,'read_counts',return_value=counts) as read:
                result=subject.protected_payload(root,ENV,low,(TARGET,),80.2)
                read.assert_called_once_with(root,ENV,kind='swift')
                self.assertEqual(gate.validate(result,(TARGET,),80.2),0)
                with self.assertRaises(ValueError):subject.protected_payload(root,ENV,{},(TARGET,),80.2)
            def drift(*args,**kwargs):file.write_text('changed\n');return counts
            with patch.object(provenance,'read_counts',side_effect=drift):
                with self.assertRaises(ValueError):subject.protected_payload(root,ENV,PAYLOAD,(TARGET,),80.2)

    def testOwningRunSwiftArtifactSchemaDigestAndNamespace(self):
        receipt,_,api=fixture();receipt.update(schema='forge-platform.protected-swift-qualification/v1',qualification='PASS_EVERY_SWIFT_FILE')
        old=next(k for k in api if '/artifacts?' in k);new=old.replace('source-root-', 'source-swift-')
        value=api.pop(old);value['artifacts'][0]['name']=value['artifacts'][0]['name'].replace('source-root-', 'source-swift-');api[new]=value
        raw=archive(receipt,name='swift-qualification.json');value['artifacts'][0].update(size_in_bytes=len(raw),digest='sha256:'+hashlib.sha256(raw).hexdigest())
        def git(root,*args):return SHA if args==('rev-parse','HEAD') else TREE if args==('rev-parse','HEAD^{tree}') else ''
        with patch.object(provenance,'git',side_effect=git):
            self.assertEqual(provenance.read_counts(Path('/model'),ENV,lambda p:copy.deepcopy(api[p]),lambda p:raw,kind='swift'),receipt['counts'])
            for field in ('schema','qualification','source_sha','run_attempt'):
                bad=copy.deepcopy(receipt);bad[field]='foreign';changed=archive(bad,name='swift-qualification.json')
                modified=copy.deepcopy(api);modified[new]['artifacts'][0]['digest']='sha256:'+hashlib.sha256(changed).hexdigest()
                with self.assertRaises(ValueError):provenance.read_counts(Path('/model'),ENV,lambda p:modified[p],lambda p:changed,kind='swift')
        with self.assertRaises(ValueError):provenance.read_hosted_counts(SHA,TREE,kind='unknown')

    def testMeasuredFileReadIsActuallyBoundedAndRejectsNonregularOrUnstableLeaf(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();file=root/'measured.json';file.write_text(json.dumps(PAYLOAD))
            self.assertEqual(subject.measured_payload(file),PAYLOAD)
            with self.assertRaises(ValueError):subject.measured_payload(file,maximum=8)
            for raw in ('{"key":1,"key":2}', '{"key":NaN}', ''):
                file.write_text(raw)
                with self.assertRaises(ValueError):subject.measured_payload(file)
            file.unlink();os.mkfifo(file)
            with self.assertRaises(ValueError):subject.measured_payload(file)
            file.unlink();other=root/'other';other.write_text(json.dumps(PAYLOAD));file.symlink_to(other)
            with self.assertRaises(OSError):subject.measured_payload(file)
            file.unlink();file.write_text(json.dumps(PAYLOAD))
            actual=subject.os.read
            def grow(fd,size):
                with file.open('a') as stream:stream.write(' ')
                return actual(fd,size)
            with patch.object(subject.os,'read',side_effect=grow):
                with self.assertRaises(ValueError):subject.measured_payload(file,maximum=256)
            file.write_text(json.dumps(PAYLOAD))
            def replace(fd,size):
                file.unlink();file.write_text(json.dumps(PAYLOAD))
                return actual(fd,size)
            with patch.object(subject.os,'read',side_effect=replace):
                with self.assertRaises(ValueError):subject.measured_payload(file)

    def testHostedExporterRequiresExactSourceAndMeasuredCoverage(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();self.source(root);evidence=root/'forge-platform-native-evidence';evidence.mkdir()
            measured=evidence/'swift-coverage.json';measured.write_text(json.dumps(PAYLOAD))
            env=dict(ENV,GITHUB_WORKFLOW='Foundation validation',GITHUB_EVENT_NAME='push',GITHUB_RUN_ID='100',GITHUB_RUN_ATTEMPT='2',RUNNER_TEMP=str(root),COVERAGE_BASE_SHA='c'*40)
            def git(root,*args):return SHA if args==('rev-parse','HEAD') else TREE if args==('rev-parse','HEAD^{tree}') else ''
            with patch.object(provenance,'git',side_effect=git),patch.object(gate,'required_targets',return_value=(TARGET,)):
                receipt=subject.qualify(root,env);self.assertEqual(receipt['source_tree'],TREE)
                subject.export(root,env);output=root/'swift-qualification.json';self.assertEqual(output.stat().st_mode & 0o777,0o600)
                self.assertEqual(json.loads(output.read_bytes()),receipt)
                with self.assertRaises(FileExistsError):subject.export(root,env)
                output.unlink();output.symlink_to(measured)
                with self.assertRaises(OSError):subject.export(root,env)
                for key,value in dict(GITHUB_WORKFLOW='other',GITHUB_EVENT_NAME='pull_request',GITHUB_REF_PROTECTED='false',GITHUB_SHA='d'*40,GITHUB_RUN_ATTEMPT='0').items():
                    with self.subTest(key=key),self.assertRaises(ValueError):subject.qualify(root,dict(env,**{key:value}))
                measured.unlink();measured.symlink_to(output)
                with self.assertRaises(OSError):subject.qualify(root,env)
            with patch.object(provenance,'git',return_value='dirty'):
                with self.assertRaises(ValueError):subject.qualify(root,env)


if __name__=='__main__':unittest.main()
