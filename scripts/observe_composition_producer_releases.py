#!/usr/bin/env python3
"""Observe public producer releases without promoting a composition.

The observer is deliberately read-only. It verifies terminal public producer
receipts and registry readback, then emits one canonical readiness report. A
missing release or explicitly unconfigured platform input is a normal BLOCKED
result. Malformed, drifting, or digest-inconsistent public evidence is an error.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import sys
from typing import Callable, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


SCHEMA = "forge-platform.composition-producer-observation/v1"
CONFIG_SCHEMA = "forge-platform.composition-producer-sources/v1"
MAXIMUM_DOCUMENT_BYTES = 1024 * 1024
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
IDENTITY = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
Fetcher = Callable[[str], bytes]


class ObservationError(ValueError):
    """Producer evidence cannot be safely interpreted."""


class PublicEvidenceNotFound(ObservationError):
    """One requested public evidence document does not exist."""


class NoPublicRelease(ObservationError):
    """The configured producer has no public release yet."""


def _pairs(values: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in values:
        if not isinstance(key, str) or key in result:
            raise ObservationError("JSON contains duplicate or invalid keys")
        result[key] = value
    return result


def _reject_constant(value: str) -> object:
    raise ObservationError(f"JSON contains non-finite number {value}")


def _strict_json(raw: bytes, label: str) -> Mapping[str, object]:
    if not raw or len(raw) > MAXIMUM_DOCUMENT_BYTES:
        raise ObservationError(f"{label} exceeds the document boundary")
    try:
        value = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=_reject_constant
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ObservationError(f"{label} is not strict UTF-8 JSON") from error
    if not isinstance(value, Mapping):
        raise ObservationError(f"{label} root must be an object")
    return value


def _canonical(value: Mapping[str, object]) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
        + "\n"
    ).encode("utf-8")


def _digest(raw: bytes) -> str:
    return "sha256:" + sha256(raw).hexdigest()


def _network_fetch(url: str) -> bytes:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "forge-platform-observer/1"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = f"Bearer {token}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    try:
        with urlopen(Request(url, headers=headers), timeout=30) as response:
            raw = response.read(MAXIMUM_DOCUMENT_BYTES + 1)
    except HTTPError as error:
        if error.code == 404:
            raise PublicEvidenceNotFound("public evidence does not exist") from error
        raise ObservationError(f"HTTP {error.code} while reading public evidence") from error
    except (URLError, TimeoutError) as error:
        raise ObservationError("public evidence transport failed") from error
    if len(raw) > MAXIMUM_DOCUMENT_BYTES:
        raise ObservationError("public evidence exceeds the document boundary")
    return raw


def _require_https(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value.isascii()
        or any(ord(character) < 0x21 for character in value)
    ):
        raise ObservationError(f"{label} must be canonical HTTPS")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise ObservationError(f"{label} must be canonical HTTPS") from error
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 443}
        or parsed.fragment
        or "\\" in value
        or parsed.geturl() != value
    ):
        raise ObservationError(f"{label} must be canonical HTTPS")
    return value


def _require_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        raise ObservationError(f"{label} must be SHA-256")
    return value


def _require_timestamp(value: str) -> str:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ObservationError("observed_at must be canonical UTC")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise ObservationError("observed_at must be canonical UTC") from error
    if parsed.tzinfo != timezone.utc or parsed.microsecond or parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ObservationError("observed_at must be canonical UTC")
    return value


def _producer_config(value: object) -> Mapping[str, object]:
    expected = {
        "identity", "repository", "tag_prefix", "receipt_asset_prefix", "product",
        "component", "registry", "pypi_project", "composition_eligible",
    }
    if not isinstance(value, Mapping) or set(value) != expected:
        raise ObservationError("producer configuration fields are invalid")
    for key in ("identity", "tag_prefix", "receipt_asset_prefix", "product", "component"):
        item = value[key]
        if not isinstance(item, str) or not item:
            raise ObservationError(f"producer {key} is invalid")
    if IDENTITY.fullmatch(str(value["identity"])) is None:
        raise ObservationError("producer identity is invalid")
    if REPOSITORY.fullmatch(str(value["repository"])) is None:
        raise ObservationError("producer repository is invalid")
    if value["registry"] not in {"pypi", "github-release"}:
        raise ObservationError("producer registry is invalid")
    if type(value["composition_eligible"]) is not bool:
        raise ObservationError("producer composition eligibility is invalid")
    project = value["pypi_project"]
    if (value["registry"] == "pypi") != isinstance(project, str) or isinstance(project, str) and not project:
        raise ObservationError("producer PyPI project does not match its registry")
    return value


def _load_config(path: Path) -> tuple[bytes, list[Mapping[str, object]], list[Mapping[str, object]]]:
    if path.is_symlink() or not path.is_file():
        raise ObservationError("producer configuration must be a regular file")
    raw = path.read_bytes()
    value = _strict_json(raw, "producer configuration")
    if set(value) != {"schema", "producers", "external_inputs"} or value["schema"] != CONFIG_SCHEMA:
        raise ObservationError("producer configuration schema or fields are invalid")
    producers_value = value["producers"]
    external_value = value["external_inputs"]
    if not isinstance(producers_value, list) or not producers_value:
        raise ObservationError("producer configuration requires producers")
    producers = [_producer_config(item) for item in producers_value]
    identities = [str(item["identity"]) for item in producers]
    if identities != sorted(identities) or len(set(identities)) != len(identities):
        raise ObservationError("producer identities must be unique and sorted")
    if not isinstance(external_value, list):
        raise ObservationError("external input configuration is invalid")
    external = [_external_config(item) for item in external_value]
    external_ids = [str(item["identity"]) for item in external]
    if external_ids != sorted(external_ids) or len(set(external_ids)) != len(external_ids):
        raise ObservationError("external input identities must be unique and sorted")
    return raw, producers, external


def _external_config(value: object) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != {"identity", "status", "evidence"}:
        raise ObservationError("external input fields are invalid")
    identity = value["identity"]
    if not isinstance(identity, str) or IDENTITY.fullmatch(identity) is None:
        raise ObservationError("external input identity is invalid")
    status = value["status"]
    evidence = value["evidence"]
    if status == "UNCONFIGURED" and evidence is None:
        return value
    if status != "READY" or not isinstance(evidence, Mapping):
        raise ObservationError("external input status/evidence is invalid")
    if set(evidence) != {"identity_digest", "artifacts"}:
        raise ObservationError("external input evidence fields are invalid")
    _require_digest(evidence["identity_digest"], "external input identity digest")
    artifacts = evidence["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise ObservationError("external input evidence requires artifacts")
    kinds: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, Mapping) or set(artifact) != {"kind", "url", "digest"}:
            raise ObservationError("external input artifact fields are invalid")
        kind = artifact["kind"]
        if not isinstance(kind, str) or IDENTITY.fullmatch(kind) is None:
            raise ObservationError("external input artifact kind is invalid")
        kinds.append(kind)
        _require_https(artifact["url"], "external input artifact URL")
        _require_digest(artifact["digest"], "external input artifact digest")
    if kinds != sorted(kinds) or len(set(kinds)) != len(kinds):
        raise ObservationError("external input artifact kinds must be unique and sorted")
    return value


def _release_identity(producer: Mapping[str, object], release: Mapping[str, object]) -> tuple[str, str]:
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ObservationError("latest producer release is not a public stable release")
    tag = release.get("tag_name")
    prefix = str(producer["tag_prefix"])
    if not isinstance(tag, str) or not tag.startswith(prefix):
        raise ObservationError("producer release tag does not match its configured prefix")
    version = tag[len(prefix):]
    if SEMVER.fullmatch(version) is None:
        raise ObservationError("producer release version is not semantic")
    source = release.get("target_commitish")
    if not isinstance(source, str) or REVISION.fullmatch(source) is None:
        raise ObservationError("producer release target is not one exact Git SHA")
    return version, source


def _receipt_asset(
    producer: Mapping[str, object], release: Mapping[str, object], version: str, source: str
) -> tuple[str, str, str]:
    name = f'{producer["receipt_asset_prefix"]}{version}-{source}.json'
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ObservationError("producer release assets are invalid")
    matches = [item for item in assets if isinstance(item, Mapping) and item.get("name") == name]
    if len(matches) != 1:
        raise ObservationError("producer release lacks one exact terminal receipt")
    asset = matches[0]
    digest = _require_digest(asset.get("digest"), "producer receipt asset digest")
    url = _require_https(asset.get("browser_download_url"), "producer receipt asset URL")
    expected = f'https://github.com/{producer["repository"]}/releases/download/{release["tag_name"]}/{name}'
    if url != expected:
        raise ObservationError("producer receipt asset URL is not canonical")
    return name, url, digest


def _common_receipt(
    producer: Mapping[str, object], receipt: Mapping[str, object], version: str, source: str
) -> None:
    for field, expected in (
        ("product", producer["product"]), ("component", producer["component"]),
        ("version", version), ("source_revision", source), ("state", "RELEASE_COMPLETE"),
    ):
        if receipt.get(field) != expected:
            raise ObservationError(f"producer receipt {field} does not bind the release")
    if not isinstance(receipt.get("operation_id"), str) or not receipt["operation_id"]:
        raise ObservationError("producer receipt operation identity is invalid")
    if not isinstance(receipt.get("policy_revision"), str) or not receipt["policy_revision"]:
        raise ObservationError("producer receipt policy is invalid")
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, Mapping) or not artifacts:
        raise ObservationError("producer receipt artifacts are invalid")
    for digest in artifacts.values():
        _require_digest(digest, "producer artifact digest")
    qualification = receipt.get("qualification")
    if not isinstance(qualification, Mapping) or qualification.get("exact_main_sha") != source:
        raise ObservationError("producer qualification does not bind exact main")
    publication = receipt.get("publication_receipt")
    if not isinstance(publication, Mapping) or publication.get("readback") != "PASS":
        raise ObservationError("producer publication readback did not pass")
    if publication.get("registry") != producer["registry"]:
        raise ObservationError("producer publication registry is invalid")
    cleanup = receipt.get("cleanup")
    if not isinstance(cleanup, Mapping) or cleanup.get("result") != "COMPLETE":
        raise ObservationError("producer cleanup is not complete")


def _pypi_artifacts(
    producer: Mapping[str, object], receipt: Mapping[str, object], version: str, fetch: Fetcher
) -> list[Mapping[str, object]]:
    artifacts = receipt["artifacts"]
    if set(artifacts) != {"wheel", "sdist"}:
        raise ObservationError("PyPI producer must bind wheel and sdist")
    project = str(producer["pypi_project"])
    document = _strict_json(
        fetch(f"https://pypi.org/pypi/{quote(project, safe='')}/{quote(version, safe='')}/json"),
        "PyPI release",
    )
    info = document.get("info")
    urls = document.get("urls")
    expected_project = re.sub(r"[-_.]+", "-", project).lower()
    observed_project = info.get("name") if isinstance(info, Mapping) else None
    if (
        not isinstance(observed_project, str)
        or re.sub(r"[-_.]+", "-", observed_project).lower() != expected_project
        or info.get("version") != version
        or not isinstance(urls, list)
    ):
        raise ObservationError("PyPI release identity is invalid")
    expected = {"bdist_wheel": artifacts["wheel"], "sdist": artifacts["sdist"]}
    observed: list[Mapping[str, object]] = []
    publication = receipt["publication_receipt"]
    readback = publication.get("observed_artifact_digests")
    if not isinstance(readback, Mapping):
        raise ObservationError("PyPI producer lacks artifact readback")
    for kind, digest in expected.items():
        matches = []
        for item in urls:
            if not isinstance(item, Mapping) or item.get("packagetype") != kind:
                continue
            digests = item.get("digests")
            if isinstance(digests, Mapping) and f'sha256:{digests.get("sha256")}' == digest:
                matches.append(item)
        if len(matches) != 1:
            raise ObservationError("PyPI artifact digest is absent or ambiguous")
        item = matches[0]
        filename = item.get("filename")
        url = _require_https(item.get("url"), "PyPI artifact URL")
        if not isinstance(filename, str) or Path(filename).name != filename or readback.get(filename) != digest:
            raise ObservationError("PyPI artifact readback does not bind the registry file")
        observed.append({"kind": kind, "filename": filename, "url": url, "digest": digest})
    return sorted(observed, key=lambda item: str(item["kind"]))


def _github_source_bundle(
    producer: Mapping[str, object], receipt: Mapping[str, object], release: Mapping[str, object]
) -> list[Mapping[str, object]]:
    artifacts = receipt["artifacts"]
    publication = receipt["publication_receipt"]
    if (
        set(artifacts) != {"source_bundle"}
        or publication.get("source_revision") != receipt["source_revision"]
        or publication.get("tag") != release.get("tag_name")
        or publication.get("observed_artifact_digests") != {"source_bundle": artifacts["source_bundle"]}
    ):
        raise ObservationError("Workspace source-bundle receipt is invalid")
    name = publication.get("artifact_name")
    digest = artifacts["source_bundle"]
    assets = release.get("assets")
    matches = [item for item in assets if isinstance(item, Mapping) and item.get("name") == name]
    if not isinstance(name, str) or len(matches) != 1:
        raise ObservationError("Workspace source bundle is absent or ambiguous")
    asset = matches[0]
    if asset.get("digest") != digest:
        raise ObservationError("Workspace source bundle digest drifted")
    url = _require_https(asset.get("browser_download_url"), "Workspace source bundle URL")
    return [{"kind": "source-bundle", "filename": name, "url": url, "digest": digest}]


def _observe_producer(producer: Mapping[str, object], fetch: Fetcher) -> Mapping[str, object]:
    repository = str(producer["repository"])
    try:
        release_raw = fetch(f"https://api.github.com/repos/{repository}/releases/latest")
    except PublicEvidenceNotFound as error:
        raise NoPublicRelease("producer has no public release") from error
    release = _strict_json(release_raw, "GitHub latest release")
    version, source = _release_identity(producer, release)
    receipt_name, receipt_url, receipt_digest = _receipt_asset(producer, release, version, source)
    receipt_raw = fetch(receipt_url)
    if _digest(receipt_raw) != receipt_digest:
        raise ObservationError("producer receipt bytes do not match the GitHub asset digest")
    receipt = _strict_json(receipt_raw, "producer terminal receipt")
    _common_receipt(producer, receipt, version, source)
    if producer["registry"] == "pypi":
        artifacts = _pypi_artifacts(producer, receipt, version, fetch)
    else:
        artifacts = _github_source_bundle(producer, receipt, release)
    eligible = bool(producer["composition_eligible"])
    release_url = _require_https(release.get("html_url"), "producer release URL")
    if release_url != f'https://github.com/{repository}/releases/tag/{release["tag_name"]}':
        raise ObservationError("producer release URL is not canonical")
    return {
        "identity": producer["identity"],
        "repository": repository,
        "release_tag": release["tag_name"],
        "release_url": release_url,
        "version": version,
        "source_revision": source,
        "receipt": {"asset_name": receipt_name, "url": receipt_url, "digest": receipt_digest},
        "artifacts": artifacts,
        "status": "READY" if eligible else "OBSERVED_NOT_INSTALLABLE",
    }


def _observe_external(value: Mapping[str, object], fetch: Fetcher) -> Mapping[str, object]:
    if value["status"] == "UNCONFIGURED":
        return {"identity": value["identity"], "status": "UNCONFIGURED"}
    evidence = value["evidence"]
    assert isinstance(evidence, Mapping)
    artifacts = evidence["artifacts"]
    assert isinstance(artifacts, list)
    for artifact in artifacts:
        assert isinstance(artifact, Mapping)
        raw = fetch(str(artifact["url"]))
        if _digest(raw) != artifact["digest"]:
            raise ObservationError(f'external input {value["identity"]} artifact digest drifted')
    return {
        "identity": value["identity"],
        "status": "READY",
        "identity_digest": evidence["identity_digest"],
        "artifacts": artifacts,
    }


def observe(*, config_path: Path, observed_at: str, fetch: Fetcher = _network_fetch) -> Mapping[str, object]:
    observed_at = _require_timestamp(observed_at)
    config_raw, producers, external = _load_config(config_path)
    observations: list[Mapping[str, object]] = []
    blockers: list[str] = []
    for producer in producers:
        try:
            observation = _observe_producer(producer, fetch)
        except NoPublicRelease:
            observation = {
                "identity": producer["identity"],
                "repository": producer["repository"],
                "status": "NO_PUBLIC_RELEASE",
            }
        observations.append(observation)
        if observation["status"] != "READY":
            blockers.append(f'{producer["identity"]}:{observation["status"]}')
    external_observations = [_observe_external(item, fetch) for item in external]
    for item in external_observations:
        if item["status"] != "READY":
            blockers.append(f'{item["identity"]}:{item["status"]}')
    report: dict[str, object] = {
        "schema": SCHEMA,
        "observed_at": observed_at,
        "configuration_digest": _digest(config_raw),
        "producer_observations": observations,
        "external_input_observations": external_observations,
        "blockers": sorted(blockers),
        "manifest_generation": "READY_FOR_REVIEW" if not blockers else "BLOCKED",
        "status": "READY" if not blockers else "BLOCKED",
    }
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path("composition-producer-sources.json"))
    parser.add_argument("--observed-at", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        report = observe(config_path=args.config, observed_at=args.observed_at)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(_canonical(report))
    except (ObservationError, OSError) as error:
        print(f"COMPOSITION_PRODUCER_OBSERVATION=FAIL reason={error}", file=sys.stderr)
        return 1
    print(
        "COMPOSITION_PRODUCER_OBSERVATION=" + str(report["status"])
        + " manifest_generation=" + str(report["manifest_generation"])
        + " blockers=" + str(len(report["blockers"]))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
