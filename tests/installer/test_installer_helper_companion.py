"""Source qualification of compatibility, real private anchors and journals."""
import copy
from dataclasses import asdict
from hashlib import sha256
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from forge_platform import installer_helper_companion as companion
from forge_platform.universal_installer import InstallerRelease, UniversalInstallerError
from forge_platform.installer_release_operation import InstallerReleaseOperation, InstallerReleaseOperationStore, InstallerReleasePreparation
from scripts import record_local_installer_publication as publisher, verify_installer_release_evidence as verifier
from scripts import qualify_local_installer_release as qualifier, verified_installer_helper_package as package_reader
from tests.installer import test_verify_installer_release_evidence as base, test_universal_installer as consumer
from tests.installer.test_installer_helper_package_release import metadata


def joined_documents():
    primary=consumer.release_metadata(capabilities=tuple(sorted((*consumer.INSTALLER_CAPABILITIES,companion.CAPABILITY))))
    raw=companion.canonical(primary)+b"\n"
    child=copy.deepcopy(primary);child["schema"]="forge-platform.installer-release/v2"
    child["primary_descriptor_digest"]="sha256:"+sha256(raw).hexdigest()
    child["installer"]["assets"][0]["helper_package"]=metadata()
    return raw,companion.canonical(child)+b"\n"


class HelperCompanionTests(unittest.TestCase):
    def test_python_consumer_verifies_both_and_persists_second_anchor(self):
        primary,child=joined_documents()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve()/"companion"
            probe=consumer.FixtureVerifier()
            def read(raw):return InstallerRelease.from_signed_bytes(primary,probe,signature_policy=consumer.FIXTURE_SIGNATURE_POLICY,
                sealed_release_trust=consumer.SEALED_RELEASE_TRUST,helper_companion_bytes=raw,
                helper_companion_acceptance_store=companion.FileHelperCompanionAcceptanceStore(root))
            joined=read(child);self.assertIsNotNone(joined.assets[0].helper_package)
            self.assertEqual(len(probe.payloads),2)
            self.assertEqual(probe.payloads[0],companion.canonical({k:v for k,v in json.loads(primary).items() if k!="signatures"}))
            self.assertEqual(read(child),joined)
            changed=json.loads(child);changed["installer"]["assets"][0]["helper_package"]["digest"]="sha256:"+"1"*64
            with self.assertRaises(ValueError):read(companion.canonical(changed))
            anchor=json.loads((root/"highest-accepted-installer-release.json").read_bytes())
            self.assertEqual(anchor["descriptorSHA256"],sha256(child).hexdigest())

    def test_missing_companion_mapping_bypass_and_untrusted_signature_fail(self):
        primary,child=joined_documents();kwargs=dict(signature_policy=consumer.FIXTURE_SIGNATURE_POLICY,sealed_release_trust=consumer.SEALED_RELEASE_TRUST)
        with self.assertRaises(UniversalInstallerError):InstallerRelease.from_signed_metadata(json.loads(primary),consumer.FixtureVerifier(),**kwargs)
        with self.assertRaises(UniversalInstallerError):InstallerRelease.from_signed_bytes(primary,consumer.FixtureVerifier(),**kwargs)
        with tempfile.TemporaryDirectory() as directory:
            class RejectSecond(consumer.FixtureVerifier):
                def verify(self,*args,**kw):return super().verify(*args,**kw) and len(self.payloads)==1
            with self.assertRaises(UniversalInstallerError):InstallerRelease.from_signed_bytes(primary,RejectSecond(),**kwargs,
                helper_companion_bytes=child,helper_companion_acceptance_store=companion.FileHelperCompanionAcceptanceStore(Path(directory).resolve()/"anchor"))
            self.assertFalse((Path(directory)/"anchor").exists())
        old=consumer.release_metadata();old_raw=companion.canonical(old)
        with self.assertRaises(UniversalInstallerError):InstallerRelease.from_signed_bytes(old_raw,consumer.FixtureVerifier(),**kwargs,helper_companion_bytes=child)

    def test_exact_binding_refuses_all_changed_release_fields_and_digest(self):
        primary,child=joined_documents();digest="sha256:"+sha256(child).hexdigest()
        self.assertEqual(companion.bound_metadata(primary,child,digest),metadata())
        parsed=json.loads(child)
        cases=[]
        for key,value in [("primary_descriptor_digest","sha256:"+"0"*64),("schema","wrong"),("sequence",True),("signatures",[]),("extra",1)]:
            bad=copy.deepcopy(parsed);bad[key]=value;cases.append(companion.canonical(bad))
        for trail,value in [(["installer","source_revision"],"a"*40),(["installer","assets",0,"helper_package","extra"],1)]:
            bad=copy.deepcopy(parsed);target=bad
            for key in trail[:-1]:target=target[key]
            target[trail[-1]]=value;cases.append(companion.canonical(bad))
        for raw in cases:
            with self.assertRaises((ValueError,KeyError,TypeError)):companion.bound_metadata(primary,raw,"sha256:"+sha256(raw).hexdigest())
        with self.assertRaises(ValueError):companion.bound_metadata(primary,child,"sha256:"+"f"*64)
        for raw in [b"[]",b'{"a":1,"a":2}',b'{"a":NaN}',b"",b" "*(companion.MAXIMUM_BYTES+1)]:
            with self.assertRaises(ValueError):companion.strict_object(raw)

    def test_real_anchor_refuses_regression_corruption_links_modes_and_partial_files(self):
        for kind in ["regression","conflict","corrupt","mode","link","fifo","partial"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                root=Path(directory).resolve()/"anchor";store=companion.FileHelperCompanionAcceptanceStore(root)
                store.accept(2,"sha256:"+"a"*64);path=root/"highest-accepted-installer-release.json"
                if kind=="corrupt":path.write_bytes(b"{}")
                if kind=="mode":root.chmod(0o755)
                if kind=="link":path.rename(root.parent/"original");path.symlink_to(root.parent/"original")
                if kind=="fifo":path.unlink();os.mkfifo(path,0o600)
                if kind=="partial":(root/"anchor-unknown.tmp").write_bytes(b"retained")
                with self.assertRaises((ValueError,OSError)):store.accept(1 if kind=="regression" else 2,"sha256:"+("b" if kind=="conflict" else "a")*64)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();(root/"alias").symlink_to(root,target_is_directory=True)
            with self.assertRaises(ValueError):companion.FileHelperCompanionAcceptanceStore(root/"alias"/"child").accept(1,"sha256:"+"a"*64)
            for sequence,digest in [(True,"sha256:"+"a"*64),(0,"invalid")]:
                with self.assertRaises(ValueError):companion.FileHelperCompanionAcceptanceStore(root/"anchor").accept(sequence,digest)

    @unittest.skipUnless(__import__("sys").platform == "darwin", "real Darwin ACL qualification")
    def test_actual_replay_root_lock_and_anchor_acl_refuse(self):
        import subprocess
        for kind in ["root", "lock", "anchor"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                root=Path(directory).resolve()/"anchor";store=companion.FileHelperCompanionAcceptanceStore(root)
                store.accept(2,"sha256:"+"a"*64)
                path=root if kind=="root" else root/("anchor.lock" if kind=="lock" else "highest-accepted-installer-release.json")
                acl="everyone allow search,add_file,delete_child" if kind=="root" else "everyone allow read,write"
                self.assertEqual(subprocess.run(["/bin/chmod","+a",acl,str(path)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode,0)
                with self.assertRaises(ValueError):store.accept(2,"sha256:"+"a"*64)

    def test_real_document_readback_rejects_fifo_links_and_nonregular(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/companion.ASSET_NAME;path.write_bytes(b"{}")
            self.assertEqual(companion.read_document(path)[0],b"{}")
            alias=root/"alias";alias.symlink_to(path)
            with self.assertRaises((ValueError,OSError)):companion.read_document(alias)
            path.unlink();os.mkfifo(path)
            with self.assertRaises(ValueError):companion.read_document(path)


class CompanionPublicationTests(unittest.TestCase):
    def inputs(self,root):
        op,primary,archive=base.VerifyInstallerReleaseEvidenceTests._write_release_inputs(root)
        data=json.loads(primary.read_bytes());operation=json.loads(op.read_bytes())
        caps=sorted([*operation["capabilities"],companion.CAPABILITY])
        provenance=base.VerifyInstallerReleaseEvidenceTests._provenance_payload(capabilities=caps)
        base.VerifyInstallerReleaseEvidenceTests._write_archive(archive,provenance)
        archive_digest="sha256:"+sha256(archive.read_bytes()).hexdigest()
        data["installer"]["capabilities"]=caps;data["installer"]["provenance_sha256"]=provenance["provenance_sha256"]
        data["installer"]["assets"][0]["digest"]=archive_digest
        primary.write_bytes(companion.canonical(data)+b"\n");digest="sha256:"+sha256(primary.read_bytes()).hexdigest()
        child=copy.deepcopy(data);child["schema"]="forge-platform.installer-release/v2";child["primary_descriptor_digest"]=digest
        child["installer"]["assets"][0]["helper_package"]=metadata()
        child_path=root/companion.ASSET_NAME;child_path.write_bytes(companion.canonical(child)+b"\n")
        operation["capabilities"]=caps;operation["provenance_sha256"]=provenance["provenance_sha256"]
        operation["descriptor_digest"]=digest;operation["archives"]["arm64"]=archive_digest;operation["preparation"]["candidate_archives"]["arm64"]=archive_digest
        q=operation["qualification"];q["provenance_sha256"]=provenance["provenance_sha256"];q["descriptor_digest"]=digest
        q["archives"]["arm64"]=archive_digest;q["candidate_archives"]["arm64"]=archive_digest
        q["qualification_receipt_reference"]="receipt:local-signing-qualification-123-helper-"+sha256(child_path.read_bytes()).hexdigest()
        op.write_bytes(companion.canonical(operation))
        return op,primary,archive,child_path,provenance

    def test_structural_gate_requires_companion_and_exact_immutable_qualification_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);op,primary,archive,child,provenance=self.inputs(root)
            pkg=root/metadata()["asset_name"];pkg.write_bytes(b"source-only companion")
            kw=dict(operation_raw=op.read_bytes(),descriptor_raw=primary.read_bytes(),archive_paths={"arm64":archive},source_revision=base.SOURCE_SHA,
                expected_operation_id="installer-release-0001",expected_version="0.1.0",expected_channel="stable",expected_release_sequence=base.RELEASE_SEQUENCE,
                expected_policy_revision=base.POLICY_REVISION,expected_provenance_sha256=provenance["provenance_sha256"],expected_release_trust_configuration_sha256=base.RELEASE_TRUST_CONFIGURATION_SHA256,
                expected_github_repository=base.IDENTITY.github_repository,expected_release_tag="forge-platform-installer-v0.1.0",expected_descriptor_asset_name=base.IDENTITY.release_descriptor_asset_name,
                expected_bundle_identifier=base.IDENTITY.bundle_identifier,expected_team_identifier=base.IDENTITY.team_identifier,expected_asset_prefix=base.IDENTITY.asset_prefix,helper_package_path=pkg)
            with self.assertRaises(ValueError):verifier.verify(**kw)
            with patch.object(package_reader,"read_descriptor",return_value=metadata()):verifier.verify(**kw,helper_companion_path=child)
            child.write_bytes(child.read_bytes()+b" ")
            with self.assertRaises(ValueError):verifier.verify(**kw,helper_companion_path=child)

    def test_structural_cli_accepts_bound_companion_and_refuses_omission(self):
        import io
        import sys
        from contextlib import redirect_stdout, redirect_stderr
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);op,primary,archive,child,provenance=self.inputs(root)
            pkg=root/metadata()["asset_name"];pkg.write_bytes(b"source-only companion")
            args=["verify-installer-release-evidence", "--operation",str(op),"--descriptor",str(primary),"--archive","arm64="+str(archive),
                "--helper-package",str(pkg),"--source-sha",base.SOURCE_SHA,"--operation-id","installer-release-0001",
                "--installer-version","0.1.0","--channel","stable","--release-sequence",str(base.RELEASE_SEQUENCE),
                "--policy-revision",base.POLICY_REVISION,"--provenance-sha256",provenance["provenance_sha256"],
                "--release-trust-configuration-sha256",base.RELEASE_TRUST_CONFIGURATION_SHA256,
                "--github-repository",base.IDENTITY.github_repository,"--release-tag","forge-platform-installer-v0.1.0",
                "--descriptor-asset-name",base.IDENTITY.release_descriptor_asset_name,"--bundle-identifier",base.IDENTITY.bundle_identifier,
                "--team-identifier",base.IDENTITY.team_identifier,"--asset-prefix",base.IDENTITY.asset_prefix]
            for include in [False,True]:
                output=io.StringIO()
                with patch.object(sys,"argv",args+(["--helper-companion",str(child)] if include else [])),redirect_stdout(output),redirect_stderr(output),patch.object(package_reader,"read_descriptor",return_value=metadata()):
                    if include:
                        verifier.main()
                        self.assertIn("INSTALLER_RELEASE_EVIDENCE_STRUCTURE=PASS",output.getvalue())
                    else:
                        with self.assertRaises(SystemExit) as failure:verifier.main()
                        self.assertEqual(failure.exception.code,1)
                        self.assertNotIn("STRUCTURE=PASS",output.getvalue())

    def test_publication_requires_independent_companion_before_journal_mutation(self):
        for kind in ["ok","same","missing","changed"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as directory:
                root=Path(directory);op,primary,archive,child,_=self.inputs(root)
                operation=InstallerReleaseOperation.parse(json.loads(op.read_bytes()))
                store=InstallerReleaseOperationStore(root/"journal");store.acquire(operation.operation_id)
                try:
                    preparation=InstallerReleasePreparation(**{key:getattr(operation,key) for key in ["operation_id","installer_version","channel","release_sequence","source_revision","policy_revision","provenance_sha256","release_identity","capabilities","preparation"]})
                    store.prepare_candidate(preparation);store.prepare_qualified(operation)
                finally:store.release(operation.operation_id)
                folder=root/"readback";folder.mkdir()
                back=folder/companion.ASSET_NAME;back.write_bytes(child.read_bytes()+(b" " if kind=="changed" else b""))
                a=root/metadata()["asset_name"];a.write_bytes(b"source-only companion")
                b=folder/a.name;b.write_bytes(a.read_bytes())
                kw=dict(operation_path=op,descriptor_path=primary,descriptor_readback_path=primary,archive_path=archive,archive_readback_path=archive,
                    run_id=123,journal_root=root/"journal",output_path=root/"published.json",helper_package_path=a,helper_package_readback_path=b,
                    helper_companion_path=child,helper_companion_readback_path=None if kind=="missing" else (child if kind=="same" else back))
                if kind=="ok":self.assertEqual(publisher.record(**kw).state,"PUBLISHED")
                else:
                    with self.assertRaises(ValueError):publisher.record(**kw)
                    self.assertFalse((root/"published.json").exists())

if __name__=="__main__":unittest.main()
