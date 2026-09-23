#!/usr/bin/env python3
from __future__ import annotations

from hashlib import sha256
import io
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))

from forge_platform.provider_runtime import (
    ManagedProviderRuntimeCoordinator,
    ProviderDownloadReceipt,
    ProviderProcessResult,
    ProviderRuntimeError,
    ProviderRuntimeInstaller,
    ProviderRuntimeTarget,
)
from forge_platform.universal_installer import ProviderRequirement, ProviderRuntimeArtifact, SemanticVersion


def archive_bytes(fmt: str, executable: str) -> bytes:
    stream=io.BytesIO()
    if fmt=="zip":
        with zipfile.ZipFile(stream,"w") as zf:
            info=zipfile.ZipInfo(executable)
            info.external_attr=(0o755 & 0xFFFF)<<16
            zf.writestr(info,b"provider-binary")
    else:
        with tarfile.open(fileobj=stream,mode="w:gz") as tf:
            info=tarfile.TarInfo(executable)
            info.mode=0o755
            payload=b"provider-binary"
            info.size=len(payload)
            tf.addfile(info,io.BytesIO(payload))
    return stream.getvalue()


def requirement(provider: str, target: str, fmt: str="zip") -> tuple[ProviderRequirement,bytes]:
    executable="bin/codex" if provider=="codex" else "bin/gh"
    payload=archive_bytes(fmt,executable)
    runtime=ProviderRuntimeArtifact(
        SemanticVersion.parse("1.2.3"),"source-1",
        "https://artifacts.example.invalid/provider.zip",
        "sha256:"+sha256(payload).hexdigest(),"qualification:provider",
        fmt,executable,
    )
    return ProviderRequirement(
        provider,True,SemanticVersion.parse("1.0.0"),"component",
        "forge-runtime" if provider=="codex" else "engineering-platform-server",
        target,runtime,
    ),payload


class Transport:
    def __init__(self,payload: bytes): self.payload=payload; self.calls=0
    def fetch(self,artifact,destination):
        self.calls+=1
        destination.write_bytes(self.payload)
        return ProviderDownloadReceipt(artifact.url,artifact.url,artifact.digest,len(self.payload))


class Runner:
    def __init__(self): self.calls=[]; self.token="gh-secret-token"
    def run(self,argv,*,environment,input_text=None):
        self.calls.append((tuple(argv),dict(environment),input_text))
        if tuple(argv)[1:4]==("auth","token","--hostname"):
            return ProviderProcessResult(0,self.token+"\n","")
        return ProviderProcessResult(0,"ok\n","")


class ProviderRuntimeTests(unittest.TestCase):
    def make_target(self,root: Path,requirement: ProviderRequirement) -> ProviderRuntimeTarget:
        runtime=root/"runtime"
        exe=runtime/("bin/codex" if requirement.identity=="codex" else "bin/gh")
        return ProviderRuntimeTarget(
            requirement.identity,requirement.owner_component or "",requirement.target_identity or "",
            root,runtime,exe,root/"home",root/"config",
        )

    def test_installer_downloads_exact_archive_and_installs_target_owned_runtime(self):
        with tempfile.TemporaryDirectory() as d:
            req,payload=requirement("codex","forge-one")
            target=self.make_target(Path(d)/"target",req)
            transport=Transport(payload)
            installer=ProviderRuntimeInstaller(transport)
            rb=installer.install(req,target)
            self.assertEqual(rb.state,"AUTHENTICATION_REQUIRED")
            self.assertTrue(target.executable.is_file())
            self.assertTrue(target.executable.stat().st_mode & stat.S_IXUSR)
            self.assertEqual(transport.calls,1)
            again=installer.install(req,target)
            self.assertEqual(again.executable_identity,rb.executable_identity)
            self.assertEqual(transport.calls,1)

    def test_runtime_substitution_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            req,payload=requirement("github-cli","ep-one","tar-gzip")
            target=self.make_target(Path(d)/"target",req)
            installer=ProviderRuntimeInstaller(Transport(payload))
            installer.install(req,target)
            target.executable.write_bytes(b"tampered")
            with self.assertRaisesRegex(ProviderRuntimeError,"substituted"):
                installer.install(req,target)

    def test_zip_and_tar_reject_path_traversal_or_links(self):
        with tempfile.TemporaryDirectory() as d:
            req,_=requirement("codex","forge-one")
            bad=io.BytesIO()
            with zipfile.ZipFile(bad,"w") as zf:
                zf.writestr("../escape",b"x")
            payload=bad.getvalue()
            runtime=req.runtime
            req=ProviderRequirement(
                req.identity,req.required,req.minimum_version,req.credential_scope,
                req.owner_component,req.target_identity,
                ProviderRuntimeArtifact(
                    runtime.version,runtime.source_revision,runtime.url,
                    "sha256:"+sha256(payload).hexdigest(),runtime.qualification,
                    "zip",runtime.executable_relative_path,
                )
            )
            with self.assertRaisesRegex(ProviderRuntimeError,"unsafe path"):
                ProviderRuntimeInstaller(Transport(payload)).install(req,self.make_target(Path(d)/"target",req))

    def test_github_one_web_login_fans_out_via_supported_cli_token_bootstrap(self):
        with tempfile.TemporaryDirectory() as d:
            first,payload=requirement("github-cli","ep-one")
            second,_=requirement("github-cli","ep-two")
            installer=ProviderRuntimeInstaller(Transport(payload))
            targets={
                first.key:self.make_target(Path(d)/"one",first),
                second.key:self.make_target(Path(d)/"two",second),
            }
            runner=Runner()
            receipts=ManagedProviderRuntimeCoordinator(
                installer=installer,targets=targets,runner=runner,
            ).execute((first,second))
            self.assertEqual(len(receipts),1)
            self.assertEqual(receipts[0].mechanism,"gh-supported-token-bootstrap")
            web=[c for c in runner.calls if "--web" in c[0]]
            with_token=[c for c in runner.calls if "--with-token" in c[0]]
            self.assertEqual(len(web),1)
            self.assertEqual(len(with_token),1)
            self.assertEqual(with_token[0][2],"gh-secret-token\n")
            self.assertFalse(any("gh-secret-token" in " ".join(c[0]) for c in runner.calls))

    def test_codex_auth_is_per_target_and_never_clones_opaque_auth_state(self):
        with tempfile.TemporaryDirectory() as d:
            first,payload=requirement("codex","forge-one")
            second,_=requirement("codex","forge-two")
            installer=ProviderRuntimeInstaller(Transport(payload))
            targets={
                first.key:self.make_target(Path(d)/"one",first),
                second.key:self.make_target(Path(d)/"two",second),
            }
            runner=Runner()
            receipts=ManagedProviderRuntimeCoordinator(
                installer=installer,targets=targets,runner=runner,
            ).execute((first,second))
            self.assertEqual(len(receipts),2)
            self.assertTrue(all(r.mechanism=="per-target-device-auth" for r in receipts))
            device=[c for c in runner.calls if c[0][1:]==("login","--device-auth")]
            status=[c for c in runner.calls if c[0][1:]==("login","status")]
            self.assertEqual(len(device),2)
            self.assertEqual(len(status),2)
            self.assertTrue(all(c[2] is None for c in runner.calls))

    def test_requirement_without_runtime_or_wrong_target_is_blocked(self):
        with tempfile.TemporaryDirectory() as d:
            req=ProviderRequirement(
                "codex",True,None,"component","forge-runtime","forge-one",None
            )
            target=ProviderRuntimeTarget(
                "codex","forge-runtime","forge-one",Path(d)/"t",Path(d)/"t/runtime",
                Path(d)/"t/runtime/bin/codex",Path(d)/"t/home",Path(d)/"t/config",
            )
            with self.assertRaisesRegex(ProviderRuntimeError,"did not pin"):
                ProviderRuntimeInstaller(Transport(b"x")).install(req,target)


if __name__=="__main__":
    unittest.main()
