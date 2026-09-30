#!/usr/bin/env python3
"""Repack pinned signed provider binaries into the component-owned layout."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import stat
import tarfile
import zipfile


MAXIMUM_ARCHIVE_BYTES = 150 * 1024 * 1024
MAXIMUM_EXECUTABLE_BYTES = 256 * 1024 * 1024
SCHEMA = "forge-platform.provider-runtime-provenance/v1"


class BuildError(ValueError):
    """The exact upstream candidate cannot produce the reviewed bytes."""


def digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def read_exact(path: Path, expected: str, maximum: int) -> bytes:
    details = path.lstat()
    if (not stat.S_ISREG(details.st_mode) or details.st_nlink != 1
        or not 0 < details.st_size <= maximum):
        raise BuildError("upstream input is not one bounded regular file")
    data = path.read_bytes()
    after = path.lstat()
    before_identity = (details.st_dev, details.st_ino, details.st_size, details.st_mtime_ns)
    after_identity = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if before_identity != after_identity:
        raise BuildError("upstream input changed during readback")
    if digest(data) != expected:
        raise BuildError("upstream input digest differs")
    return data


def source_member(archive: bytes, member_name: str, kind: str) -> bytes:
    if kind == "codex":
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
            members = source.getmembers()
            if (len(members) != 1 or members[0].name != member_name
                or not members[0].isfile()
                or members[0].size > MAXIMUM_EXECUTABLE_BYTES):
                raise BuildError("Codex archive layout differs")
            stream = source.extractfile(members[0])
            if stream is None:
                raise BuildError("Codex executable is unavailable")
            binary = stream.read(MAXIMUM_EXECUTABLE_BYTES + 1)
    elif kind == "gh":
        with zipfile.ZipFile(io.BytesIO(archive)) as source:
            matches = [item for item in source.infolist()
                       if item.filename == member_name]
            if (len(matches) != 1 or matches[0].is_dir()
                or matches[0].file_size > MAXIMUM_EXECUTABLE_BYTES):
                raise BuildError("GitHub CLI archive layout differs")
            binary = source.read(matches[0])
    else:
        raise BuildError("provider identity is unsupported")
    if not binary or len(binary) > MAXIMUM_EXECUTABLE_BYTES:
        raise BuildError("provider executable size is invalid")
    return binary


def github_license(archive: bytes) -> bytes:
    with zipfile.ZipFile(io.BytesIO(archive)) as source:
        matches = [item for item in source.infolist()
                   if item.filename == "gh_2.101.0_macOS_arm64/LICENSE"]
        if (len(matches) != 1 or matches[0].is_dir()
            or not 0 < matches[0].file_size <= 128 * 1024):
            raise BuildError("GitHub CLI license layout differs")
        return source.read(matches[0])


def add_member(output: tarfile.TarFile, name: str,
               content: bytes | None, mode: int) -> None:
    member = tarfile.TarInfo(name)
    member.uid = member.gid = member.mtime = 0
    member.uname = member.gname = ""
    member.mode = mode
    if content is None:
        member.type = tarfile.DIRTYPE
        output.addfile(member)
    else:
        member.size = len(content)
        output.addfile(member, io.BytesIO(content))


def repack(binary: bytes, license_bytes: bytes, executable: str) -> bytes:
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0,
                       compresslevel=6) as compressed:
        with tarfile.open(fileobj=compressed, mode="w",
                          format=tarfile.USTAR_FORMAT) as archive:
            add_member(archive, "bin/", None, 0o755)
            add_member(archive, "bin/" + executable, binary, 0o755)
            add_member(archive, "LICENSE", license_bytes, 0o644)
    return output.getvalue()


def load_provenance(path: Path) -> tuple[dict[str, object], bytes]:
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
        raise BuildError("provider provenance is not one regular file")
    raw = path.read_bytes()
    after = path.lstat()
    if (details.st_dev, details.st_ino, details.st_size, details.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise BuildError("provider provenance changed during readback")
    if not raw or len(raw) > 16 * 1024:
        raise BuildError("provider provenance size is invalid")
    try:
        record = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError) as error:
        raise BuildError("provider provenance JSON is invalid") from error
    if (not isinstance(record, dict) or record.get("schema") != SCHEMA
        or not isinstance(record.get("assets"), list)
        or not all(isinstance(item, dict) for item in record["assets"])
        or [item.get("provider") for item in record["assets"]]
            != ["codex", "github-cli"]):
        raise BuildError("provider provenance identity is invalid")
    return record, raw


def build(codex_archive: Path, codex_license: Path, gh_archive: Path,
          provenance: Path, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise BuildError("provider output already exists")
    record, provenance_bytes = load_provenance(provenance)
    codex, gh = record["assets"]
    inputs = [
        (codex, codex_archive, codex_license, "codex-aarch64-apple-darwin", "codex",
         "forge-platform-provider-codex-0.157.1-arm64.tar.gz"),
        (gh, gh_archive, None, "gh_2.101.0_macOS_arm64/bin/gh", "gh",
         "forge-platform-provider-gh-2.101.0-arm64.tar.gz"),
    ]
    prepared = []
    for item, path, license_path, member_name, executable, expected_name in inputs:
        upstream = read_exact(path, item["upstream_archive_sha256"],
                              MAXIMUM_ARCHIVE_BYTES)
        binary = source_member(upstream, member_name, executable)
        if digest(binary) != item["executable_sha256"]:
            raise BuildError("provider executable differs")
        if license_path is None:
            license_bytes = github_license(upstream)
        else:
            license_bytes = read_exact(license_path, item["license_sha256"],
                                       128 * 1024)
        if digest(license_bytes) != item["license_sha256"]:
            raise BuildError("provider license differs")
        if (item["executable_path"] != "bin/" + executable
            or item["normalized_asset"] != expected_name):
            raise BuildError("provider output path differs")
        normalized = repack(binary, license_bytes, executable)
        if (digest(normalized) != item["normalized_sha256"]
            or len(normalized) != item["normalized_size"]):
            raise BuildError("normalized provider archive differs")
        prepared.append((item["normalized_asset"], normalized))
    output.mkdir(mode=0o700)
    for name, content in prepared:
        target = output / name
        with target.open("xb") as stream:
            stream.write(content)
        if read_exact(target, digest(content), MAXIMUM_ARCHIVE_BYTES) != content:
            raise BuildError("written provider archive differs")
    with (output / "provider-runtime-provenance.json").open("xb") as stream:
        stream.write(provenance_bytes)
    if (output / "provider-runtime-provenance.json").read_bytes() != provenance_bytes:
        raise BuildError("written provider provenance differs")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-archive", type=Path, required=True)
    parser.add_argument("--codex-license", type=Path, required=True)
    parser.add_argument("--github-cli-archive", type=Path, required=True)
    parser.add_argument("--provenance", type=Path,
                        default=Path(__file__).resolve().parents[1]
                        / "provider-runtime-provenance.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        build(args.codex_archive, args.codex_license, args.github_cli_archive,
              args.provenance, args.output)
    except (BuildError, OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, f"PROVIDER_RUNTIME_BUILD=BLOCKED reason={error}\n")
    print("PROVIDER_RUNTIME_BUILD=PASS archives=2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
