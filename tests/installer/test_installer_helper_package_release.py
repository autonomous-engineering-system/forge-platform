"""Source-only closed V2 handoff and real private publication journal checks."""
from hashlib import sha256
import copy
import contextlib
import io
import sys
import json
import os
from pathlib import Path
import tempfile
import stat
import zipfile
import unittest
from unittest.mock import patch
from scripts import installer_helper_package_release as gate
from scripts import record_local_installer_publication as publisher
from scripts import verify_installer_release_evidence as verifier
from scripts import verified_installer_helper_package as trusted
from tests.installer import test_verify_installer_release_evidence as base
from forge_platform.installer_release_operation import InstallerReleaseOperation, InstallerReleaseOperationStore, InstallerReleasePreparation


def metadata(data=b"source-only companion"):
    return dict(asset_name=gate.ASSET_NAME, digest="sha256:"+sha256(data).hexdigest(), bytes=len(data), notarization_receipt_reference="receipt:source-only")


def descriptor(value=None):
    return dict(schema="forge-platform.installer-release/v2",installer=dict(assets=[dict(helper_package=value or metadata())]))


class CompanionReleaseTests(unittest.TestCase):
    def test_closed_schema_and_metadata(self):
        self.assertEqual(gate.package_metadata(descriptor()),metadata())
        self.assertIsNone(gate.package_metadata(dict(schema="forge-platform.installer-release/v1",installer=dict(assets=[{}]))))
        for key,value in [("asset_name","wrong.pkg"),("digest","sha256:"+"A"*64),("bytes",True),("bytes",0),("bytes",gate.MAXIMUM_BYTES+1),("notarization_receipt_reference","secret"),("extra",1)]:
            bad=metadata();bad[key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):gate.package_metadata(descriptor(bad))
        for bad in [dict(schema="unknown"),dict(schema="forge-platform.installer-release/v2"),dict(schema="forge-platform.installer-release/v2",installer=dict(assets=[])),dict(schema="forge-platform.installer-release/v1",installer=dict(assets=[dict(helper_package=metadata())])),dict(schema="forge-platform.installer-release/v2",installer=dict(assets=[{}]))]:
            with self.assertRaises(ValueError):gate.package_metadata(bad)

    def test_real_readback_refuses_fifo_links_and_changed_bytes(self):
        for kind in ["ok","name","fifo","symlink","hardlink","directory","size","bytes"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);p=root/gate.ASSET_NAME;p.write_bytes(b"source-only companion")
                if kind=="name":p=p.rename(root/"wrong.pkg")
                elif kind=="fifo":p.unlink();os.mkfifo(p)
                elif kind=="symlink":p.rename(root/"original");p.symlink_to(root/"original")
                elif kind=="hardlink":os.link(p,root/"alias")
                elif kind=="directory":p.unlink();p.mkdir()
                elif kind=="size":p.write_bytes(b"short")
                elif kind=="bytes":p.write_bytes(b"X"*len(b"source-only companion"))
                if kind=="ok":gate.require_readback(p,metadata())
                else:
                    with self.assertRaises((ValueError,OSError)):gate.require_readback(p,metadata())

    def test_truncation_growth_and_named_replacement_are_refused(self):
        for kind in ["truncated","grown","replacement"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                p=Path(temporary)/gate.ASSET_NAME;p.write_bytes(b"source-only companion");real=os.read;calls=[]
                def read(fd,size):
                    calls.append(size)
                    if kind=="truncated":return b""
                    result=real(fd,size)
                    if len(calls)==1:
                        if kind=="grown":
                            with p.open("ab") as f:f.write(b"X")
                        else:p.unlink();p.write_bytes(b"source-only companion")
                    return result
                with patch.object(gate.os,"read",side_effect=read),self.assertRaises(ValueError):gate.require_readback(p,metadata())

    def inputs(self,root,v2=True):
        op,desc,archive=base.VerifyInstallerReleaseEvidenceTests._write_release_inputs(root)
        data=json.loads(desc.read_bytes());operation=json.loads(op.read_bytes())
        if v2:
            data["schema"]="forge-platform.installer-release/v2";data["installer"]["assets"][0]["helper_package"]=metadata()
            desc.write_text(json.dumps(data));digest="sha256:"+sha256(desc.read_bytes()).hexdigest()
            operation["descriptor_digest"]=digest;operation["qualification"]["descriptor_digest"]=digest;op.write_text(json.dumps(operation))
        return op,desc,archive

    def verification(self,op,desc,archive,package=None):
        return verifier.verify(operation_raw=op.read_bytes(),descriptor_raw=desc.read_bytes(),archive_paths={"arm64":archive},source_revision=base.SOURCE_SHA,expected_operation_id="installer-release-0001",expected_version="0.1.0",expected_channel="stable",expected_release_sequence=base.RELEASE_SEQUENCE,expected_policy_revision=base.POLICY_REVISION,expected_provenance_sha256=base.PROVENANCE_SHA256,expected_release_trust_configuration_sha256=base.RELEASE_TRUST_CONFIGURATION_SHA256,expected_github_repository=base.IDENTITY.github_repository,expected_release_tag="forge-platform-installer-v0.1.0",expected_descriptor_asset_name=base.IDENTITY.release_descriptor_asset_name,expected_bundle_identifier=base.IDENTITY.bundle_identifier,expected_team_identifier=base.IDENTITY.team_identifier,expected_asset_prefix=base.IDENTITY.asset_prefix,helper_package_path=package)

    def test_v2_structure_requires_actual_trusted_companion_and_exact_bindings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);op,desc,archive=self.inputs(root);p=root/gate.ASSET_NAME;p.write_bytes(b"source-only companion")
            with self.assertRaises(ValueError):self.verification(op,desc,archive)
            with patch.object(trusted,"read_descriptor",return_value=metadata()) as observe:
                self.verification(op,desc,archive,p)
                kwargs=observe.call_args.kwargs
                self.assertEqual(kwargs["archive"],archive);self.assertEqual(kwargs["archive_digest"],"sha256:"+sha256(archive.read_bytes()).hexdigest())
                self.assertEqual(kwargs["team"],base.IDENTITY.team_identifier);self.assertEqual(kwargs["preparation"].source_revision,base.SOURCE_SHA)
            bad=metadata();bad["digest"]="sha256:"+"1"*64
            with patch.object(trusted,"read_descriptor",return_value=bad),self.assertRaises(ValueError):self.verification(op,desc,archive,p)
            with patch.object(trusted,"read_descriptor",side_effect=ValueError("actual platform rejection")),self.assertRaises(ValueError):self.verification(op,desc,archive,p)

    def test_v2_ambiguous_unbound_and_hostile_descriptors_fail_before_platform_inspection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);op,desc,archive=self.inputs(root);original=desc.read_bytes();parsed=json.loads(original)
            cases=[b"[]",b"{",b"\xff",b'{"schema":1,"schema":2}',b'{"schema":NaN}',b" "*(verifier.MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES+1)]
            for trail,value in [(["sequence"],True),(["sequence"],0),(["sequence"],99),(["channel"],"unknown"),(["published_at"],"invalid"),(["published_at"],"2026-01-01T00:00:00"),(["expires_at"],"2025-01-01T00:00:00Z"),(["composition_catalog","url"],"http://untrusted.invalid"),(["github_release","tag"],"../wrong"),(["github_release","repository"],"wrong/identity"),(["installer","assets",0,"helper_package","extra"],"execution selector"),(["installer","assets",0,"operating_system"],"linux"),(["installer","assets",0,"architecture"],"x86_64"),(["installer","assets",0,"notarization_receipt_reference"],"untrusted"),(["installer","assets",0,"digest"],False),(["installer","assets",0,"bundle_identifier"],"wrong.bundle"),(["installer","assets",0,"team_identifier"],"WRONGTEAM1"),(["installer","assets",0,"code_directory_sha256"],"invalid"),(["installer","assets",0,"digest"],"sha256:"+"1"*64),(["installer","capabilities"],["composition/v1","composition/v1"]),(["installer","provenance_sha256"],"1"*64)]:
                bad=copy.deepcopy(parsed);target=bad
                for key in trail[:-1]:target=target[key]
                target[trail[-1]]=value;cases.append(json.dumps(bad).encode())
            with patch.object(trusted,"read_descriptor",side_effect=AssertionError("unbound platform inspection")):
                for raw in cases:
                    desc.write_bytes(raw)
                    with self.subTest(raw_length=len(raw)),self.assertRaises(ValueError):self.verification(op,desc,archive,root/gate.ASSET_NAME)
            desc.write_bytes(original)

    def test_cli_evidence_paths_refuse_nonregular_and_unbounded_inputs(self):
        for kind in ["fifo","link","directory","empty","oversize","missing","missing-parent"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);p=root/"evidence.json"
                if kind=="fifo":os.mkfifo(p)
                elif kind=="link":(root/"original").write_bytes(b"{}");p.symlink_to(root/"original")
                elif kind=="directory":p.mkdir()
                elif kind=="empty":p.write_bytes(b"")
                elif kind=="oversize":p.write_bytes(b"xxx")
                elif kind=="missing-parent":p=root/"absent"/"file"
                with self.assertRaises(ValueError):verifier._read_regular_non_symlink_file(str(p),label="source-only",maximum_bytes=2)
        with tempfile.TemporaryDirectory() as temporary:
            p=Path(temporary)/"evidence.json";p.write_bytes(b"{}")
            self.assertEqual(verifier._read_regular_non_symlink_file(str(p),label="source-only",maximum_bytes=2)[1],b"{}")
            (Path(temporary)/"link").symlink_to(p)
            for args in [[],["arm64="+temporary],["arm64="+str(Path(temporary)/"link")],["arm64"],["arm64="],["x86_64="+str(p)],["arm64="+str(p),"arm64="+str(p)]]:
                with self.assertRaises(ValueError):verifier._archive_arguments(args)

    def test_bundled_public_policy_rejects_traversal_duplicate_links_and_size_overflow(self):
        resource="PublicPolicy.json";name="ForgePlatformInstaller.app/Contents/Resources/"+resource
        for kind in ["ok","traversal","duplicate","link","ancestor-link","oversize","missing","badzip"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                p=Path(temporary)/"source-only.zip"
                with zipfile.ZipFile(p,"w") as archive:
                    selected=("../"+resource) if kind=="traversal" else name
                    def entry(path,mode,data):
                        info=zipfile.ZipInfo(path);info.create_system=3;info.external_attr=mode<<16;archive.writestr(info,data)
                    if kind!="missing":entry(selected,(stat.S_IFLNK|0o777) if kind=="link" else (stat.S_IFREG|0o644),b"xxx" if kind=="oversize" else b"{}")
                    if kind=="duplicate":entry(name,stat.S_IFREG|0o644,b"{}")
                    if kind=="ancestor-link":entry("ForgePlatformInstaller.app/Contents",stat.S_IFLNK|0o777,b"target")
                if kind=="badzip":p.write_bytes(b"not a zip")
                kw=dict(resource_name=resource,maximum_bytes=2,resource_label="public policy")
                if kind=="ok":self.assertEqual(verifier._bundled_resource_bytes(p,**kw),b"{}")
                else:
                    with self.assertRaises(ValueError):verifier._bundled_resource_bytes(p,**kw)

    def test_v1_structure_refuses_unbound_companion(self):
        with tempfile.TemporaryDirectory() as temporary:
            op,desc,archive=self.inputs(Path(temporary),False)
            with self.assertRaises(ValueError):self.verification(op,desc,archive,Path(temporary)/gate.ASSET_NAME)

    def test_publication_never_records_missing_or_wrong_companion(self):
        for kind in ["missing","half","bad","same","ancestor-alias","ok","v1-extra","v1"]:
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary);op,desc,archive=self.inputs(root,not kind.startswith("v1"));store=InstallerReleaseOperationStore(root/"journal");operation=InstallerReleaseOperation.parse(json.loads(op.read_bytes()));store.acquire(operation.operation_id)
                try:
                    preparation=InstallerReleasePreparation(**{key:getattr(operation,key) for key in ["operation_id","installer_version","channel","release_sequence","source_revision","policy_revision","provenance_sha256","release_identity","capabilities","preparation"]})
                    store.prepare_candidate(preparation)
                    store.prepare_qualified(operation)
                finally:store.release(operation.operation_id)
                original=root/"original";readback=root/"readback";original.mkdir();readback.mkdir()
                a=original/gate.ASSET_NAME;b=readback/gate.ASSET_NAME;a.write_bytes(b"source-only companion");b.write_bytes(b"source-only companion" if kind!="bad" else b"wrong")
                kw=dict(operation_path=op,descriptor_path=desc,descriptor_readback_path=desc,archive_path=archive,archive_readback_path=archive,run_id=123,journal_root=root/"journal",output_path=root/"published.json")
                if kind not in ["missing","v1"]:kw["helper_package_path"]=a
                if kind in ["bad","ok","v1-extra","same","ancestor-alias"]:kw["helper_package_readback_path"]=b
                if kind=="same":kw["helper_package_readback_path"]=a
                if kind=="ancestor-alias":
                    (root/"alias").symlink_to(original,target_is_directory=True)
                    kw["helper_package_readback_path"]=root/"alias"/gate.ASSET_NAME
                if kind in ["ok","v1"]:
                    result=publisher.record(**kw);self.assertEqual(result.state,"PUBLISHED")
                    cli=["--operation",str(op),"--descriptor",str(desc),"--descriptor-readback",str(desc),"--archive",str(archive),"--archive-readback",str(archive),"--run-id","123","--journal-root",str(root/"journal"),"--output",str(root/"published.json")]
                    if kind=="ok":cli += ["--helper-package",str(a),"--helper-package-readback",str(b)]
                    with contextlib.redirect_stdout(io.StringIO()):self.assertEqual(publisher.main(cli),0)
                    bad_cli=list(cli)
                    if "--helper-package" in bad_cli:bad_cli[bad_cli.index("--helper-package")+1]=str(root/"missing.pkg")
                    else:bad_cli += ["--helper-package",str(root/"missing.pkg")]
                    with contextlib.redirect_stderr(io.StringIO()):self.assertEqual(publisher.main(bad_cli),1)
                    persisted=InstallerReleaseOperation.parse(json.loads((root/"published.json").read_bytes()));self.assertEqual(persisted.descriptor_digest,operation.descriptor_digest)
                else:
                    with self.assertRaises(ValueError):publisher.record(**kw)
                    self.assertFalse((root/"published.json").exists())


if __name__=="__main__":unittest.main()
