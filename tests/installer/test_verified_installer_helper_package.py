"""Source-only artifact and signing-payload qualification; no live release."""
import base64
from dataclasses import asdict, replace
from hashlib import sha256
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
import gzip
from scripts import installer_helper_package_payload as payload_inspector
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT));sys.path.insert(0,str(ROOT/'scripts'))
from scripts import verified_installer_helper_package as verifier
from scripts import qualify_local_installer_release as qualifier
from tests.installer import test_installer_release_operation as operations
from forge_platform.installer_release_trust import canonical_release_trust_configuration_sha256
from tests.installer.helper_package_source_fixture import create

GOOD='Status: signed by a developer certificate issued by Apple for distribution\n 1. Developer ID Installer: source test (ZEML4LPXH4)\n'

class HelperPackageDescriptorTests(unittest.TestCase):
    def file(self,root):
        p,archive,preparation=create(root)
        if not hasattr(self,'bindings'):self.bindings={}
        self.bindings[root]=(archive,preparation)
        return p
    def read(self,path):
        archive,preparation=self.bindings[path.parent]
        return verifier.read_descriptor(path,team='ZEML4LPXH4',notarization_reference='receipt:source-test',archive=archive,preparation=preparation,archive_digest="sha256:"+sha256(archive.read_bytes()).hexdigest())
    def test_exact_file_descriptor_and_every_platform_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            p=self.file(Path(temporary));calls=[]
            def inspect(tool,args):
                calls.append((tool,args));return GOOD if tool.endswith('pkgutil') else ''
            with patch.object(verifier,'_observe',side_effect=inspect): value=self.read(p)
            self.assertEqual(value,dict(asset_name=verifier.ASSET_NAME,digest='sha256:'+sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size,notarization_receipt_reference='receipt:source-test'))
            self.assertEqual([x[0] for x in calls],['/usr/sbin/pkgutil','/usr/bin/xcrun','/usr/sbin/spctl'])
            for fail in range(3):
                count=[]
                def failing(tool,args):
                    count.append(tool);return None if len(count)-1==fail else (GOOD if tool.endswith('pkgutil') else '')
                with patch.object(verifier,'_observe',side_effect=failing),self.assertRaises(ValueError):self.read(p)
    def test_wrong_signature_identity_ambiguity_and_unsigned_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            p=self.file(Path(temporary))
            for text in [GOOD.replace('ZEML4LPXH4','OTHERTEAM1'),GOOD.replace('Installer:','Application:'),GOOD+GOOD,'unsigned',None]:
                with patch.object(verifier,'_observe',return_value=text),self.assertRaises(ValueError):self.read(p)
    def test_hostile_file_paths_and_permissions_are_rejected_before_inspection(self):
        for kind in ['link','hardlink','fifo','directory','empty','size','mode','parent','name','team','reference']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);p=self.file(root);archive,preparation=self.bindings[root];kw=dict(team='ZEML4LPXH4',notarization_reference='receipt:source-test',archive=archive,preparation=preparation,archive_digest="sha256:"+sha256(archive.read_bytes()).hexdigest())
                if kind=='link':p.rename(root/'retained');p.symlink_to(root/'retained')
                elif kind=='hardlink':os.link(p,root/'alias')
                elif kind=='fifo':p.unlink();os.mkfifo(p,0o600)
                elif kind=='directory':p.unlink();p.mkdir()
                elif kind=='empty':p.write_bytes(b'')
                elif kind=='mode':p.chmod(0o644)
                elif kind=='parent':root.chmod(0o755)
                elif kind=='name':p=p.rename(root/'wrong.pkg')
                elif kind=='team':kw['team']='bad'
                elif kind=='reference':kw['notarization_reference']='https://untrusted.invalid'
                with patch.object(verifier,'MAXIMUM_BYTES',1 if kind=='size' else verifier.MAXIMUM_BYTES),patch.object(verifier,'_check_platform',side_effect=AssertionError('unsafe platform inspection')):
                    with self.assertRaises((OSError,ValueError)):verifier.read_descriptor(p,**kw)
    def test_file_replacement_and_parent_mutation_cannot_reuse_signature_observation(self):
        for kind in ['replace','write','parent']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);p=self.file(root)
                def mutate(path,team):
                    if kind=='replace':path.unlink();path.write_bytes(b'source-only candidate');path.chmod(0o600)
                    elif kind=='write':path.write_bytes(b'changed bytes')
                    else:(root/'extra').write_bytes(b'changed namespace')
                    return True
                with patch.object(verifier,'_check_platform',side_effect=mutate),self.assertRaises(ValueError):self.read(p)
    def test_inspection_output_is_bounded_and_commands_closed(self):
        self.assertIsNone(verifier._observe('/bin/sh',['-c','anything']))
        for kind in ['ok','large','badutf','exit','timeout']:
            def run(args,**kw):
                if kind=='timeout':raise subprocess.TimeoutExpired(args,20)
                kw['stdout'].write(b'\xff' if kind=='badutf' else (b'x'*17000 if kind=='large' else b'ok'))
                return subprocess.CompletedProcess(args,1 if kind=='exit' else 0)
            with patch.object(verifier.subprocess,'run',side_effect=run):
                self.assertEqual(verifier._observe('/usr/sbin/pkgutil',['--check-signature','source.pkg']),'ok' if kind=='ok' else None)
    def test_real_unsigned_pkgbuild_artifact_fails_without_injected_platform_check(self):
        if sys.platform!='darwin':self.skipTest('actual macOS inspection')
        with tempfile.TemporaryDirectory() as temporary:
            p=self.file(Path(temporary))
            with self.assertRaises(ValueError):self.read(p)
    def test_wrong_release_and_extra_installation_scripts_fail_before_descriptor_evidence(self):
        for kind in ['wrong-version','wrong-source','script','app-byte-drift']:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);p,archive,preparation=create(root/'good')
                if kind=='app-byte-drift':
                    alternate=create(root/'alternate')
                    with zipfile.ZipFile(archive) as old: entries=[(info,old.read(info)) for info in old.infolist()]
                    with zipfile.ZipFile(archive,'w') as changed:
                        for info,data in entries: changed.writestr(info,data+b'changed' if info.filename.endswith('/ForgePlatformInstaller') else data)
                else:
                    p,_,_=create(root/'other',version='1.2.0' if kind=='wrong-version' else '1.1.0',source='b'*40 if kind=='wrong-source' else 'a'*40,extra_script=kind=='script')
                with patch.object(verifier,'_observe',side_effect=lambda tool,args:GOOD if tool.endswith('pkgutil') else ''),self.assertRaises(ValueError):
                    verifier.read_descriptor(p,team='ZEML4LPXH4',notarization_reference='receipt:source-test',archive=archive,preparation=preparation,archive_digest="sha256:"+sha256(archive.read_bytes()).hexdigest())
    def test_os_metadata_profile_cannot_import_resource_forks_finder_flags_or_other_attributes(self):
        with tempfile.TemporaryDirectory() as temporary:
            package,archive,preparation=create(Path(temporary))
            descriptor=os.open(package,os.O_RDONLY|os.O_NOFOLLOW)
            try:
                start,length,_,_=payload_inspector._xar(descriptor)['Payload']
                with gzip.GzipFile(fileobj=payload_inspector._Region(descriptor,start,length)) as stream:
                    original=None
                    while True:
                        header=stream.read(76);name_size=int(header[59:65],8);size=int(header[65:76],8)
                        name=stream.read(name_size)[:-1].decode();data=stream.read(size)
                        if '/._' in name:original=data;break
                        if name=='TRAILER!!!':break
                # pkgbuild does not always emit protected OS provenance. Verify
                # any emitted sidecar, then exercise the fixed hostile-byte case
                # independently of the host's optional extended attributes.
                if original is not None:payload_inspector._os_provenance_sidecar(original)
                import struct
                sample=bytearray(163)
                struct.pack_into('>II16sH',sample,0,0x51607,0x20000,b'\0'*16,2)
                struct.pack_into('>III',sample,26,9,50,113)
                struct.pack_into('>III',sample,38,2,163,0)
                struct.pack_into('>IIIIIIIIHH',sample,84,0x41545452,0,163,152,11,0,0,0,0,1)
                struct.pack_into('>IIHB',sample,120,152,11,0,21)
                sample[131:152]=b'com.apple.provenance\0'
                original=bytes(sample)
                payload_inspector._os_provenance_sidecar(original)
                for kind in ['finder','resource-fork','attribute','flags','length']:
                    data=bytearray(original)
                    if kind=='finder':data[50]=1
                    elif kind=='resource-fork':data[49]=1
                    elif kind=='attribute':data[131]=ord('x')
                    elif kind=='flags':data[117]=1
                    else:data.append(0)
                    with self.assertRaises(ValueError):payload_inspector._os_provenance_sidecar(bytes(data))
            finally:os.close(descriptor)
    def test_archive_digest_change_and_unbounded_entity_metadata_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            package,archive,preparation=create(Path(temporary))
            descriptor=os.open(package,os.O_RDONLY|os.O_NOFOLLOW)
            try:
                with self.assertRaises(ValueError):payload_inspector.verify_payload(descriptor,archive=archive,preparation=preparation,archive_digest='sha256:'+'0'*64)
            finally:os.close(descriptor)
        for data in [b'<!DOCTYPE x [<!ENTITY e "more">]><x>&e;</x>',b'\xff',b'<unclosed>']:
            with self.assertRaises(ValueError):payload_inspector._xml(data)
        with self.assertRaises(ValueError):payload_inspector._inflate(b'',5*1024*1024)
    def test_v2_helper_fields_are_covered_by_actual_ed25519_signature_and_v1_is_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);root.chmod(0o700)
            key=root/'source-test-key.pem';pub=root/'source-test-public.der'
            subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            subprocess.run(['openssl','pkey','-in',str(key),'-pubout','-outform','DER','-out',str(pub)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            public=pub.read_bytes()[-32:];public64=base64.b64encode(public).decode()
            identity=replace(operations.RELEASE_IDENTITY,team_identifier='ZEML4LPXH4',bundle_identifier='com.autonomous-engineering-system.forge-platform-installer')
            policy=dict(repository=identity.github_repository,release_descriptor_locator='github-release-asset-v1',release_descriptor_asset_name=identity.release_descriptor_asset_name,expected_bundle_identifier=identity.bundle_identifier,expected_team_identifier=identity.team_identifier,signature_threshold=1,ed25519_public_keys=[('release-key-001',public64)])
            digest=canonical_release_trust_configuration_sha256(**policy);identity=replace(identity,release_trust_configuration_sha256=digest)
            policy['ed25519_public_keys']=[dict(key_id='release-key-001',public_key_base64=public64)];policy.update(schema_version=2,configuration_sha256=digest)
            trust=root/'trust.json';trust.write_text(json.dumps(policy))
            signed=[]
            def sign(tool,keyid,payload):
                message=root/'message';signature=root/'signature';message.write_bytes(payload)
                subprocess.run(['openssl','pkeyutl','-sign','-rawin','-inkey',str(key),'-in',str(message),'-out',str(signature)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                raw=signature.read_bytes();signed.append((payload,raw))
                return dict(algorithm='ed25519',key_id=keyid,signature=base64.urlsafe_b64encode(raw).decode().rstrip('=')),raw
            from forge_platform import installer_helper_companion as companion
            for version in [1,2]:
                caps=tuple(sorted((*operations.CAPABILITIES,companion.CAPABILITY))) if version==2 else operations.CAPABILITIES
                p,archive,source_preparation=create(root/('package-input'+str(version)),trust=digest,capabilities=list(caps))
                preparation=root/('preparation'+str(version)+'.json')
                preparation.write_text(json.dumps(asdict(operations.prepared_candidate(operations.operation(release_identity=identity,provenance_sha256=source_preparation.provenance_sha256,capabilities=caps)))))
                kwargs=dict(preparation_path=preparation,signed_archive=archive,release_trust_path=trust,descriptor_key_tool=root/'unused-test-key-tool',code_directory_sha256='4'*64,notarization_receipt_reference='receipt:source-test',catalog_url='https://catalog.example.invalid/catalog.json',published_at='2026-10-10T00:00:00Z',expires_at='2026-10-20T00:00:00Z',run_id=123,journal_root=root/('journal'+str(version)),output_directory=root/('output'+str(version)))
                if version==2:kwargs.update(signed_helper_package=p,helper_package_notarization_receipt_reference='receipt:source-test')
                with patch.object(qualifier,'_descriptor_key_tool',return_value=root/'source-only-tool'),patch.object(qualifier,'_tool_public_key',return_value=public),patch.object(qualifier,'_tool_signature',side_effect=sign),patch.object(verifier,'_observe',side_effect=lambda tool,args:GOOD if tool.endswith('pkgutil') else ''):
                    operation=qualifier.qualify(**kwargs)
                body=json.loads(signed[-1][0]);self.assertEqual(body['schema'],'forge-platform.installer-release/v'+str(version))
                asset=body['installer']['assets'][0]
                if version==1:self.assertNotIn('helper_package',asset)
                else:
                    self.assertEqual(asset['helper_package']['digest'],'sha256:'+sha256(p.read_bytes()).hexdigest())
                    asset['helper_package']['digest']='sha256:'+'0'*64
                    with self.assertRaises(ValueError):qualifier._verify_signature(public,qualifier._canonical(body),signed[-1][1])
                descriptor=kwargs['output_directory']/identity.release_descriptor_asset_name
                self.assertEqual(operation.descriptor_digest,'sha256:'+sha256(descriptor.read_bytes()).hexdigest())
                self.assertEqual(json.loads(descriptor.read_bytes())['schema'],'forge-platform.installer-release/v1')
                if version==2:
                    child=kwargs['output_directory']/companion.ASSET_NAME
                    expected='sha256:'+sha256(child.read_bytes()).hexdigest()
                    self.assertEqual(companion.qualification_binding(operation),expected)
                    self.assertEqual(companion.bound_metadata(descriptor.read_bytes(),child.read_bytes(),expected)['digest'],'sha256:'+sha256(p.read_bytes()).hexdigest())
                    payloads=[json.loads(raw) for raw,_ in signed[-2:]]
                    self.assertEqual([v['schema'] for v in payloads],['forge-platform.installer-release/v1','forge-platform.installer-release/v2'])
                    self.assertEqual(payloads[1]['primary_descriptor_digest'],operation.descriptor_digest)
