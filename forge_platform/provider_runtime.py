"""Installer-owned provider runtime installation and authentication.

Composition/v2 pins exact Codex/GitHub CLI archives. This module owns their
credential-free acquisition and isolated target installation; product adapters
still own product registration/readiness. Ambient PATH/Homebrew tools are never
installation authority.

Authentication deliberately uses only provider-supported CLI surfaces:
* Codex: per-target device auth; no opaque auth-file copying.
* GitHub CLI: one web login may fan out through `gh auth token` plus the
  documented `gh auth login --with-token` command. The token exists only in
  process memory/stdin and never enters receipts/logs.

Target roots are supplied by the owning product/deployment adapter and must be
absolute, private, and non-overlapping.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile
import tempfile
from typing import Mapping, Protocol, Sequence
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError
import zipfile

from .provider_fanout import ProviderFanoutReceipt, ProviderTargetReceipt
from .universal_installer import ProviderReadback, ProviderRequirement, ProviderRuntimeArtifact, SemanticVersion


_MAX_ARCHIVE_BYTES = 1024 * 1024 * 1024
_MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024
_DESCRIPTOR = "provider-runtime.json"


class ProviderRuntimeError(RuntimeError):
    """Provider runtime/auth state cannot be installed or verified safely."""


@dataclass(frozen=True)
class ProviderRuntimeTarget:
    provider: str
    owner_component: str
    target_identity: str
    target_root: Path
    runtime_root: Path
    executable: Path
    home: Path
    config_home: Path

    def __post_init__(self) -> None:
        if self.provider not in {"codex", "github-cli"}:
            raise ValueError("provider runtime target identity is unsupported")
        if not self.owner_component or not self.target_identity:
            raise ValueError("provider runtime target owner/identity are required")
        paths=(self.target_root,self.runtime_root,self.executable,self.home,self.config_home)
        if any(not isinstance(p,Path) or not p.is_absolute() for p in paths):
            raise ValueError("provider runtime target paths must be absolute")
        root=self.target_root.resolve(strict=False)
        for p in paths[1:]:
            resolved=p.resolve(strict=False)
            if resolved == root or not resolved.is_relative_to(root):
                raise ValueError("provider runtime target path escaped target_root")
        if self.executable.resolve(strict=False) == self.runtime_root.resolve(strict=False):
            raise ValueError("provider runtime executable cannot equal runtime_root")

    @property
    def key(self) -> str:
        return f"{self.provider}:{self.owner_component}:{self.target_identity}"


@dataclass(frozen=True)
class ProviderDownloadReceipt:
    requested_url: str
    final_url: str
    digest: str
    byte_count: int

    def __post_init__(self) -> None:
        if self.requested_url != self.final_url:
            raise ValueError("provider runtime download redirected")
        if not self.digest.startswith("sha256:") or len(self.digest) != 71:
            raise ValueError("provider runtime download digest is invalid")
        if self.byte_count < 0:
            raise ValueError("provider runtime download byte_count is invalid")


class ProviderArtifactTransport(Protocol):
    def fetch(self, artifact: ProviderRuntimeArtifact, destination: Path) -> ProviderDownloadReceipt: ...


class _NoRedirect(urllib_request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        raise HTTPError(req.full_url, code, "redirect denied", headers, fp)


class HTTPSProviderArtifactTransport:
    """Bounded exact-URL HTTPS download with no credentials/cookies/redirects."""

    def fetch(self, artifact: ProviderRuntimeArtifact, destination: Path) -> ProviderDownloadReceipt:
        if not isinstance(artifact,ProviderRuntimeArtifact):
            raise ValueError("provider runtime artifact is required")
        destination.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        opener=urllib_request.build_opener(_NoRedirect)
        request=urllib_request.Request(
            artifact.url,
            headers={"Accept":"application/octet-stream","User-Agent":"ForgePlatformInstaller/managed-provider-runtime"},
        )
        total=0
        digest=sha256()
        try:
            with opener.open(request,timeout=30) as response, destination.open("xb") as output:
                final_url=response.geturl()
                if final_url != artifact.url:
                    raise ProviderRuntimeError("provider runtime download redirected")
                length=response.headers.get("Content-Length")
                if length is not None and int(length) > _MAX_ARCHIVE_BYTES:
                    raise ProviderRuntimeError("provider runtime archive exceeds size limit")
                while True:
                    block=response.read(1024*1024)
                    if not block:
                        break
                    total += len(block)
                    if total > _MAX_ARCHIVE_BYTES:
                        raise ProviderRuntimeError("provider runtime archive exceeds size limit")
                    digest.update(block)
                    output.write(block)
                output.flush()
                os.fsync(output.fileno())
        except (OSError,HTTPError,URLError,ValueError) as error:
            destination.unlink(missing_ok=True)
            if isinstance(error,ProviderRuntimeError):
                raise
            raise ProviderRuntimeError("provider runtime download failed") from error
        actual="sha256:"+digest.hexdigest()
        if actual != artifact.digest:
            destination.unlink(missing_ok=True)
            raise ProviderRuntimeError("provider runtime digest mismatch")
        return ProviderDownloadReceipt(artifact.url,artifact.url,actual,total)


@dataclass(frozen=True)
class ProviderProcessResult:
    returncode: int
    stdout: str
    stderr: str


class ProviderProcessRunner(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        environment: Mapping[str,str],
        input_text: str | None = None,
    ) -> ProviderProcessResult: ...


class SubprocessProviderProcessRunner:
    def run(self, argv, *, environment, input_text=None):
        if not argv or not Path(argv[0]).is_absolute():
            raise ProviderRuntimeError("provider command executable must be absolute")
        result=subprocess.run(
            tuple(argv),
            text=True,
            input=input_text,
            capture_output=True,
            check=False,
            env=dict(environment),
        )
        return ProviderProcessResult(result.returncode,result.stdout,result.stderr)


def _secure_directory(path: Path) -> None:
    path.mkdir(parents=True,exist_ok=True,mode=0o700)
    os.chmod(path,0o700)


def _safe_member(name: str) -> PurePosixPath:
    path=PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(part in {"",".."} for part in path.parts):
        raise ProviderRuntimeError("provider runtime archive contains unsafe path")
    return path


def _extract_zip(archive: Path, destination: Path) -> None:
    total=0
    with zipfile.ZipFile(archive) as zf:
        for entry in zf.infolist():
            rel=_safe_member(entry.filename.rstrip("/"))
            mode=(entry.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise ProviderRuntimeError("provider runtime archive contains symlink")
            total += entry.file_size
            if total > _MAX_EXTRACTED_BYTES:
                raise ProviderRuntimeError("provider runtime archive expands beyond limit")
            target=destination.joinpath(*rel.parts)
            if entry.is_dir():
                _secure_directory(target)
                continue
            target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            with zf.open(entry) as source, target.open("xb") as output:
                shutil.copyfileobj(source,output,1024*1024)
            permissions=(entry.external_attr >> 16) & 0o777
            os.chmod(target,permissions or 0o600)


def _extract_tar_gzip(archive: Path, destination: Path) -> None:
    total=0
    with tarfile.open(archive,"r:gz") as tf:
        for entry in tf.getmembers():
            rel=_safe_member(entry.name.rstrip("/"))
            if entry.issym() or entry.islnk() or entry.isdev() or entry.isfifo():
                raise ProviderRuntimeError("provider runtime archive contains unsupported link/device")
            if not entry.isdir() and not entry.isfile():
                raise ProviderRuntimeError("provider runtime archive contains unsupported entry")
            total += max(entry.size,0)
            if total > _MAX_EXTRACTED_BYTES:
                raise ProviderRuntimeError("provider runtime archive expands beyond limit")
            target=destination.joinpath(*rel.parts)
            if entry.isdir():
                _secure_directory(target)
                continue
            target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            source=tf.extractfile(entry)
            if source is None:
                raise ProviderRuntimeError("provider runtime archive file is unreadable")
            with source, target.open("xb") as output:
                shutil.copyfileobj(source,output,1024*1024)
            os.chmod(target,entry.mode & 0o777 or 0o600)


class ProviderRuntimeInstaller:
    def __init__(self, transport: ProviderArtifactTransport | None = None) -> None:
        self.transport=transport or HTTPSProviderArtifactTransport()

    def install(self, requirement: ProviderRequirement, target: ProviderRuntimeTarget) -> ProviderReadback:
        if not isinstance(requirement,ProviderRequirement) or requirement.runtime is None:
            raise ProviderRuntimeError("composition did not pin provider runtime bytes")
        if requirement.key != target.key:
            raise ProviderRuntimeError("provider runtime target changed")
        runtime=requirement.runtime
        runtime.verify_provider_identity(requirement.identity)
        self._validate_target(target,runtime)

        descriptor=target.runtime_root / _DESCRIPTOR
        if descriptor.exists():
            return self._readback(requirement,target)

        target.target_root.parent.mkdir(parents=True,exist_ok=True)
        _secure_directory(target.target_root)
        _secure_directory(target.home)
        if target.config_home != target.home:
            _secure_directory(target.config_home)

        staging=Path(tempfile.mkdtemp(prefix=".provider-runtime-",dir=target.target_root))
        try:
            archive=staging / "runtime.archive"
            receipt=self.transport.fetch(runtime,archive)
            extracted=staging / "extracted"
            extracted.mkdir(mode=0o700)
            if runtime.archive_format == "zip":
                _extract_zip(archive,extracted)
            elif runtime.archive_format == "tar-gzip":
                _extract_tar_gzip(archive,extracted)
            else:
                raise ProviderRuntimeError("provider runtime archive format is unsupported")

            staged_executable=extracted.joinpath(*PurePosixPath(runtime.executable_relative_path).parts)
            if staged_executable.is_symlink() or not staged_executable.is_file():
                raise ProviderRuntimeError("provider runtime executable is missing")
            executable_digest="sha256:"+sha256(staged_executable.read_bytes()).hexdigest()
            mode=staged_executable.stat().st_mode
            if mode & 0o111 == 0:
                os.chmod(staged_executable,(mode & 0o777) | 0o500)

            expected_parent=target.executable.relative_to(target.runtime_root)
            actual_parent=Path(*PurePosixPath(runtime.executable_relative_path).parts)
            if expected_parent != actual_parent:
                raise ProviderRuntimeError("provider target executable path conflicts with signed runtime")

            payload={
                "schema":"forge-platform.provider-runtime/v1",
                "provider":requirement.identity,
                "owner_component":requirement.owner_component,
                "target_identity":requirement.target_identity,
                "version":str(runtime.version),
                "source_revision":runtime.source_revision,
                "archive_digest":receipt.digest,
                "qualification":runtime.qualification,
                "archive_format":runtime.archive_format,
                "executable_relative_path":runtime.executable_relative_path,
                "executable_sha256":executable_digest,
            }
            tmp_descriptor=extracted / _DESCRIPTOR
            tmp_descriptor.write_text(json.dumps(payload,sort_keys=True,separators=(",",":"))+"\n",encoding="utf-8")
            os.chmod(tmp_descriptor,0o600)

            if target.runtime_root.exists():
                raise ProviderRuntimeError("provider runtime target appeared during installation")
            os.replace(extracted,target.runtime_root)
            return self._readback(requirement,target)
        finally:
            shutil.rmtree(staging,ignore_errors=True)

    def _validate_target(self,target: ProviderRuntimeTarget,runtime: ProviderRuntimeArtifact) -> None:
        if target.provider not in {"codex","github-cli"}:
            raise ProviderRuntimeError("provider target is unsupported")
        expected_name="codex" if target.provider=="codex" else "gh"
        if target.executable.name != expected_name and not (target.provider=="codex" and target.executable.name.startswith("codex-")):
            raise ProviderRuntimeError("provider target executable name is invalid")
        if PurePosixPath(runtime.executable_relative_path).name != target.executable.name:
            raise ProviderRuntimeError("provider runtime executable name changed")

    def _readback(self,requirement: ProviderRequirement,target: ProviderRuntimeTarget) -> ProviderReadback:
        runtime=requirement.runtime
        assert runtime is not None
        descriptor=target.runtime_root / _DESCRIPTOR
        try:
            data=json.loads(descriptor.read_text(encoding="utf-8"))
        except (OSError,json.JSONDecodeError) as error:
            raise ProviderRuntimeError("provider runtime descriptor is unavailable") from error
        expected={
            "schema":"forge-platform.provider-runtime/v1",
            "provider":requirement.identity,
            "owner_component":requirement.owner_component,
            "target_identity":requirement.target_identity,
            "version":str(runtime.version),
            "source_revision":runtime.source_revision,
            "archive_digest":runtime.digest,
            "qualification":runtime.qualification,
            "archive_format":runtime.archive_format,
            "executable_relative_path":runtime.executable_relative_path,
        }
        if any(data.get(k)!=v for k,v in expected.items()):
            raise ProviderRuntimeError("provider runtime descriptor identity mismatch")
        if target.executable.is_symlink() or not target.executable.is_file() or target.executable.stat().st_mode & 0o111 == 0:
            raise ProviderRuntimeError("provider runtime executable is unavailable")
        actual="sha256:"+sha256(target.executable.read_bytes()).hexdigest()
        if data.get("executable_sha256") != actual:
            raise ProviderRuntimeError("provider runtime executable was substituted")
        return ProviderReadback(
            requirement.identity,
            "AUTHENTICATION_REQUIRED",
            runtime.version,
            actual,
            "provider-runtime:"+sha256(descriptor.read_bytes()).hexdigest(),
            requirement.owner_component,
            requirement.target_identity,
        )


class ManagedProviderRuntimeCoordinator:
    """Install exact provider runtimes, authenticate, then independently verify."""

    def __init__(
        self,
        *,
        installer: ProviderRuntimeInstaller,
        targets: Mapping[str,ProviderRuntimeTarget],
        runner: ProviderProcessRunner | None = None,
    ) -> None:
        self.installer=installer
        self.targets=dict(targets)
        self.runner=runner or SubprocessProviderProcessRunner()

    def execute(self, requirements: Sequence[ProviderRequirement]) -> tuple[ProviderFanoutReceipt,...]:
        by_provider: dict[str,list[ProviderRequirement]]={}
        for requirement in requirements:
            if not isinstance(requirement,ProviderRequirement) or requirement.runtime is None:
                raise ProviderRuntimeError("provider requirement lacks exact runtime")
            target=self.targets.get(requirement.key)
            if target is None:
                raise ProviderRuntimeError("provider target layout is unavailable")
            self.installer.install(requirement,target)
            by_provider.setdefault(requirement.identity,[]).append(requirement)

        receipts:list[ProviderFanoutReceipt]=[]
        for provider,group in sorted(by_provider.items()):
            group=sorted(group,key=lambda x:x.key)
            if provider=="github-cli":
                receipts.append(self._github(group))
            elif provider=="codex":
                receipts.extend(self._codex(group))
            else:
                raise ProviderRuntimeError("provider auth strategy is unavailable")
        return tuple(receipts)

    def _environment(self,target: ProviderRuntimeTarget) -> dict[str,str]:
        base={
            "PATH":f"{target.executable.parent}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME":str(target.home),
        }
        if target.provider=="codex":
            base["CODEX_HOME"]=str(target.config_home)
        else:
            base["GH_CONFIG_DIR"]=str(target.config_home)
            base["GH_HOST"]="github.com"
        return base

    def _codex(self,group: Sequence[ProviderRequirement]) -> list[ProviderFanoutReceipt]:
        result=[]
        for index,requirement in enumerate(group,1):
            target=self.targets[requirement.key]
            env=self._environment(target)
            login=self.runner.run(
                (str(target.executable),"login","--device-auth"),
                environment=env,
            )
            if login.returncode:
                raise ProviderRuntimeError("Codex device authentication failed")
            status=self.runner.run(
                (str(target.executable),"login","status"),
                environment=env,
            )
            if status.returncode:
                raise ProviderRuntimeError("Codex target authentication did not verify")
            readback=self.installer._readback(requirement,target)
            verified=ProviderReadback(
                readback.identity,"VERIFIED",readback.version,readback.executable_identity,
                "provider-auth:"+sha256(f"{requirement.key}:codex-status".encode()).hexdigest(),
                readback.owner_component,readback.target_identity,
            )
            target_receipt=ProviderTargetReceipt(
                requirement.key,"codex",f"codex-target-{index}",
                verified.evidence_reference,verified.executable_identity or "",str(verified.version),
            )
            result.append(ProviderFanoutReceipt("codex",f"codex-target-{index}","per-target-device-auth",(target_receipt,)))
        return result

    def _github(self,group: Sequence[ProviderRequirement]) -> ProviderFanoutReceipt:
        first=group[0]
        first_target=self.targets[first.key]
        env=self._environment(first_target)
        login=self.runner.run(
            (
                str(first_target.executable),"auth","login","--web",
                "--hostname","github.com","--git-protocol","https",
                "--skip-ssh-key","--insecure-storage",
            ),
            environment=env,
        )
        if login.returncode:
            raise ProviderRuntimeError("GitHub web authentication failed")
        token_result=self.runner.run(
            (str(first_target.executable),"auth","token","--hostname","github.com"),
            environment=env,
        )
        token=token_result.stdout.strip()
        if token_result.returncode or not token or "\n" in token or "\r" in token:
            raise ProviderRuntimeError("GitHub bootstrap token could not be obtained")

        ceremony="github-web-fanout"
        target_receipts=[]
        try:
            for requirement in group:
                target=self.targets[requirement.key]
                target_env=self._environment(target)
                if requirement.key != first.key:
                    provision=self.runner.run(
                        (
                            str(target.executable),"auth","login","--with-token",
                            "--hostname","github.com","--git-protocol","https",
                            "--skip-ssh-key","--insecure-storage",
                        ),
                        environment=target_env,
                        input_text=token+"\n",
                    )
                    if provision.returncode:
                        raise ProviderRuntimeError("GitHub target bootstrap failed")
                status=self.runner.run(
                    (str(target.executable),"auth","status","--active","--hostname","github.com"),
                    environment=target_env,
                )
                if status.returncode:
                    raise ProviderRuntimeError("GitHub target authentication did not verify")
                rb=self.installer._readback(requirement,target)
                evidence="provider-auth:"+sha256(f"{requirement.key}:github-status".encode()).hexdigest()
                target_receipts.append(ProviderTargetReceipt(
                    requirement.key,"github-cli",ceremony,evidence,
                    rb.executable_identity or "",str(rb.version),
                ))
        finally:
            token=""  # Drop our only Python-level reference; never persist/log.
        return ProviderFanoutReceipt("github-cli",ceremony,"gh-supported-token-bootstrap",tuple(target_receipts))
