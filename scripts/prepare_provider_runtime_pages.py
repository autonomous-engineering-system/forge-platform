#!/usr/bin/env python3
"""Stage reviewed provider archives while preserving exact public managed tools."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.prepare_managed_tool_pages import (
    DIGEST, PublicationError, SITE_PREFIX as TOOL_PREFIX, _digest,
    load_config as load_tool_config, stage as stage_tools,
    validate_backing_release, validate_release_tag_binding,
)


SCHEMA = "forge-platform.provider-runtime-pages/v1"
PREFIX = "https://autonomous-engineering-system.github.io/forge-platform/provider-runtimes/v1/"
KINDS = {
    "codex-runtime": re.compile(
        r"codex-[0-9]+\.[0-9]+\.[0-9]+-arm64/forge-platform-provider-codex-"
        r"[0-9]+\.[0-9]+\.[0-9]+-arm64\.tar\.gz"
    ),
    "github-cli-runtime": re.compile(
        r"github-cli-[0-9]+\.[0-9]+\.[0-9]+-arm64/forge-platform-provider-gh-"
        r"[0-9]+\.[0-9]+\.[0-9]+-arm64\.tar\.gz"
    ),
    "provider-provenance": re.compile(r"provider-runtime-provenance\.json"),
}
MAXIMUM_ASSET_BYTES = 256 * 1024 * 1024
MAXIMUM_SITE_BYTES = 1_000_000_000


def load_config(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise PublicationError("provider configuration is not a regular file")
    raw = path.read_bytes()
    if not raw or len(raw) > 64 * 1024:
        raise PublicationError("provider configuration size is invalid")
    try:
        config = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique)
    except (UnicodeError, ValueError) as error:
        raise PublicationError("provider configuration is not strict JSON") from error
    if (not isinstance(config, dict)
        or set(config) != {"schema", "status", "release_tag",
                              "preserved_managed_tool_tag",
                              "preserved_managed_tool_marker_sha256",
                              "preserved_managed_tool_marker_size", "assets"}
        or config["schema"] != SCHEMA
        or config["status"] != "REVIEWED_CANDIDATE"
        or not isinstance(config["release_tag"], str)
        or re.fullmatch(r"forge-platform-provider-runtimes-v[1-9][0-9]*",
                        config["release_tag"]) is None
        or not isinstance(config["preserved_managed_tool_tag"], str)
        or not isinstance(config["preserved_managed_tool_marker_sha256"], str)
        or DIGEST.fullmatch(config["preserved_managed_tool_marker_sha256"]) is None
        or type(config["preserved_managed_tool_marker_size"]) is not int
        or not 0 < config["preserved_managed_tool_marker_size"] <= 4096):
        raise PublicationError("provider configuration identity is invalid")
    assets = config["assets"]
    if not isinstance(assets, list) or len(assets) != len(KINDS):
        raise PublicationError("provider asset set is incomplete")
    seen: set[str] = set()
    names: set[str] = set()
    total = 0
    for asset in assets:
        if not isinstance(asset, dict) or set(asset) != {
            "kind", "asset_name", "relative_path", "url", "sha256", "size",
        }:
            raise PublicationError("provider asset fields are invalid")
        kind, relative = asset["kind"], asset["relative_path"]
        if (not isinstance(kind, str) or kind not in KINDS or kind in seen
            or not isinstance(relative, str)
            or KINDS[kind].fullmatch(relative) is None
            or not isinstance(asset["asset_name"], str)
            or asset["asset_name"] != Path(relative).name
            or asset["asset_name"] in names
            or asset["url"] != PREFIX + relative
            or not isinstance(asset["sha256"], str)
            or DIGEST.fullmatch(asset["sha256"]) is None
            or type(asset["size"]) is not int
            or not 0 < asset["size"] <= MAXIMUM_ASSET_BYTES):
            raise PublicationError("provider asset identity is invalid")
        seen.add(kind)
        names.add(asset["asset_name"])
        total += asset["size"]
    if seen != KINDS.keys() or total > MAXIMUM_SITE_BYTES:
        raise PublicationError("provider asset boundary is invalid")
    for kind, prefix in (("codex-runtime", "codex-"),
                         ("github-cli-runtime", "github-cli-")):
        asset = next(item for item in assets if item["kind"] == kind)
        root = asset["relative_path"].split("/")[0]
        version = root[len(prefix):-len("-arm64")]
        if version not in asset["asset_name"]:
            raise PublicationError("provider archive version differs")
    return config


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise PublicationError("duplicate provider JSON key")
        result[key] = value
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise PublicationError("public Pages URL redirected")


def fetch_exact(url: str, expected_size: int, digest: str, destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        raise PublicationError("preserved asset destination already exists")
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(urllib.request.Request(url), timeout=60) as response:
            if response.status != 200 or response.geturl() != url:
                raise PublicationError("preserved public asset identity differs")
            length = response.headers.get("Content-Length")
            if length is not None and length != str(expected_size):
                raise PublicationError("preserved public asset length differs")
            hasher = hashlib.sha256()
            count = 0
            with destination.open("xb") as output:
                while chunk := response.read(1024 * 1024):
                    count += len(chunk)
                    if count > expected_size:
                        raise PublicationError("preserved public asset exceeds limit")
                    hasher.update(chunk)
                    output.write(chunk)
            if count != expected_size or "sha256:" + hasher.hexdigest() != digest:
                raise PublicationError("preserved public asset bytes differ")
    except (urllib.error.URLError, TimeoutError) as error:
        raise PublicationError("preserved public asset unavailable") from error


def stage(config: dict[str, object], tool_config: dict[str, object],
          provider_assets: Path, output: Path, source_sha: str,
          run_id: int, run_attempt: int) -> None:
    if (config["preserved_managed_tool_tag"] != tool_config["release_tag"]
        or provider_assets.is_symlink() or not provider_assets.is_dir()
        or output.exists() or output.is_symlink()
        or re.fullmatch(r"[0-9a-f]{40}", source_sha) is None
        or type(run_id) is not int or run_id <= 0
        or type(run_attempt) is not int or run_attempt <= 0):
        raise PublicationError("provider publication context is invalid")
    with tempfile.TemporaryDirectory(prefix="forge-provider-preserve-") as temporary:
        preserved = Path(temporary)
        for asset in tool_config["assets"]:
            fetch_exact(asset["url"], asset["size"], asset["sha256"],
                        preserved / asset["asset_name"])
        stage_tools(tool_config, preserved, output)
        marker = output / "managed-tools/v1/publication.json"
        fetch_exact(TOOL_PREFIX + "publication.json",
                    config["preserved_managed_tool_marker_size"],
                    config["preserved_managed_tool_marker_sha256"], marker)
        git = next(asset for asset in tool_config["assets"]
                   if asset["kind"] == "managed-git-runtime")
        index = output / "managed-tools/v1" / git["relative_path"].split("/")[0] / "index.html"
        with tempfile.TemporaryDirectory(prefix="forge-provider-index-") as index_dir:
            public_index = Path(index_dir) / "index.html"
            fetch_exact(TOOL_PREFIX + git["relative_path"].split("/")[0] + "/index.html",
                        index.stat().st_size,
                        "sha256:" + hashlib.sha256(index.read_bytes()).hexdigest(),
                        public_index)
            if public_index.read_bytes() != index.read_bytes():
                raise PublicationError("preserved Git source index differs")
    for asset in config["assets"]:
        source = provider_assets / asset["asset_name"]
        if _digest(source, asset["size"]) != asset["sha256"]:
            raise PublicationError("provider release asset differs")
        target = output / "provider-runtimes/v1" / asset["relative_path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if _digest(target, asset["size"]) != asset["sha256"]:
            raise PublicationError("staged provider bytes differ")
    publication = {
        "schema": "forge-platform.provider-runtime-pages-publication/v1",
        "source_sha": source_sha,
        "release_tag": config["release_tag"],
        "preserved_managed_tool_tag": tool_config["release_tag"],
        "preserved_managed_tool_marker_sha256":
            config["preserved_managed_tool_marker_sha256"],
        "assets": [{"kind": asset["kind"], "sha256": asset["sha256"]}
                   for asset in config["assets"]],
        "github_run_id": run_id,
        "github_run_attempt": run_attempt,
    }
    (output / "provider-runtimes/v1/publication.json").write_text(
        json.dumps(publication, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--tool-config", type=Path, required=True)
    parser.add_argument("--provider-assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    args = parser.parse_args()
    try:
        stage(load_config(args.config), load_tool_config(args.tool_config),
              args.provider_assets, args.output, args.source_sha,
              args.run_id, args.run_attempt)
    except (PublicationError, OSError) as error:
        parser.exit(1, f"PROVIDER_RUNTIME_PAGES=BLOCKED reason={error}\n")
    print("PROVIDER_RUNTIME_PAGES=STAGED assets=3 preserved_tools=6")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
