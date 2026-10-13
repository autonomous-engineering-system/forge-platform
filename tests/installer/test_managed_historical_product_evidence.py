"""Source-only readback gates. Temporary files; no installer/product effects."""
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

from forge_platform.managed_historical_product_evidence import (
    HistoricalProductEvidenceError, _bounded_members, _runtime_acl, _StableReadback,
    decode_inspection_intent, _archive_readback, _public_archive_url,
    _fetch_public_archive, _bounded_archive_bytes,
)
from forge_platform.installer_helper_companion import no_extended_acl


class HistoricalArchiveBoundsTests(unittest.TestCase):
    def test_stops_before_processing_oversized_member(self):
        consumed=[]
        def archive():
            consumed.append(1);yield SimpleNamespace(size=2*1024*1024*1024+1)
            consumed.append(2);raise AssertionError("over-limit archive must stop")
        with self.assertRaises(HistoricalProductEvidenceError):_bounded_members(archive())
        self.assertEqual(consumed,[1])

    def test_limits_entry_count_during_iteration(self):
        consumed=[]
        def archive():
            for i in range(131074):
                consumed.append(i);yield SimpleNamespace(size=1)
        with self.assertRaises(HistoricalProductEvidenceError):_bounded_members(archive())
        self.assertEqual(len(consumed),131073)

    def test_empty_and_negative_size_rejected(self):
        for entries in ([],[SimpleNamespace(size=-1)]):
            with self.assertRaises(HistoricalProductEvidenceError):_bounded_members(entries)

    def test_bounded_entries_accepted(self):
        entries=[SimpleNamespace(size=0),SimpleNamespace(size=12)]
        self.assertEqual(_bounded_members(iter(entries)),(entries,12))


class HistoricalArchiveAcquisitionTests(unittest.TestCase):
    def test_missing_cache_uses_exact_public_bytes_without_creating_cache(self):
        from hashlib import sha256
        from forge_platform.universal_installer import DownloadIdentity
        raw=b"exact public bytes"
        identity=DownloadIdentity("https://github.com/openai/codex/releases/download/example/archive.tar.gz",
                                  "sha256:"+sha256(raw).hexdigest())
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temp:
            path=Path(temp)/"absent-cache"
            with _StableReadback() as stable:
                self.assertEqual(_archive_readback(stable,path,identity,lambda value:raw),raw)
                stable.verify()
            self.assertFalse(path.exists())

    def test_wrong_public_digest_cannot_replace_missing_original_proof(self):
        from forge_platform.universal_installer import DownloadIdentity
        identity=DownloadIdentity("https://github.com/cli/cli/releases/download/example/archive.tar.gz","sha256:"+"a"*64)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temp:
            with _StableReadback() as stable:
                with self.assertRaises(HistoricalProductEvidenceError):
                    _archive_readback(stable,Path(temp)/"absent",identity,lambda value:b"wrong")

    def test_public_fetch_disables_ambient_proxy_selection(self):
        from hashlib import sha256
        import io
        from unittest.mock import patch
        from urllib.request import ProxyHandler
        from forge_platform.universal_installer import DownloadIdentity
        raw=b"public archive"
        identity=DownloadIdentity("https://github.com/openai/codex/releases/download/example/archive.tar.gz",
                                  "sha256:"+sha256(raw).hexdigest())
        class Response(io.BytesIO):
            def geturl(self):return identity.url
        class Opener:
            def open(self,url,timeout):return Response(raw)
        observed=[]
        def factory(*handlers):
            observed.extend(handlers);return Opener()
        with patch("forge_platform.managed_historical_product_evidence.build_opener",side_effect=factory):
            self.assertEqual(_fetch_public_archive(identity),raw)
        proxy=next(value for value in observed if isinstance(value,ProxyHandler))
        self.assertEqual(proxy.proxies,{})

    def test_download_size_is_bounded_during_reads(self):
        import io
        from unittest.mock import patch
        with patch("forge_platform.managed_historical_product_evidence._MAXIMUM_ARCHIVE_BYTES",8):
            self.assertEqual(_bounded_archive_bytes(io.BytesIO(b"12345678")),b"12345678")
            with self.assertRaises(HistoricalProductEvidenceError):_bounded_archive_bytes(io.BytesIO(b"123456789"))

    def test_public_fetch_rejects_private_hosts_and_plaintext_redirects(self):
        for url in ["http://github.com/archive", "https://127.0.0.1/archive", "https://example.com/archive",
                    "https://user:password@github.com/archive"]:
            with self.assertRaises((HistoricalProductEvidenceError,ValueError)):_public_archive_url(url)
        self.assertEqual(_public_archive_url("https://release-assets.githubusercontent.com/archive"),
                         "https://release-assets.githubusercontent.com/archive")


class HistoricalInspectionIntentTests(unittest.TestCase):
    def test_only_operation_identity_is_accepted(self):
        raw=b'{"operation_id":"managed-python-original","schema":"forge-platform.historical-product-inspection/v1"}'
        self.assertEqual(decode_inspection_intent(raw),"managed-python-original")
        for invalid in (raw+b"\n",raw.replace(b"managed-python-original",b"../other"),
                        raw.replace(b'{',b'{"root":"/tmp",',1),
                        raw.replace(b'{',b'{"operation_id":"other",',1)):
            with self.assertRaises(HistoricalProductEvidenceError):decode_inspection_intent(invalid)

    def test_readonly_worker_never_loads_product_service(self):
        from unittest.mock import patch
        import io
        from forge_platform.installer_product_worker import run
        raw=b'{"operation_id":"managed-python-original","schema":"forge-platform.historical-product-inspection/v1"}'
        with patch("forge_platform.installer_product_worker.inspect_original_product_request",return_value=b"readback") as inspect:
            def forbidden():raise AssertionError("inspection must not load a product service")
            out=io.BytesIO()
            self.assertEqual(run(io.BytesIO(raw),out,service_loader=forbidden),0)
            inspect.assert_called_once_with(raw)
            self.assertEqual(out.getvalue(),b"readback")


@unittest.skipUnless(os.geteuid()==0,"isolated root-owned archive qualification")
class HistoricalProtectedArchiveTests(unittest.TestCase):
    def test_corrupt_cached_content_uses_public_bytes_and_preserves_original(self):
        from hashlib import sha256
        from forge_platform.universal_installer import DownloadIdentity
        raw=b"verified public archive"
        identity=DownloadIdentity("https://github.com/cli/cli/releases/download/example/archive.tar.gz",
                                  "sha256:"+sha256(raw).hexdigest())
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temp:
            path=Path(temp)/"cache";path.write_bytes(b"old corrupt cache");path.chmod(0o600)
            before=path.stat()
            with _StableReadback() as stable:
                self.assertEqual(_archive_readback(stable,path,identity,lambda value:raw),raw)
                stable.verify()
            self.assertEqual(path.stat(),before)
            self.assertEqual(path.read_bytes(),b"old corrupt cache")

    def test_unsafe_cache_profile_cannot_trigger_fallback(self):
        from forge_platform.universal_installer import DownloadIdentity
        identity=DownloadIdentity("https://github.com/cli/cli/releases/download/example/archive.tar.gz","sha256:"+"a"*64)
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temp:
            path=Path(temp)/"cache";path.write_bytes(b"cache");path.chmod(0o644)
            def forbidden(_):raise AssertionError("unsafe cache must deny before network")
            with _StableReadback() as stable:
                with self.assertRaises(HistoricalProductEvidenceError):_archive_readback(stable,path,identity,forbidden)

    def test_actual_provider_trees_and_full_original_reconstruction_are_stable_and_fail_closed(self):
        import io, json, tarfile
        from hashlib import sha256
        from unittest.mock import patch
        import forge_platform.managed_historical_product_evidence as subject
        from forge_platform.universal_installer import CompositionManifest
        from tests.installer.test_managed_product_operation_admission import request_payload
        def canonical(value):
            return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
        def hashed(raw): return sha256(raw).hexdigest()
        with tempfile.TemporaryDirectory(prefix='l1-original-provider-', dir='/private/tmp') as temp:
            base=Path(temp);base.chmod(0o700);root=base/'installer';root.mkdir(mode=0o700)
            state=root/'state';state.mkdir(mode=0o700)
            def directory(path):
                path.mkdir(parents=True, exist_ok=True, mode=0o700)
                current=path
                while current!=base:
                    current.chmod(0o700);current=current.parent
            def write(path,value):
                directory(path.parent);path.write_bytes(canonical(value));path.chmod(0o600)
            # Only account-name resolution is modeled. Actual existing UID owns empty temp homes.
            account=pwd.getpwuid(501)
            operator={'account_name':account.pw_name,'uid':account.pw_uid,'gid':account.pw_gid}
            wire={'ep_instance_id':'fpi-'+'a'*40,'forge_instance_id':'fpi-'+'b'*40,
                'ep_service_account':'_fpi_'+'c'*20,'forge_service_account':account.pw_name,
                'ep_display_label':'Source EP','ep_bind_port':33174,'deployment_id':'production'}
            wire.update(ep_artifact_sha256='sha256:'+'d'*64,forge_artifact_sha256='sha256:'+'e'*64)
            payload=json.loads((Path(__file__).resolve().parents[2]/'compositions/forge-ep-2.8.1-2.3.113.json').read_bytes())
            homes=[];executable_paths=[]
            for requirement in payload['providers']:
                ep=requirement['owner_component']=='engineering-platform-server'
                codex=requirement['identity']=='codex';executable='bin/'+('codex' if codex else 'gh')
                contents=b'isolated source executable\n';archive_stream=io.BytesIO()
                with tarfile.open(fileobj=archive_stream,mode='w:gz') as tf:
                    entry=tarfile.TarInfo('bin');entry.type=tarfile.DIRTYPE;entry.mode=0o700;tf.addfile(entry)
                    entry=tarfile.TarInfo(executable);entry.mode=0o755;entry.size=len(contents);tf.addfile(entry,io.BytesIO(contents))
                    entry=tarfile.TarInfo('notice');entry.mode=0o600;entry.size=6;tf.addfile(entry,io.BytesIO(b'source'))
                raw=archive_stream.getvalue();digest='sha256:'+hashed(raw)
                requirement['minimum_version']='1.2.3'
                requirement['runtime']=dict(version='1.2.3',archive_kind='tar.gz',
                    artifact=dict(url='https://github.com/openai/codex/releases/download/source/archive.tar.gz',digest=digest),
                    executable_relative_path=executable,executable_digest='sha256:'+hashed(contents))
                provider_root=(root/'products/engineering-platform/instances'/wire['ep_instance_id']/'providers'/('codex' if codex else 'github')) if ep else root/'provider-contexts/deployments/production/providers/forge-runtime/production/codex/runtime'
                directory(provider_root)
                slot=provider_root/'runtime' if ep else provider_root/'1.2.3';directory(slot/'bin')
                file=slot/executable;file.write_bytes(contents);file.chmod(0o500)
                subprocess.run(['/bin/chmod','+a',f'user:{account.pw_name} allow read,execute',str(file)],check=True,capture_output=True)
                executable_paths.append(file)
                notice=slot/'notice';notice.write_bytes(b'source');notice.chmod(0o600)
                archive=provider_root/('archive-'+digest[7:]+'.tar.gz');archive.write_bytes(raw);archive.chmod(0o600)
                home=(provider_root/('home' if codex else 'config')) if ep else provider_root.parent/'home'
                home.mkdir(mode=0o700);os.chown(home,account.pw_uid,account.pw_gid);homes.append(home)
            manifest_digest='sha256:'+hashed(canonical(payload))
            manifest=CompositionManifest.from_digest_bound_bytes(canonical(payload),manifest_digest=manifest_digest)
            request=request_payload(manifest,installed=None,exists=False);operation=request['operation_id']
            parent={k:request[k] for k in ('operation_id','session_id','deployment_id','stable_plan_fingerprint','composition_identity','manifest_sha256')}
            parent.update(state='MANAGED_TOOLS',managed_tools_evidence={'python_runtime_receipt_reference':'receipt:runtime-complete'})
            write(state/'active-installer-operation.json',parent)
            providers=[];refs=['receipt:runtime-complete','receipt:git-mutation','receipt:git-final']
            def resolve(name):
                if name in (wire['ep_service_account'],account.pw_name): return account
                raise KeyError(name)
            with patch.object(subject.pwd,'getpwnam',side_effect=resolve), patch.object(subject,'resolve_identity_sha256',return_value='sha256:'+hashed(canonical(operator))):
                with subject._StableReadback() as stable:
                    for requirement in payload['providers']:
                        target,values=subject._provider_references(root,parent,wire,requirement,operator,stable)
                        providers.append(target);refs.extend(values)
                    stable.verify()
                selection={'intent':dict(parent),'component_identities':['engineering-platform-server','forge-runtime'],
                    'enabled_provider_target_ids':sorted(providers),'route_request':{'inventory_evidence_reference':request['inventory_evidence_reference']}}
                write(root/('reviewed-selection-'+hashed(operation.encode())+'.json'),selection)
                route={'components':[dict(id=c['identity'],change='install',installed_version=None,candidate_version=c['candidate_version'],artifact_digest=c['artifact_sha256']) for c in request['components']]}
                write(root/('released-route-'+hashed(canonical(selection['route_request']))+'.json'),route)
                write(root/('reviewed-installer-user-'+hashed((operation+'\0'+parent['stable_plan_fingerprint']).encode())+'.json'),dict(operation_id=operation,stable_plan_fingerprint=parent['stable_plan_fingerprint'],deployment_id='production',operator=operator))
                write(root/'product-worker-authority.json',dict(schema='forge-platform.product-worker-authority/v7',installation_routes=[wire],candidate_manifests=[dict(digest=manifest_digest,payload=payload)],installer_release=request['installer_release']))
                write(state/('managed-git-terminal-'+hashed(operation.encode())+'.json'),dict(phase='COMPLETE',operation_id=operation,stable_plan_fingerprint=parent['stable_plan_fingerprint'],mutation_evidence_reference='receipt:git-mutation',final_readback_evidence_reference='receipt:git-final'))
                request['provider_target_ids']=sorted(providers);request['runtime_evidence_references']=sorted(set(refs));del request['request_fingerprint']
                request['request_fingerprint']=hashed(canonical(request))
                product_id='product-'+hashed((request['request_fingerprint']+'\x1fengineering-platform-server\x1fmutation').encode())
                artifact=next(c.artifact for c in manifest.components if c.identity=='engineering-platform-server')
                product_path=root/'products/engineering-platform/instances'/wire['ep_instance_id']/'operations'/product_id/'request.json'
                write(product_path,dict(contract='engineering-platform.system-provisioner/v1',operation='INSTALL',operation_id=product_id,instance_id=wire['ep_instance_id'],display_label=wire['ep_display_label'],service_account=wire['ep_service_account'],bind_port=wire['ep_bind_port'],release=dict(version=artifact.version,artifact_digest=artifact.digest,source_revision=artifact.source_revision)))
                # No product launch, network request or credential child is used.
                frozen={path:path.read_bytes() for path in root.rglob('*.json')}
                evidence=subject.reconstruct_original_product_evidence(root,operation)
                self.assertEqual(json.loads(evidence.canonical_request),request)
                self.assertEqual(len(evidence.protected_sha256_by_role),7)
                self.assertEqual(subject.reconstruct_original_product_evidence(root,operation),evidence)
                self.assertTrue(all(not list(home.iterdir()) for home in homes))
                self.assertTrue(all(path.read_bytes()==raw for path,raw in frozen.items()))
                executable_paths[0].write_bytes(b'changed tree')
                with self.assertRaises(HistoricalProductEvidenceError):subject.reconstruct_original_product_evidence(root,operation)



@unittest.skipUnless(sys.platform=="darwin" and os.getuid()>0,"Darwin named account required")
class HistoricalRuntimeReadbackTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.account=pwd.getpwuid(os.getuid()).pw_name
        self.file=self.root/"executable";self.file.write_bytes(b"original")
        self.file.chmod(0o500)

    def grant(self,path,permission):
        subprocess.run(["/bin/chmod","+a",f"user:{self.account} allow {permission}",str(path)],check=True,capture_output=True)

    def test_native_search_and_execute_profiles_accepted(self):
        self.grant(self.root,"search")
        self.grant(self.file,"read,execute")
        with _StableReadback() as readback:
            readback.open(self.root,directory=True,acl=lambda fd:_runtime_acl(fd,os.getuid(),8))
            readback.open(self.file,acl=lambda fd:_runtime_acl(fd,os.getuid(),10))
            readback.verify()

    def test_write_unknown_identity_and_inheritance_rejected(self):
        for grant in (f"user:{self.account} allow read,execute,write",
                      "user:root allow read,execute",
                      f"user:{self.account} allow read,execute,file_inherit"):
            subprocess.run(["/bin/chmod","-N",str(self.file)],check=True,capture_output=True)
            subprocess.run(["/bin/chmod","+a",grant,str(self.file)],check=True,capture_output=True)
            fd=os.open(self.file,os.O_RDONLY)
            try:
                with self.assertRaises(HistoricalProductEvidenceError):_runtime_acl(fd,os.getuid(),10)
            finally:os.close(fd)

    def test_earlier_leaf_mutation_rejected_at_end_of_scan(self):
        with _StableReadback() as readback:
            readback.open(self.file,acl=no_extended_acl)
            self.file.chmod(0o600);self.file.write_bytes(b"changed");self.file.chmod(0o500)
            with self.assertRaises(HistoricalProductEvidenceError):readback.verify()

    def test_same_bytes_replacement_rejected(self):
        with _StableReadback() as readback:
            readback.open(self.file,acl=no_extended_acl)
            replacement=self.root/"replacement";replacement.write_bytes(b"original");replacement.chmod(0o500)
            replacement.replace(self.file)
            with self.assertRaises(HistoricalProductEvidenceError):readback.verify()

    def test_provider_parent_write_grant_rejected(self):
        self.grant(self.root,"search,add_file")
        with _StableReadback() as readback:
            with self.assertRaises(HistoricalProductEvidenceError):
                readback.open(self.root,directory=True,acl=lambda fd:_runtime_acl(fd,os.getuid(),8))

    def test_first_provider_replacement_during_third_read_rejected(self):
        files=[]
        for name in ("first","second","third"):
            path=self.root/name;path.write_bytes(b"provider");files.append(path)
        with _StableReadback() as readback:
            for i,path in enumerate(files):
                readback.open(path,acl=no_extended_acl)
                if i==2:
                    replacement=self.root/"replacement";replacement.write_bytes(b"provider")
                    replacement.replace(files[0])
            with self.assertRaises(HistoricalProductEvidenceError):readback.verify()

    def test_acl_drift_rejected(self):
        with _StableReadback() as readback:
            readback.open(self.file,acl=lambda fd:_runtime_acl(fd,os.getuid(),10))
            self.grant(self.file,"read,execute")
            with self.assertRaises(HistoricalProductEvidenceError):readback.verify()


if __name__=="__main__":unittest.main()
