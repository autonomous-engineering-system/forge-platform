#!/usr/bin/env python3
"""Stage exact reviewed managed-tool bytes for a protected Pages deployment."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat


SCHEMA = "forge-platform.managed-tool-pages/v1"
SITE_PREFIX = "https://autonomous-engineering-system.github.io/forge-platform/managed-tools/v1/"
KIND_PATHS = {
    "managed-git-runtime": re.compile(
        r"git-[0-9]+\.[0-9]+\.[0-9]+-arm64/forge-platform-managed-git\.tar\.gz"
    ),
    "managed-python-runtime": re.compile(
        r"python-[0-9]+\.[0-9]+\.[0-9]+-arm64/forge-platform-managed-python-runtime\.tar\.gz"
    ),
    "cpython-source": re.compile(
        r"python-[0-9]+\.[0-9]+\.[0-9]+-arm64/cpython-[0-9]+\.[0-9]+\.[0-9]+-source\.tar\.gz"
    ),
    "source-provenance": re.compile(
        r"python-[0-9]+\.[0-9]+\.[0-9]+-arm64/source-provenance\.json"
    ),
    "build-provenance": re.compile(
        r"python-[0-9]+\.[0-9]+\.[0-9]+-arm64/build-provenance\.json"
    ),
    "git-corresponding-source": re.compile(
        r"git-[0-9]+\.[0-9]+\.[0-9]+-arm64/git-corresponding-source\.tar\.gz"
    ),
}
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
TAG = re.compile(r"forge-platform-managed-tools-v[1-9][0-9]*")
MAXIMUM_DOCUMENT_BYTES = 64 * 1024
MAXIMUM_ASSET_BYTES = 500 * 1024 * 1024
MAXIMUM_SITE_BYTES = 1_000_000_000


class PublicationError(ValueError):
    """The candidate cannot be published without changing reviewed evidence."""


def _pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise PublicationError("duplicate or invalid JSON key")
        result[key] = value
    return result


def load_config(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise PublicationError("configuration must be a regular file")
    raw = path.read_bytes()
    if not raw or len(raw) > MAXIMUM_DOCUMENT_BYTES:
        raise PublicationError("configuration size is invalid")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PublicationError("configuration is not strict UTF-8 JSON") from error
    if not isinstance(value, dict) or set(value) != {
        "schema", "status", "release_tag", "handoff_manifest_sha256", "assets",
    } or value["schema"] != SCHEMA:
        raise PublicationError("configuration schema or fields are invalid")
    if value["status"] == "UNCONFIGURED":
        if (value["release_tag"] is None
            and value["handoff_manifest_sha256"] is None
            and value["assets"] == []):
            raise PublicationError("managed-tool publication is unconfigured")
        raise PublicationError("unconfigured state contains asset claims")
    if (value["status"] != "REVIEWED_CANDIDATE"
        or not isinstance(value["release_tag"], str)
        or TAG.fullmatch(value["release_tag"]) is None):
        raise PublicationError("release tag or status is invalid")
    if (not isinstance(value["handoff_manifest_sha256"], str)
        or DIGEST.fullmatch(value["handoff_manifest_sha256"]) is None):
        raise PublicationError("handoff inventory digest is invalid")
    assets = value["assets"]
    if not isinstance(assets, list) or len(assets) != len(KIND_PATHS):
        raise PublicationError("the five consumer assets and Git source asset are required")
    kinds: set[str] = set()
    paths: set[str] = set()
    names: set[str] = set()
    total = 0
    for asset in assets:
        if not isinstance(asset, dict) or set(asset) != {
            "kind", "asset_name", "relative_path", "url", "sha256", "size",
        }:
            raise PublicationError("asset fields are invalid")
        kind = asset["kind"]
        name = asset["asset_name"]
        relative = asset["relative_path"]
        digest = asset["sha256"]
        size = asset["size"]
        if not isinstance(kind, str) or kind not in KIND_PATHS or kind in kinds:
            raise PublicationError("asset kind is missing or duplicated")
        if (not isinstance(relative, str)
            or KIND_PATHS[kind].fullmatch(relative) is None
            or relative in paths):
            raise PublicationError("asset path is missing or duplicated")
        if not isinstance(name, str) or name != Path(relative).name or name in names:
            raise PublicationError("release asset name is invalid")
        if asset["url"] != SITE_PREFIX + relative:
            raise PublicationError("consumer URL differs from exact Pages path")
        if not isinstance(digest, str) or DIGEST.fullmatch(digest) is None:
            raise PublicationError("asset digest is invalid")
        if type(size) is not int or not 0 < size <= MAXIMUM_ASSET_BYTES:
            raise PublicationError("asset size is invalid")
        total += size
        kinds.add(kind)
        paths.add(relative)
        names.add(name)
    if kinds != KIND_PATHS.keys() or total > MAXIMUM_SITE_BYTES:
        raise PublicationError("consumer asset set exceeds the Pages boundary")
    by_kind = {asset["kind"]: asset for asset in assets}
    git_root = str(by_kind["managed-git-runtime"]["relative_path"]).split("/")[0]
    source_root = str(by_kind["git-corresponding-source"]["relative_path"]).split("/")[0]
    python_root = str(by_kind["managed-python-runtime"]["relative_path"]).split("/")[0]
    if git_root != source_root or any(
        str(by_kind[kind]["relative_path"]).split("/")[0] != python_root
        for kind in ("cpython-source", "source-provenance", "build-provenance")
    ):
        raise PublicationError("source and runtime versions differ")
    python_version = python_root[len("python-"):-len("-arm64")]
    if str(by_kind["cpython-source"]["asset_name"]) != f"cpython-{python_version}-source.tar.gz":
        raise PublicationError("CPython source version differs from runtime")
    return value


def validate_backing_release(
    config: dict[str, object], release: object, source_sha: str, release_id: int
) -> bool:
    """Return draft state after checking one exact same-repository release."""
    if (not isinstance(release, dict)
        or re.fullmatch(r"[0-9a-f]{40}", source_sha) is None
        or type(release_id) is not int or release_id <= 0
        or type(release.get("id")) is not int or release["id"] != release_id
        or release.get("tag_name") != config["release_tag"]
        or release.get("target_commitish") != source_sha
        or type(release.get("draft")) is not bool
        or release.get("prerelease") is not False
        or (release["draft"] is True and release.get("published_at") is not None)
        or (release["draft"] is False and not release.get("published_at"))):
        raise PublicationError("backing release identity or visibility differs")
    assets = release.get("assets")
    if not isinstance(assets, list) or not all(isinstance(a, dict) for a in assets):
        raise PublicationError("backing release asset metadata is invalid")
    names = [a.get("name") for a in assets]
    if (any(not isinstance(name, str) for name in names)
        or len(set(names)) != len(names)
        or len(names) != len(config["assets"])):
        raise PublicationError("backing release asset names are ambiguous")
    by_name = {a["name"]: a for a in assets}
    for expected in config["assets"]:
        actual = by_name.get(expected["asset_name"])
        if (actual is None or actual.get("state") != "uploaded"
            or type(actual.get("size")) is not int
            or actual["size"] != expected["size"]
            or actual.get("digest") not in (None, expected["sha256"])):
            raise PublicationError("backing release asset differs from reviewed candidate")
    return release["draft"]


def validate_release_tag_binding(draft: bool, tag_sha: str | None, source_sha: str) -> None:
    """A draft may lack a Git ref; a public release must have the exact ref."""
    if (type(draft) is not bool
        or re.fullmatch(r"[0-9a-f]{40}", source_sha) is None
        or (tag_sha is not None and tag_sha != source_sha)
        or (not draft and tag_sha is None)):
        raise PublicationError("backing release tag does not bind exact source")


def _digest(path: Path, expected_size: int) -> str:
    details = path.lstat()
    if (not stat.S_ISREG(details.st_mode) or details.st_nlink != 1
        or details.st_size != expected_size):
        raise PublicationError("asset is not one exact regular file")
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    after = path.lstat()
    if (after.st_dev, after.st_ino, after.st_mode, after.st_nlink,
        after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (
        details.st_dev, details.st_ino, details.st_mode, details.st_nlink,
        details.st_size, details.st_mtime_ns, details.st_ctime_ns,
    ):
        raise PublicationError("asset changed during readback")
    return "sha256:" + hasher.hexdigest()


def stage(config: dict[str, object], assets_root: Path, output: Path) -> None:
    if (assets_root.is_symlink() or not assets_root.is_dir()
        or output.exists() or output.is_symlink()):
        raise PublicationError("asset or output root is invalid")
    assets = config["assets"]
    assert isinstance(assets, list)
    for asset in assets:
        assert isinstance(asset, dict)
        source = assets_root / str(asset["asset_name"])
        if _digest(source, int(asset["size"])) != asset["sha256"]:
            raise PublicationError("release asset digest differs from reviewed input")
    output.mkdir(mode=0o700)
    (output / ".nojekyll").write_bytes(b"")
    for asset in assets:
        assert isinstance(asset, dict)
        destination = output / "managed-tools" / "v1" / str(asset["relative_path"])
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(assets_root / str(asset["asset_name"]), destination)
        if _digest(destination, int(asset["size"])) != asset["sha256"]:
            raise PublicationError("staged Pages bytes differ from reviewed input")
        if _digest(assets_root / str(asset["asset_name"]), int(asset["size"])) != asset["sha256"]:
            raise PublicationError("release asset changed during staging")
    git = next(asset for asset in assets if asset["kind"] == "managed-git-runtime")
    source = next(asset for asset in assets if asset["kind"] == "git-corresponding-source")
    git_directory = str(git["relative_path"]).split("/")[0]
    version = git_directory[len("git-"):-len("-arm64")]
    index = output / "managed-tools" / "v1" / git_directory / "index.html"
    index.write_text(
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">"
        f"<title>Forge Platform managed Git {version}</title>"
        f"<h1>Forge Platform managed Git {version}</h1>"
        f"<p><a href=\"{git['asset_name']}\">Managed Git binary archive</a> "
        f"{git['sha256']}</p>"
        f"<p><a href=\"{source['asset_name']}\">Complete corresponding source, "
        f"dispatcher and build recipes</a> {source['sha256']}</p>"
        "<p>The source archive includes the Git GPL-2.0 license and the exact "
        "custom dispatcher source. Both files are available here without credentials.</p>"
        "</html>\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--assets-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        stage(config, args.assets_root, args.output)
    except (PublicationError, OSError) as error:
        parser.exit(1, f"MANAGED_TOOL_PAGES=BLOCKED reason={error}\n")
    print(f"MANAGED_TOOL_PAGES=STAGED assets={len(config['assets'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
