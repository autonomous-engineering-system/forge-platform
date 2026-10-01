#!/usr/bin/env python3
"""Test exact published managed-Python bytes on an isolated Apple Silicon host."""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path, PurePosixPath
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import HTTPRedirectHandler, Request, build_opener


SCHEMA = "forge-platform.managed-python-test-evidence/v1"
SOURCE_SHA = re.compile(r"^[0-9a-f]{40}$")
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
MAX_EXTRACTED_BYTES = 256 * 1024 * 1024


class QualificationError(ValueError):
    """The published runtime cannot be qualified."""


def digest(raw: bytes) -> str:
    return "sha256:" + sha256(raw).hexdigest()


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def runtime_identity_digest(manifest: dict[str, object], archive_digest: str) -> str:
    """Bind the tested archive to the composition's managed-runtime identity."""
    fields = (
        "implementation", "version", "operating_system", "architecture",
        "minimum_macos_version", "build_variant", "python_tag", "abi_tag",
        "platform_tag", "artifact_kind", "managed_root_identity", "policy_revision",
    )
    try:
        material = {field: manifest[field] for field in fields}
        material["schema"] = "forge-platform.managed-python-runtime/v1"
        material["artifact"] = {"url": manifest["artifact_url"], "digest": archive_digest}
        for role in ("source", "source_provenance", "build_provenance"):
            material[role] = {
                "url": manifest[f"{role}_url"], "digest": manifest[f"{role}_digest"],
            }
    except KeyError as error:
        raise QualificationError("archive runtime identity is incomplete") from error
    return digest(canonical(material).rstrip(b"\n"))


def strict_object(raw: bytes) -> dict[str, object]:
    def pairs(items: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in items:
            if key in result:
                raise QualificationError("duplicate JSON key")
            result[key] = value
        return result

    def reject_constant(value: str) -> object:
        raise QualificationError("non-finite JSON value")

    try:
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=reject_constant)
    except QualificationError:
        raise
    except (UnicodeDecodeError, ValueError) as error:
        raise QualificationError("invalid JSON evidence") from error
    if not isinstance(value, dict):
        raise QualificationError("evidence root must be an object")
    return value


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise QualificationError("published evidence redirected")


def fetch_exact(url: str, expected: str, maximum: int = MAX_ARCHIVE_BYTES) -> bytes:
    if not url.startswith("https://autonomous-engineering-system.github.io/forge-platform/managed-tools/v1/"):
        raise QualificationError("unapproved managed-tool URL")
    with build_opener(NoRedirect()).open(Request(url, headers={"User-Agent": "forge-platform-python-qualification/1"}), timeout=60) as response:
        if response.status != 200 or response.geturl() != url:
            raise QualificationError("published evidence URL changed")
        raw = response.read(maximum + 1)
    if not raw or len(raw) > maximum or digest(raw) != expected:
        raise QualificationError("published evidence bytes differ")
    return raw


def load_inputs(config_path: Path) -> tuple[dict[str, object], bytes, bytes]:
    config = strict_object(config_path.read_bytes())
    if config.get("schema") != "forge-platform.managed-tool-pages/v1":
        raise QualificationError("managed-tool publication schema differs")
    assets = config.get("assets")
    if not isinstance(assets, list):
        raise QualificationError("managed-tool assets are missing")
    by_kind = {entry.get("kind"): entry for entry in assets if isinstance(entry, dict)}
    if len(by_kind) != len(assets):
        raise QualificationError("managed-tool asset kinds are ambiguous")
    try:
        archive_entry = by_kind["managed-python-runtime"]
        build_entry = by_kind["build-provenance"]
        archive = fetch_exact(archive_entry["url"], archive_entry["sha256"])
        build = fetch_exact(build_entry["url"], build_entry["sha256"], 1024 * 1024)
    except (KeyError, TypeError) as error:
        raise QualificationError("managed Python publication is incomplete") from error
    return config, archive, build


def safe_extract(archive: bytes, destination: Path) -> None:
    archive_path = destination / "runtime.tar.gz"
    archive_path.write_bytes(archive)
    root = destination / "runtime"
    root.mkdir()
    try:
        with tarfile.open(archive_path, mode="r:gz") as source:
            members = source.getmembers()
            names: set[str] = set()
            total = 0
            for member in members:
                path = PurePosixPath(member.name)
                normalized = str(path)
                if (
                    path.is_absolute() or any(part in {"", ".", ".."} for part in member.name.rstrip("/").split("/"))
                    or not member.name or normalized in names
                    or not (member.isdir() or member.isfile())
                    or member.mode & 0o6000
                ):
                    raise QualificationError("runtime archive layout is unsafe")
                names.add(normalized)
                total += member.size
                if total > MAX_EXTRACTED_BYTES:
                    raise QualificationError("runtime archive exceeds extraction limit")
            if "bin/python3" not in names or "forge-platform-runtime.json" not in names:
                raise QualificationError("runtime archive is incomplete")
            source.extractall(root, members=members, filter="data")
    except (tarfile.TarError, OSError) as error:
        raise QualificationError("runtime archive cannot be safely extracted") from error


def run_interpreter(executable: Path, args: list[str], *, home: Path) -> str:
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home)}
    try:
        completed = subprocess.run(
            [str(executable), *args], cwd=home, env=env, capture_output=True,
            text=True, check=True, timeout=90,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise QualificationError("managed interpreter qualification failed") from error
    return completed.stdout.strip()


def qualify(archive: bytes, build_raw: bytes, *, source_sha: str,
            expected_archive_digest: str, expected_build_digest: str) -> dict[str, object]:
    if SOURCE_SHA.fullmatch(source_sha) is None:
        raise QualificationError("qualification source must be an exact Git SHA")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise QualificationError("qualification requires native Apple Silicon macOS")
    if digest(archive) != expected_archive_digest or digest(build_raw) != expected_build_digest:
        raise QualificationError("input digest differs from reviewed publication")
    build = strict_object(build_raw)
    if build.get("schema") != "forge-platform.managed-tool-build-provenance/v1" or build.get("version") != "3.14.7":
        raise QualificationError("build provenance identity differs")
    output = build.get("outputs")
    if not isinstance(output, dict) or output.get("entrypoint") != "bin/python3":
        raise QualificationError("build provenance entrypoint differs")
    with tempfile.TemporaryDirectory(prefix="managed-python-qualification-") as temporary:
        root = Path(temporary)
        safe_extract(archive, root)
        runtime = root / "runtime"
        manifest = strict_object((runtime / "forge-platform-runtime.json").read_bytes())
        if (
            manifest.get("schema") != "forge-platform.managed-python-runtime-archive-manifest/v1"
            or manifest.get("version") != build["version"]
            or manifest.get("build_provenance_digest") != expected_build_digest
            or manifest.get("interpreter_relative_path") != "bin/python3"
        ):
            raise QualificationError("archive manifest differs from build provenance")
        identity_digest = runtime_identity_digest(manifest, expected_archive_digest)
        executable = runtime / "bin/python3"
        executable_digest = digest(executable.read_bytes())
        if executable_digest != output.get("entrypoint_digest"):
            raise QualificationError("interpreter bytes differ from build provenance")
        probe = run_interpreter(executable, ["-I", "-S", "-c", (
            "import json,platform,ssl,sqlite3,lzma,zlib,ctypes,sys;"
            "print(json.dumps({'version':list(sys.version_info[:3]),"
            "'machine':platform.machine(),'ssl':ssl.OPENSSL_VERSION.split()[0],"
            "'sqlite':sqlite3.sqlite_version,'lzma':bool(lzma.LZMACompressor),"
            "'zlib':bool(zlib.compress),'ctypes':bool(ctypes.CDLL)}))"
        )], home=root)
        result = strict_object(probe.encode())
        if result.get("version") != [3, 14, 7] or result.get("machine") != "arm64" or any(
            not result.get(name) for name in ("ssl", "sqlite", "lzma", "zlib", "ctypes")
        ):
            raise QualificationError("interpreter module probe differs")
        venv = root / "isolated-venv"
        run_interpreter(executable, ["-I", "-m", "venv", str(venv)], home=root)
        venv_python = venv / "bin/python3"
        venv_probe = run_interpreter(venv_python, ["-I", "-c", (
            "import json,sys,pip; print(json.dumps({'isolated':sys.prefix!=sys.base_prefix,"
            "'pip':bool(pip.__version__)}))"
        )], home=root)
        if strict_object(venv_probe.encode()) != {"isolated": True, "pip": True}:
            raise QualificationError("isolated venv or bundled pip is unavailable")
    return {
        "schema": SCHEMA,
        "source_sha": source_sha,
        "archive_digest": expected_archive_digest,
        "runtime_identity_digest": identity_digest,
        "build_provenance_digest": expected_build_digest,
        "interpreter_digest": executable_digest,
        "host": {"os": "macos", "architecture": "arm64", "version": platform.mac_ver()[0]},
        "checks": {"archive_layout": "PASS", "interpreter_modules": "PASS", "isolated_venv_pip": "PASS"},
        "outcome": "PASS",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        config, archive, build = load_inputs(args.config)
        assets = {entry["kind"]: entry for entry in config["assets"]}
        report = qualify(
            archive, build, source_sha=args.source_sha,
            expected_archive_digest=assets["managed-python-runtime"]["sha256"],
            expected_build_digest=assets["build-provenance"]["sha256"],
        )
        args.output.write_bytes(canonical(report))
    except (OSError, QualificationError) as error:
        print(f"MANAGED_PYTHON_QUALIFICATION=FAIL {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"MANAGED_PYTHON_QUALIFICATION=PASS report_digest={digest(canonical(report))}")


if __name__ == "__main__":
    main()
