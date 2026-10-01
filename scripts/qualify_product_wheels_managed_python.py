#!/usr/bin/env python3
"""Qualify exact released product wheels on exact public managed Python bytes.

This is installed-wheel/CLI compatibility evidence. It does not create a
product instance, authenticate a provider, start a service, or prove readiness.
"""
from __future__ import annotations

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.qualify_managed_python_runtime import (  # noqa: E402
    canonical, digest, load_inputs, runtime_identity_digest, safe_extract, strict_object,
)

SCHEMA = "forge-platform.product-managed-python-test-evidence/v1"
INPUT_SCHEMA = "forge-platform.product-managed-python-qualification-inputs/v1"
SOURCE_SHA = re.compile(r"^[0-9a-f]{40}$")
WHEEL_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
PRODUCTS = {
    "engineering-platform-server": ("engineering-platform", "engineering-platform-system-provisioner"),
    "forge-runtime": ("forge-autonomy", "forge"),
}
MAX_WHEEL_BYTES = 64 * 1024 * 1024


class QualificationError(ValueError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise QualificationError("product wheel URL redirected")


def load_config(path: Path) -> dict[str, object]:
    value = strict_object(path.read_bytes())
    if set(value) != {"schema", "runtime_identity_digest", "products"} or value["schema"] != INPUT_SCHEMA:
        raise QualificationError("product qualification inputs are invalid")
    if not isinstance(value["runtime_identity_digest"], str) or not WHEEL_DIGEST.fullmatch(value["runtime_identity_digest"]):
        raise QualificationError("managed Python identity is invalid")
    products = value["products"]
    if not isinstance(products, list) or len(products) != len(PRODUCTS):
        raise QualificationError("exact product set is required")
    identities = []
    for item in products:
        if not isinstance(item, dict) or set(item) != {"identity", "version", "source_revision", "wheel"}:
            raise QualificationError("product input fields are invalid")
        identity = item["identity"]
        identities.append(identity)
        wheel = item["wheel"]
        if (identity not in PRODUCTS or not isinstance(item["version"], str)
                or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", item["version"])
                or not isinstance(item["source_revision"], str)
                or not SOURCE_SHA.fullmatch(item["source_revision"])
                or not isinstance(wheel, dict) or set(wheel) != {"url", "digest"}
                or not isinstance(wheel["url"], str)
                or not wheel["url"].startswith("https://files.pythonhosted.org/packages/")
                or not wheel["url"].endswith(".whl")
                or not isinstance(wheel["digest"], str)
                or not WHEEL_DIGEST.fullmatch(wheel["digest"])):
            raise QualificationError("product wheel identity is invalid")
    if identities != sorted(PRODUCTS):
        raise QualificationError("product input order or identity is ambiguous")
    return value


def fetch_wheel(url: str, expected_digest: str) -> bytes:
    if not url.startswith("https://files.pythonhosted.org/packages/") or not url.endswith(".whl"):
        raise QualificationError("product wheel host is unsupported")
    with build_opener(NoRedirect()).open(Request(url, headers={"User-Agent": "forge-platform-product-qualification/1"}), timeout=60) as response:
        if response.status != 200 or response.geturl() != url:
            raise QualificationError("product wheel URL changed")
        raw = response.read(MAX_WHEEL_BYTES + 1)
    if not raw or len(raw) > MAX_WHEEL_BYTES or digest(raw) != expected_digest:
        raise QualificationError("published product wheel bytes differ")
    return raw


def run(argv: list[str], *, home: Path) -> str:
    env = {
        "PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home),
        "CODEX_HOME": str(home / "codex"), "GH_CONFIG_DIR": str(home / "gh"),
        "PYTHONNOUSERSITE": "1", "PIP_CONFIG_FILE": os.devnull,
    }
    try:
        completed = subprocess.run(argv, cwd=home, env=env, text=True, capture_output=True, timeout=90, check=True)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise QualificationError("isolated product wheel qualification failed") from error
    if completed.stderr:
        raise QualificationError("isolated product wheel emitted diagnostics")
    return completed.stdout.strip()


def qualify(config: dict[str, object], archive: bytes, wheels: dict[str, bytes], *, source_sha: str) -> dict[str, object]:
    if not SOURCE_SHA.fullmatch(source_sha):
        raise QualificationError("qualification requires exact source SHA")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise QualificationError("qualification requires native Apple Silicon macOS")
    archive_digest = digest(archive)
    if config["runtime_identity_digest"] != runtime_identity_digest_from_archive(archive, archive_digest):
        raise QualificationError("managed Python identity differs")
    results = []
    with tempfile.TemporaryDirectory(prefix="forge-platform-product-managed-python-") as temporary:
        root = Path(temporary)
        safe_extract(archive, root)
        python = root / "runtime/bin/python3"
        for item in config["products"]:
            identity = item["identity"]
            wheel_identity = item["wheel"]
            raw = wheels[identity]
            if not raw or len(raw) > MAX_WHEEL_BYTES or digest(raw) != wheel_identity["digest"]:
                raise QualificationError("product wheel bytes differ")
            home = root / f"home-{identity}"
            home.mkdir(mode=0o700)
            wheel_path = home / Path(wheel_identity["url"]).name
            wheel_path.write_bytes(raw)
            venv = root / f"venv-{identity}"
            run([str(python), "-m", "venv", str(venv)], home=home)
            interpreter = venv / "bin/python3"
            run([str(interpreter), "-m", "pip", "install", "--no-index", "--no-deps", str(wheel_path)], home=home)
            distribution, cli = PRODUCTS[identity]
            installed = run([str(interpreter), "-I", "-c", f"import importlib.metadata as m; print(m.version({distribution!r}))"], home=home)
            if installed != item["version"]:
                raise QualificationError("installed product version differs")
            help_text = run([str(venv / "bin" / cli), "--help"], home=home)
            if not help_text:
                raise QualificationError("product CLI help is empty")
            results.append({
                "identity": identity, "version": installed,
                "source_revision": item["source_revision"],
                "wheel_digest": wheel_identity["digest"],
                "venv_install": "PASS", "metadata_readback": "PASS", "cli_help": "PASS",
            })
    return {
        "schema": SCHEMA, "source_sha": source_sha, "outcome": "PASS",
        "qualification": "EXACT_RELEASED_WHEELS_MANAGED_PYTHON_CLI_SMOKE_V1",
        "runtime_identity_digest": config["runtime_identity_digest"],
        "runtime_archive_digest": archive_digest, "products": results,
    }


def runtime_identity_digest_from_archive(archive: bytes, archive_digest: str) -> str:
    import io
    import tarfile
    try:
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
            member = source.extractfile("forge-platform-runtime.json")
            if member is None:
                raise QualificationError("runtime identity member missing")
            manifest = strict_object(member.read(64 * 1024))
    except (OSError, tarfile.TarError, KeyError) as error:
        raise QualificationError("runtime identity member unreadable") from error
    return runtime_identity_digest(manifest, archive_digest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "product-runtime-qualification-inputs.json")
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    config = load_config(args.config)
    _, archive, _ = load_inputs(ROOT / "managed-tool-pages.json")
    wheels = {item["identity"]: fetch_wheel(item["wheel"]["url"], item["wheel"]["digest"])
              for item in config["products"]}
    report = qualify(config, archive, wheels, source_sha=args.source_sha)
    args.output.write_bytes(canonical(report))
    print("PRODUCT_MANAGED_PYTHON_QUALIFICATION=PASS")


if __name__ == "__main__":
    main()
