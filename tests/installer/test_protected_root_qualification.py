"""Source models for GitHub provenance; actual bounded JSON/ZIP/process IO.

No live API, token, root account or installer effect. API facts are explicit
fixtures and never grant installed/runtime authority.
"""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from scripts import protected_root_qualification as subject
from scripts import emit_protected_root_qualification as exporter
from scripts import check_managed_installer_python_coverage as gate

SHA='a'*40; TREE='b'*40
ENV=dict(GITHUB_ACTIONS='true',GITHUB_WORKFLOW='Forge Platform installer release framework',
    GITHUB_REPOSITORY=subject.REPOSITORY,GITHUB_REF='refs/heads/main',GITHUB_REF_PROTECTED='true',
    GITHUB_EVENT_NAME='workflow_dispatch',GITHUB_SHA=SHA,GITHUB_WORKFLOW_SHA=SHA,
    GITHUB_SERVER_URL='https://github.com',GITHUB_API_URL='https://api.github.com',
    GITHUB_RUN_ID='200',GITHUB_RUN_ATTEMPT='1',GH_TOKEN='source-model-not-a-credential')


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()


def archive(receipt,name='root-qualification.json',extra=False):
    stream=io.BytesIO()
    with zipfile.ZipFile(stream,'w') as z:
        z.writestr(name,canonical(receipt))
        if extra:z.writestr('other',b'other')
    return stream.getvalue()


def fixture():
    counts={'schema':'forge-platform.source-root-coverage/v1','files':{'source.py':{'source_sha256':'c'*64,'lines':[1]}}}
    receipt=dict(schema=subject.SCHEMA,repository=subject.REPOSITORY,source_sha=SHA,source_tree=TREE,
        workflow=subject.FOUNDATION,workflow_sha=SHA,run_id=100,run_attempt=2,qualification='PASS_ROOT_NO_SKIPS',counts=counts)
    raw=archive(receipt)
    run=dict(id=100,run_attempt=2,head_sha=SHA,head_branch='main',event='push',status='completed',
        conclusion='success',workflow_id=5,path=subject.FOUNDATION)
    own=dict(run,id=200,run_attempt=1,event='workflow_dispatch',status='in_progress',conclusion=None,
        path=subject.BUILD_WORKFLOWS[ENV['GITHUB_WORKFLOW']])
    name=f'source-root-qualification-{SHA}-100-2'
    api={
        'branches/main':dict(protected=True,commit={'sha':SHA}),
        'rules/branches/main':[dict(type='required_status_checks',parameters={'required_status_checks':[{'context':'Foundation validation'}]})],
        'actions/runs/200/attempts/1':own,
        'actions/workflows/foundation-validation.yml':dict(id=5,path=subject.FOUNDATION,state='active'),
        f'actions/workflows/foundation-validation.yml/runs?event=push&branch=main&head_sha={SHA}&status=completed&per_page=20':dict(total_count=1,workflow_runs=[run]),
        'actions/runs/100/attempts/2':copy.deepcopy(run),
        'actions/runs/100/attempts/2/jobs?per_page=100':dict(total_count=3,jobs=[dict(name=n,status='completed',conclusion='success') for n in subject.JOBS]),
        f'actions/runs/100/artifacts?name={name}&per_page=100':dict(total_count=1,artifacts=[dict(id=50,name=name,
            expired=False,size_in_bytes=len(raw),digest='sha256:'+hashlib.sha256(raw).hexdigest(),
            workflow_run=dict(id=100,head_sha=SHA,head_branch='main'))])}
    return receipt,raw,api


class ProtectedRootReadbackTests(unittest.TestCase):
    def invoke(self,api,raw,env=None):
        def git(root,*args):
            return SHA if args==('rev-parse','HEAD') else TREE if args==('rev-parse','HEAD^{tree}') else ''
        def download(endpoint):
            self.assertEqual(endpoint,f'repos/{subject.REPOSITORY}/actions/artifacts/50/zip');return raw
        with patch.object(subject,'git',side_effect=git):
            return subject.read_counts(Path('/source-model'),env or ENV,lambda path:copy.deepcopy(api[path]),download)

    def testCatalogConsumesOnlySameProtectedSourceAndOwnWorkflow(self):
        receipt,raw,api=fixture()
        env=dict(ENV,GITHUB_WORKFLOW='Forge Platform composition catalog release framework')
        own='actions/runs/200/attempts/1'
        api[own]['path']='.github/workflows/forge-platform-composition-catalog-release.yml'
        self.assertEqual(self.invoke(api,raw,env),receipt['counts'])
        api[own]['path']='.github/workflows/forge-platform-installer-release.yml'
        with self.assertRaises(ValueError):self.invoke(api,raw,env)
        api[own]['path']='.github/workflows/forge-platform-composition-catalog-release.yml'
        with self.assertRaises(ValueError):self.invoke(api,raw,dict(env,GITHUB_EVENT_NAME='pull_request'))

    def testExactQualifiedRunAndArtifactProvideCountsOnly(self):
        receipt,raw,api=fixture();self.assertEqual(self.invoke(api,raw),receipt['counts'])

    def testClosedProtectedBuildContextBeforeAnyArtifact(self):
        receipt,raw,api=fixture()
        for key,value in dict(GITHUB_REPOSITORY='other/repo',GITHUB_REF='refs/heads/other',GITHUB_REF_PROTECTED='false',
            GITHUB_WORKFLOW='other',GITHUB_EVENT_NAME='pull_request',GITHUB_ACTIONS='false',GITHUB_SHA='not-sha',
            GITHUB_SERVER_URL='https://untrusted.invalid',GITHUB_API_URL='https://untrusted.invalid/api',GITHUB_WORKFLOW_SHA='d'*40,GITHUB_RUN_ID='0',GITHUB_RUN_ATTEMPT='-1',GH_TOKEN='').items():
            with self.subTest(key=key),self.assertRaises(ValueError):self.invoke(api,raw,dict(ENV,**{key:value}))
        self.assertFalse(subject.protected_build({}))
        with patch.object(subject,'git',return_value='changed'):
            with self.assertRaises(ValueError):subject.context(Path('/model'),ENV)

    def testIndependentMainRulesOwnRunAndWorkflowCannotDrift(self):
        _,raw,api=fixture()
        changes=[('branches/main','protected',False),('actions/runs/200/attempts/1','id',99),
            ('actions/runs/200/attempts/1','run_attempt',2),('actions/runs/200/attempts/1','run_attempt',True),('actions/runs/200/attempts/1','head_sha','d'*40),
            ('actions/runs/200/attempts/1','head_branch','other'),('actions/runs/200/attempts/1','event','push'),
            ('actions/runs/200/attempts/1','path','other.yml'),('actions/runs/200/attempts/1','status','completed'),
            ('actions/runs/200/attempts/1','conclusion','success'),('actions/workflows/foundation-validation.yml','state','disabled'),
            ('actions/workflows/foundation-validation.yml','path','other.yml'),('actions/workflows/foundation-validation.yml','id',True)]
        for endpoint,key,value in changes:
            modified=copy.deepcopy(api);modified[endpoint][key]=value
            with self.subTest(key=key,endpoint=endpoint),self.assertRaises(ValueError):self.invoke(modified,raw)
        modified=copy.deepcopy(api);modified['rules/branches/main']=[]
        with self.assertRaises(ValueError):self.invoke(modified,raw)
        modified=copy.deepcopy(api);modified['branches/main']['commit']['sha']='d'*40
        with self.assertRaises(ValueError):self.invoke(modified,raw)

    def testExactFoundationRunAttemptAndAllRequiredJobs(self):
        _,raw,api=fixture();listing=next(k for k in api if '/runs?' in k)
        for key,value in dict(id=True,run_attempt=0,head_sha='d'*40,head_branch='other',event='pull_request',
            status='in_progress',conclusion='failure',workflow_id=6,path='other.yml').items():
            modified=copy.deepcopy(api);modified[listing]['workflow_runs'][0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.invoke(modified,raw)
        for mutate in (lambda v:v.update(total_count=21),lambda v:v['workflow_runs'].append(copy.deepcopy(v['workflow_runs'][0]))):
            modified=copy.deepcopy(api);mutate(modified[listing])
            with self.assertRaises(ValueError):self.invoke(modified,raw)
        for key in api['actions/runs/100/attempts/2']:
            modified=copy.deepcopy(api);modified['actions/runs/100/attempts/2'][key]='changed'
            with self.subTest(key=key),self.assertRaises(ValueError):self.invoke(modified,raw)
        jobpath='actions/runs/100/attempts/2/jobs?per_page=100'
        for mutate in (lambda v:v.update(total_count=101),lambda v:v['jobs'].pop(),
            lambda v:v['jobs'][0].update(status='in_progress'),lambda v:v['jobs'][0].update(conclusion='failure'),
            lambda v:v['jobs'][0].update(name='unknown')):
            modified=copy.deepcopy(api);mutate(modified[jobpath])
            with self.assertRaises(ValueError):self.invoke(modified,raw)

    def testArtifactIdentityDigestAndBoundedClosedZip(self):
        receipt,raw,api=fixture();artifactpath=next(k for k in api if '/artifacts?' in k)
        for key,value in dict(id=True,name='other',expired=True,size_in_bytes=0,digest='bad').items():
            modified=copy.deepcopy(api);modified[artifactpath]['artifacts'][0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.invoke(modified,raw)
        for key,value in dict(id=99,head_sha='d'*40,head_branch='other').items():
            modified=copy.deepcopy(api);modified[artifactpath]['artifacts'][0]['workflow_run'][key]=value
            with self.assertRaises(ValueError):self.invoke(modified,raw)
        modified=copy.deepcopy(api);modified[artifactpath]['artifacts'].append(copy.deepcopy(modified[artifactpath]['artifacts'][0]))
        with self.assertRaises(ValueError):self.invoke(modified,raw)
        with self.assertRaises(ValueError):self.invoke(api,raw+b'drift')
        for altered in (archive(receipt,name='../root-qualification.json'),archive(receipt,extra=True)):
            modified=copy.deepcopy(api);modified[artifactpath]['artifacts'][0]['digest']='sha256:'+hashlib.sha256(altered).hexdigest()
            with self.assertRaises(ValueError):self.invoke(modified,altered)
        for key in receipt:
            value=copy.deepcopy(receipt)
            if key=='counts':del value[key]
            else:value[key]='changed'
            altered=archive(value);modified=copy.deepcopy(api);modified[artifactpath]['artifacts'][0]['digest']='sha256:'+hashlib.sha256(altered).hexdigest()
            with self.subTest(key=key),self.assertRaises(ValueError):self.invoke(modified,altered)

    def testDuplicateNonfiniteAndOversizedJsonDeny(self):
        for raw in (b'',b'{"key":1,"key":2}',b'{"key":NaN}',b'x'*(subject.MAXIMUM+1)):
            with self.assertRaises(ValueError):subject.decode(raw)
        self.assertFalse(subject.workflow_path(None,subject.FOUNDATION))
        self.assertTrue(subject.workflow_path(subject.FOUNDATION+'@refs/heads/main',subject.FOUNDATION))

    def testBoundedRealChildReaderNeverUsesTokenInArguments(self):
        real=subprocess.Popen
        def child(args,**kwargs):
            self.assertEqual(args[:4],['gh','api','--hostname','github.com']);self.assertNotIn(ENV['GH_TOKEN'],' '.join(args))
            return real([sys.executable,'-c','import sys;sys.stdout.buffer.write(b"source-only")'],**kwargs)
        with patch.object(subject.subprocess,'Popen',side_effect=child):
            self.assertEqual(subject.gh_bytes(f'repos/{subject.REPOSITORY}/branches/main'),b'source-only')
        with self.assertRaises(ValueError):subject.gh_bytes('repos/other/repo/branches/main')
        def too_big(args,**kwargs):return real([sys.executable,'-c','import sys;sys.stdout.buffer.write(b"x"*100)'],**kwargs)
        with patch.object(subject.subprocess,'Popen',side_effect=too_big),patch.object(subject,'MAXIMUM',8):
            with self.assertRaises(ValueError):subject.gh_bytes(f'repos/{subject.REPOSITORY}/branches/main')
        with patch.object(subject,'gh_bytes',return_value=b'{"readback":true}'):
            self.assertEqual(subject.api('branches/main'),{'readback':True})


class RootCountsAssemblyTests(unittest.TestCase):
    def testRealSourceHashLineBoundsAndNoGenericReceiptSelector(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'source.py').write_text('value = 1\n')
            with patch.object(gate,'ROOT',root),patch.object(gate,'TARGETS',('source.py',)):
                before=gate._source_hashes();payload=dict(schema='forge-platform.source-root-coverage/v1',files={'source.py':dict(source_sha256=before['source.py'],lines=[1])})
                output={};gate._merge_root_counts(output,before,payload);self.assertEqual(output[(root/'source.py').resolve()],{1})
                for value in ({},dict(payload,schema='other'),dict(payload,unknown=True),dict(payload,files={}),
                    dict(payload,files={'other.py':payload['files']['source.py']})):
                    with self.assertRaises((ValueError,KeyError)):gate._merge_root_counts({},before,value)
                for lines in ([True],[0],[10000],[1,1]):
                    bad=copy.deepcopy(payload);bad['files']['source.py']['lines']=lines
                    with self.assertRaises(ValueError):gate._merge_root_counts({},before,bad)
                bad=copy.deepcopy(payload);bad['files']['source.py']['source_sha256']='changed'
                with self.assertRaises(ValueError):gate._merge_root_counts({},before,bad)
                # Protected assembly is internal; source models verify route selection without IO.
                with patch.dict(os.environ,ENV,clear=True),patch('scripts.protected_root_qualification.read_counts',return_value=payload) as receipt,patch.object(gate.subprocess,'run') as sudo:
                    gate._merge_root_qualification({},before);receipt.assert_called_once();sudo.assert_not_called()
                (root/'source.py').write_text('value = 2\n')
                with self.assertRaises(ValueError):gate._merge_root_counts({},before,payload)

    def testHostedExporterRunsActualRootGateCommandAndCorrelatesSource(self):
        env=dict(ENV,GITHUB_WORKFLOW='Foundation validation',GITHUB_EVENT_NAME='push',GITHUB_RUN_ID='100',GITHUB_RUN_ATTEMPT='2')
        counts={'schema':'forge-platform.source-root-coverage/v1','files':{'source.py':dict(source_sha256='c'*64,lines=[1])}}
        def git(root,*args):return SHA if args==('rev-parse','HEAD') else TREE if args==('rev-parse','HEAD^{tree}') else ''
        with patch.object(exporter,'git',side_effect=git),patch.object(gate,'_source_hashes',return_value={'source.py':'c'*64}),patch.object(gate,'_require_source_snapshot'),patch.object(gate,'_merge_root_counts') as merge,patch.object(exporter.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=canonical(counts))) as run:
            value=exporter.qualify(Path('/source-model'),env)
            self.assertEqual(value['counts'],counts);self.assertEqual(value['run_attempt'],2)
            self.assertEqual(run.call_args.args[0][:2],['sudo','-n']);merge.assert_called_once()
            with self.assertRaises(ValueError):exporter.qualify(Path('/source-model'),dict(env,GITHUB_REF_PROTECTED='false'))
            with self.assertRaises(ValueError):exporter.qualify(Path('/source-model'),dict(env,GITHUB_SHA='d'*40))

    def testExporterExclusiveBoundedPublicationAndForeignParentDenial(self):
        with tempfile.TemporaryDirectory(prefix='root-handoff-output-') as temp:
            root=Path(temp).resolve();output=root/'root-qualification.json'
            value={'schema':subject.SCHEMA,'qualification':'source-model-only'}
            with patch.dict(os.environ,RUNNER_TEMP=str(root)),patch.object(sys,'argv',['emitter','--output',str(output)]),patch.object(exporter,'qualify',return_value=value):
                exporter.main();raw=output.read_bytes()
                self.assertEqual(json.loads(raw),value);self.assertEqual(output.stat().st_mode & 0o777,0o600)
                with self.assertRaises(FileExistsError):exporter.main()
                self.assertEqual(output.read_bytes(),raw)
                with patch.object(sys,'argv',['emitter','--output',str(root.parent/'foreign-output.json')]):
                    with self.assertRaises(ValueError):exporter.main()



if __name__=='__main__':unittest.main()
