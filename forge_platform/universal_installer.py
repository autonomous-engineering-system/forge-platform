"""Fail-closed planning primitives for the Forge Platform macOS installer.

The native installer is a separately versioned Forge Platform product.  This
module is its platform-neutral policy kernel: it accepts only verified
installer-release metadata, immutable composition inputs and product-owned
readbacks.  It deliberately does *not* install an artifact, write a product
database, choose a runtime from ``PATH``, register a service, or handle a
provider credential.

Product provisioners retain ownership of those mutations.  A SwiftUI shell or
a future privileged helper can use the plans below only after it has supplied
the required product-owned evidence and has passed every gate.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
import base64
import binascii
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Iterable, Iterator, Mapping, Protocol, Sequence
from urllib.parse import urlsplit, urlunsplit

from .component_operations import (
    COMPONENT_IDENTITIES,
    ArtifactCorrelation,
    ProductInstallationReadback,
    ProductUpdateAssessment,
    QualifiedArtifact,
)
from .composition_identity import require_composition_identity
from .macos_platform_contract import (
    INSTALLER_ARCHITECTURE,
    INSTALLER_ARCHITECTURES,
    MINIMUM_MACOS_MAJOR,
    MINIMUM_MACOS_SEMANTIC_VERSION,
)


INSTALLER_RELEASE_SCHEMA = "forge-platform.installer-release/v1"
COMPOSITION_CATALOG_SCHEMA = "forge-platform.composition-catalog/v1"
COMPOSITION_SCHEMA = "forge-platform.composition/v1"
COMPOSITION_SCHEMA_V2 = "forge-platform.composition/v2"
COMPOSITION_SCHEMAS = frozenset({COMPOSITION_SCHEMA, COMPOSITION_SCHEMA_V2})
INSTALLER_CHANNELS = frozenset({"stable", "candidate"})
SUPPORTED_MACOS_ARCHITECTURES = INSTALLER_ARCHITECTURES
# Host observations retain Intel as an explicit negative input so preflight can
# produce bounded denial evidence rather than failing before the gate runs.
OBSERVABLE_MACOS_ARCHITECTURES = frozenset({"arm64", "x86_64"})
MANAGED_TOOL_IDENTITIES = frozenset({"git"})
MANAGED_PYTHON_RUNTIME_SCHEMA = "forge-platform.managed-python-runtime/v1"
MANAGED_PYTHON_IMPLEMENTATION = "cpython"
MANAGED_PYTHON_OPERATING_SYSTEM = "macos"
MANAGED_PYTHON_ARCHITECTURE = "arm64"
MANAGED_PYTHON_BUILD_VARIANT = "standard-gil"
MANAGED_PYTHON_ARTIFACT_KIND = "forge-platform-managed-python-runtime-archive-v1"
MANAGED_PYTHON_ROOT_IDENTITY = "forge-platform-managed-python-v1"
PROVIDER_IDENTITIES = frozenset({"codex", "github-cli"})
PROVIDER_CREDENTIAL_SCOPES = frozenset({"user", "component"})
PROVIDER_OWNER_COMPONENTS = frozenset({
    "forge-runtime", "engineering-platform-server", "engineering-platform-project-agent",
})
PROVIDER_STATES = frozenset({"ABSENT", "INSTALLED", "AUTHENTICATION_REQUIRED", "VERIFIED", "FAILED"})
TOOL_STATES = frozenset({"ABSENT", "ACTIVE", "UNKNOWN"})
SERVICE_COMPONENTS = frozenset({"forge-runtime", "workspace-server", "engineering-platform-server"})
LOCAL_COMPONENTS = frozenset({"workspace-client", "engineering-platform-project-agent"})
DIFF_ACTIONS = frozenset({"INSTALL", "UPDATE", "REPAIR", "REMOVE", "NO_CHANGE", "BLOCKED"})
REMOVAL_SUPPORT_STATES = frozenset({"SUPPORTED", "UNSUPPORTED", "UNKNOWN"})
MAXIMUM_CANONICAL_HTTPS_URL_LENGTH = 2048
MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES = 128 * 1024
# The native outer-catalog verifier admits at most this many raw UTF-8 bytes
# before strict parsing. Keeping the policy kernel on the same bound prevents a
# Python qualifier from accepting a catalog the released macOS installer must
# reject before any component selection or product action.
MAXIMUM_COMPOSITION_CATALOG_BYTES = 512 * 1024
MAXIMUM_COMPOSITION_CATALOG_JSON_NESTING_DEPTH = 64
MAXIMUM_COMPOSITION_CATALOG_JSON_NODES = 16_384

_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_RAW_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_SOURCE_REVISION = re.compile(r"^[0-9a-f]{40,64}$")
_CAPABILITY = re.compile(r"^[a-z0-9][a-z0-9./_-]{0,127}$")
_POLICY_REVISION = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
# All signed installer/catalog time fields use one deliberately narrow RFC3339
# profile.  Keeping it UTC and whole-second avoids platform parser
# normalisation (for example invalid calendar dates) and fractional precision
# loss across the Python qualifier and native macOS verifier.
_CANONICAL_RFC3339_UTC = re.compile(
    r"^(?P<year>[0-9]{4})-(?P<month>[0-9]{2})-(?P<day>[0-9]{2})"
    r"T(?P<hour>[0-9]{2}):(?P<minute>[0-9]{2}):(?P<second>[0-9]{2})Z$"
)
# Each path segment begins alphanumerically, so a signed identity can never
# produce a dot segment such as ``owner/..`` after GitHub URL derivation.
_GITHUB_REPOSITORY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
_GITHUB_RELEASE_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_GITHUB_DESCRIPTOR_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,122}\.json$")
_GITHUB_ARCHIVE_ASSET_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,123}\.zip$")
_BUNDLE_IDENTIFIER = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
_TEAM_IDENTIFIER = re.compile(r"^[A-Z0-9]{10}$")
_MAXIMUM_NATIVE_SIGNED_INTEGER = (1 << 63) - 1
_MAXIMUM_RELEASE_SEQUENCE = (1 << 64) - 1
_SAFE_OPERATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_SIGNING_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
# An Ed25519 signature is exactly 64 raw bytes, encoded as unpadded base64url.
# Keeping its textual representation fixed avoids accepting semantically equal
# but differently encoded signed metadata.
_ED25519_SIGNATURE = re.compile(r"^[A-Za-z0-9_-]{86}$")
_JOURNAL_FORBIDDEN_KEY_FRAGMENTS = frozenset({
    "access_token", "authorization", "credential", "cookie", "password", "private_key", "secret", "token",
})
_OPAQUE_JOURNAL_REFERENCE = re.compile(r"^receipt:[a-z0-9][a-z0-9._-]{0,127}$")
_SAFE_TARGET_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_PYTHON_TAG = re.compile(r"^cp[0-9]{2,3}$")
_PYTHON_PLATFORM_TAG = re.compile(r"^macosx_26_0_arm64$")
# A composition identity is publication metadata, not a display label. Keep
# Unicode non-whitespace identifiers possible, but prohibit controls and all
# whitespace so its exact identity remains unambiguous across the schema,
# Python qualifier and native macOS verifier.
_CANONICAL_HTTPS_AUTHORITY = re.compile(r"^[A-Za-z0-9._:\[\]-]+$")
_CANONICAL_HTTPS_PATH_OR_QUERY = re.compile(r"^[A-Za-z0-9._~!$&'()*+,;=:@%/?-]*$")
_PERCENT_ESCAPE = re.compile(r"%[0-9A-Fa-f]{2}")


class UniversalInstallerError(RuntimeError):
    """Raised when untrusted, incomplete, or incompatible installer input appears."""


def _required(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} is required")
    return value


def _composition_catalog_id(value: object, label: str) -> str:
    return require_composition_identity(value, label)


def _mapping(value: object, expected: frozenset[str], label: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != expected:
        raise ValueError(f"{label} fields are invalid")
    return value


def _sequence(value: object, label: str) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value <= 0
        or value > _MAXIMUM_RELEASE_SEQUENCE
    ):
        raise ValueError(f"{label} must be a positive UInt64 integer")
    return value


def _nonnegative_int(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{label} must be a non-negative integer")
    return value


def _digest(value: object, label: str) -> str:
    value = _required(value, label)
    if not _DIGEST.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase sha256 identity")
    return value


def _raw_sha256(value: object, label: str) -> str:
    value = _required(value, label)
    if not _RAW_SHA256.fullmatch(value):
        raise ValueError(f"{label} must be a raw lowercase sha256 identity")
    return value


def _source_revision(value: object, label: str) -> str:
    value = _required(value, label)
    if not _SOURCE_REVISION.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase full Git revision")
    return value


def canonical_https_url(value: object, label: str) -> str:
    """Require one bounded wire-stable HTTPS URL accepted by the native parser.

    This deliberately excludes credentials, fragments, non-ASCII source text,
    malformed percent escapes and non-default TLS ports.  A URL is kept as its
    exact signed string rather than normalized at use time, so the Python
    qualifier cannot publish a descriptor the native installer refuses after
    download.
    """

    value = _required(value, label)
    if len(value) > MAXIMUM_CANONICAL_HTTPS_URL_LENGTH or not value.isascii() or not value.startswith("https://"):
        raise ValueError(f"{label} must be a bounded canonical HTTPS URL")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise ValueError(f"{label} must be a bounded canonical HTTPS URL") from error
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
        or (port is not None and port != 443)
        or (port is not None and not parsed.netloc.endswith(":443"))
        or (port is None and parsed.netloc.endswith(":"))
        or _CANONICAL_HTTPS_AUTHORITY.fullmatch(parsed.netloc) is None
        or _CANONICAL_HTTPS_PATH_OR_QUERY.fullmatch(parsed.path) is None
        or _CANONICAL_HTTPS_PATH_OR_QUERY.fullmatch(parsed.query) is None
        or any(
            _PERCENT_ESCAPE.fullmatch(value[index : index + 3]) is None
            for index, character in enumerate(value)
            if character == "%"
        )
        or urlunsplit(parsed) != value
    ):
        raise ValueError(f"{label} must be a bounded canonical HTTPS URL")
    return value


def _https_url(value: object, label: str) -> str:
    """Backward-compatible internal spelling for canonical HTTPS validation."""

    return canonical_https_url(value, label)


def canonical_rfc3339_utc_timestamp(value: object, label: str) -> datetime:
    """Parse the one wire-stable RFC3339 timestamp profile used by installer metadata.

    The profile is ASCII ``YYYY-MM-DDTHH:MM:SSZ`` only.  It is an RFC3339
    subset, not a display-date convenience parser: offsets, fractional
    seconds, lowercase separators, whitespace and parser-normalised calendar
    values are rejected before any comparison or signature-bound selection.
    """

    value = _required(value, label)
    match = _CANONICAL_RFC3339_UTC.fullmatch(value)
    if match is None:
        raise ValueError(f"{label} must be a canonical RFC3339 UTC timestamp")
    try:
        return datetime(
            int(match["year"]),
            int(match["month"]),
            int(match["day"]),
            int(match["hour"]),
            int(match["minute"]),
            int(match["second"]),
            tzinfo=timezone.utc,
        )
    except ValueError as error:
        raise ValueError(f"{label} must be a canonical RFC3339 UTC timestamp") from error


def _timestamp(value: object, label: str) -> datetime:
    """Compatibility spelling for signed installer and outer-catalog fields."""

    return canonical_rfc3339_utc_timestamp(value, label)


def _canonical_json(value: Mapping[str, object]) -> bytes:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ValueError("signed metadata must contain only finite JSON values") from error


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON value is not permitted: {value}")


def _reject_duplicate_pairs(pairs: list[tuple[object, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if not isinstance(key, str) or key in result:
            raise ValueError("signed JSON has duplicate or invalid object keys")
        result[key] = value
    return result


def _strict_json_mapping(
    raw_bytes: bytes,
    label: str,
    *,
    maximum_nesting_depth: int | None = None,
    maximum_node_count: int | None = None,
) -> Mapping[str, object]:
    if not isinstance(raw_bytes, bytes):
        raise ValueError(f"{label} bytes are required")
    try:
        value = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as error:
        raise UniversalInstallerError(f"{label} is not valid strict JSON") from error
    if not isinstance(value, Mapping):
        raise UniversalInstallerError(f"{label} root must be an object")
    if maximum_nesting_depth is not None or maximum_node_count is not None:
        _require_bounded_json_structure(
            value,
            label=label,
            maximum_nesting_depth=maximum_nesting_depth,
            maximum_node_count=maximum_node_count,
        )
    return value


def _require_bounded_json_structure(
    value: object,
    *,
    label: str,
    maximum_nesting_depth: int | None,
    maximum_node_count: int | None,
) -> None:
    """Mirror the native strict reader's container-depth and value budgets.

    The check runs after duplicate-key/non-finite rejection and before a
    catalog is semantically authorized. It is iterative so the qualifier does
    not use Python recursion to assess hostile JSON. A JSON *value* (not an
    object key) consumes one node, matching the Swift reader's `parseValue`.
    Only object/array nesting consumes the separate container-depth budget.
    """

    if maximum_nesting_depth is not None and maximum_nesting_depth <= 0:
        raise ValueError("maximum JSON nesting depth must be positive")
    if maximum_node_count is not None and maximum_node_count <= 0:
        raise ValueError("maximum JSON node count must be positive")

    nodes = 0
    pending: list[tuple[object, int]] = [(value, 0)]
    while pending:
        current, parent_container_depth = pending.pop()
        nodes += 1
        if maximum_node_count is not None and nodes > maximum_node_count:
            raise UniversalInstallerError(f"{label} exceeds the native JSON node limit")

        if isinstance(current, Mapping):
            depth = parent_container_depth + 1
            if maximum_nesting_depth is not None and depth > maximum_nesting_depth:
                raise UniversalInstallerError(f"{label} exceeds the native JSON nesting limit")
            pending.extend((child, depth) for child in current.values())
        elif isinstance(current, list):
            depth = parent_container_depth + 1
            if maximum_nesting_depth is not None and depth > maximum_nesting_depth:
                raise UniversalInstallerError(f"{label} exceeds the native JSON nesting limit")
            pending.extend((child, depth) for child in current)


@dataclass(frozen=True, order=True)
class SemanticVersion:
    """The deliberately small stable-version grammar used by installer metadata."""

    major: int
    minor: int
    patch: int

    def __post_init__(self) -> None:
        if any(
            isinstance(component, bool)
            or not isinstance(component, int)
            or component < 0
            or component > _MAXIMUM_NATIVE_SIGNED_INTEGER
            for component in (self.major, self.minor, self.patch)
        ):
            raise ValueError("semantic version components must fit native Int64")

    @classmethod
    def parse(cls, value: object, label: str = "version") -> "SemanticVersion":
        value = _required(value, label)
        match = _SEMVER.fullmatch(value)
        if not match:
            raise ValueError(f"{label} must be a stable semantic version")
        return cls(*(int(part) for part in match.groups()))

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclass(frozen=True)
class DownloadIdentity:
    """A URL remains an acquisition locator, not a replacement for the digest."""

    url: str
    digest: str

    def __post_init__(self) -> None:
        _https_url(self.url, "download URL")
        _digest(self.digest, "download digest")


@dataclass(frozen=True)
class ManagedPythonRuntimeIdentity:
    """One immutable platform-approved CPython runtime, never inferred from PATH."""

    schema: str
    implementation: str
    version: SemanticVersion
    operating_system: str
    architecture: str
    minimum_macos_version: SemanticVersion
    build_variant: str
    python_tag: str
    abi_tag: str
    platform_tag: str
    artifact_kind: str
    managed_root_identity: str
    artifact: DownloadIdentity
    source: DownloadIdentity
    source_provenance: DownloadIdentity
    build_provenance: DownloadIdentity
    policy_revision: str
    identity_digest: str

    def __post_init__(self) -> None:
        if self.schema != MANAGED_PYTHON_RUNTIME_SCHEMA:
            raise ValueError("managed Python runtime schema is unsupported")
        if self.implementation != MANAGED_PYTHON_IMPLEMENTATION:
            raise ValueError("managed Python runtime implementation is unsupported")
        if not isinstance(self.version, SemanticVersion):
            raise ValueError("managed Python runtime version must be exact semantic version")
        if self.operating_system != MANAGED_PYTHON_OPERATING_SYSTEM:
            raise ValueError("managed Python runtime operating system must be macOS")
        if self.architecture != MANAGED_PYTHON_ARCHITECTURE:
            raise ValueError("managed Python runtime must be arm64-only")
        if (
            not isinstance(self.minimum_macos_version, SemanticVersion)
            or self.minimum_macos_version.major < MINIMUM_MACOS_MAJOR
        ):
            raise ValueError("managed Python runtime requires macOS 26 or newer")
        if self.build_variant != MANAGED_PYTHON_BUILD_VARIANT:
            raise ValueError("managed Python runtime build variant is unsupported")
        expected_tag = f"cp{self.version.major}{self.version.minor}"
        if self.python_tag != expected_tag or not _PYTHON_TAG.fullmatch(self.python_tag):
            raise ValueError("managed Python runtime python_tag does not match its exact version")
        if self.abi_tag != self.python_tag:
            raise ValueError("managed Python runtime ABI tag must equal the standard-GIL Python tag")
        if not _PYTHON_PLATFORM_TAG.fullmatch(self.platform_tag):
            raise ValueError("managed Python runtime platform tag must be macOS 26 arm64")
        if self.artifact_kind != MANAGED_PYTHON_ARTIFACT_KIND:
            raise ValueError("managed Python runtime artifact kind is unsupported")
        if self.managed_root_identity != MANAGED_PYTHON_ROOT_IDENTITY:
            raise ValueError("managed Python runtime root identity is unsupported")
        for label, locator in (
            ("artifact", self.artifact),
            ("source", self.source),
            ("source provenance", self.source_provenance),
            ("build provenance", self.build_provenance),
        ):
            if not isinstance(locator, DownloadIdentity):
                raise ValueError(f"managed Python runtime {label} identity is invalid")
        if not _POLICY_REVISION.fullmatch(self.policy_revision):
            raise ValueError("managed Python runtime policy revision is invalid")
        _digest(self.identity_digest, "managed Python runtime identity_digest")
        if self.identity_digest != self.computed_identity_digest():
            raise ValueError("managed Python runtime identity_digest does not bind the exact runtime")

    def identity_material(self) -> Mapping[str, object]:
        return {
            "schema": self.schema,
            "implementation": self.implementation,
            "version": str(self.version),
            "operating_system": self.operating_system,
            "architecture": self.architecture,
            "minimum_macos_version": str(self.minimum_macos_version),
            "build_variant": self.build_variant,
            "python_tag": self.python_tag,
            "abi_tag": self.abi_tag,
            "platform_tag": self.platform_tag,
            "artifact_kind": self.artifact_kind,
            "managed_root_identity": self.managed_root_identity,
            "artifact": {"url": self.artifact.url, "digest": self.artifact.digest},
            "source": {"url": self.source.url, "digest": self.source.digest},
            "source_provenance": {
                "url": self.source_provenance.url,
                "digest": self.source_provenance.digest,
            },
            "build_provenance": {
                "url": self.build_provenance.url,
                "digest": self.build_provenance.digest,
            },
            "policy_revision": self.policy_revision,
        }

    def computed_identity_digest(self) -> str:
        return "sha256:" + sha256(_canonical_json(self.identity_material())).hexdigest()

    @classmethod
    def from_mapping(cls, value: object) -> "ManagedPythonRuntimeIdentity":
        fields = frozenset({
            "schema", "implementation", "version", "operating_system", "architecture",
            "minimum_macos_version", "build_variant", "python_tag", "abi_tag", "platform_tag",
            "artifact_kind", "managed_root_identity", "artifact", "source", "source_provenance",
            "build_provenance", "policy_revision", "identity_digest",
        })
        payload = _mapping(value, fields, "managed Python runtime")

        def locator(name: str) -> DownloadIdentity:
            item = _mapping(payload[name], frozenset({"url", "digest"}), f"managed Python {name}")
            return DownloadIdentity(
                _https_url(item["url"], f"managed Python {name} URL"),
                _digest(item["digest"], f"managed Python {name} digest"),
            )

        return cls(
            _required(payload["schema"], "managed Python schema"),
            _required(payload["implementation"], "managed Python implementation"),
            SemanticVersion.parse(payload["version"], "managed Python version"),
            _required(payload["operating_system"], "managed Python operating_system"),
            _required(payload["architecture"], "managed Python architecture"),
            SemanticVersion.parse(payload["minimum_macos_version"], "managed Python minimum_macos_version"),
            _required(payload["build_variant"], "managed Python build_variant"),
            _required(payload["python_tag"], "managed Python python_tag"),
            _required(payload["abi_tag"], "managed Python abi_tag"),
            _required(payload["platform_tag"], "managed Python platform_tag"),
            _required(payload["artifact_kind"], "managed Python artifact_kind"),
            _required(payload["managed_root_identity"], "managed Python managed_root_identity"),
            locator("artifact"),
            locator("source"),
            locator("source_provenance"),
            locator("build_provenance"),
            _required(payload["policy_revision"], "managed Python policy_revision"),
            _digest(payload["identity_digest"], "managed Python identity_digest"),
        )


@dataclass(frozen=True)
class CatalogFeedLocator:
    """Signed immutable locator for a separately signed, rotating catalog feed.

    A catalog is intentionally not pinned to the installer bundle digest: a
    compatible installer may select a newly published composition without a
    binary replacement.  The catalog's own signature, sequence, expiry and
    locally persisted accepted identity provide its integrity and anti-replay
    guarantees.
    """

    url: str

    def __post_init__(self) -> None:
        _https_url(self.url, "composition catalog feed URL")


@dataclass(frozen=True)
class GitHubInstallerReleaseIdentity:
    """The signed descriptor's canonical GitHub Release namespace.

    Individual archive URLs are deliberately derived from this immutable
    identity.  A descriptor cannot redirect a trusted old installer to an
    arbitrary URL while retaining a valid archive digest.
    """

    repository: str
    tag: str
    descriptor_asset_name: str

    def __post_init__(self) -> None:
        if not isinstance(self.repository, str) or _GITHUB_REPOSITORY.fullmatch(self.repository) is None:
            raise ValueError("installer GitHub release repository is invalid")
        if not isinstance(self.tag, str) or _GITHUB_RELEASE_TAG.fullmatch(self.tag) is None:
            raise ValueError("installer GitHub release tag is invalid")
        if (
            not isinstance(self.descriptor_asset_name, str)
            or _GITHUB_DESCRIPTOR_ASSET_NAME.fullmatch(self.descriptor_asset_name) is None
        ):
            raise ValueError("installer GitHub descriptor asset name is invalid")

    @classmethod
    def from_mapping(cls, value: object) -> "GitHubInstallerReleaseIdentity":
        payload = _mapping(
            value,
            frozenset({"repository", "tag", "descriptor_asset_name"}),
            "installer GitHub release identity",
        )
        return cls(
            repository=_required(payload["repository"], "installer GitHub release repository"),
            tag=_required(payload["tag"], "installer GitHub release tag"),
            descriptor_asset_name=_required(
                payload["descriptor_asset_name"], "installer GitHub descriptor asset name"
            ),
        )

    def asset_url(self, asset_name: str) -> str:
        if not isinstance(asset_name, str) or _GITHUB_ARCHIVE_ASSET_NAME.fullmatch(asset_name) is None:
            raise ValueError("installer GitHub archive asset name is invalid")
        return f"https://github.com/{self.repository}/releases/download/{self.tag}/{asset_name}"

    @property
    def descriptor_url(self) -> str:
        """The sole descriptor location implied by this signed identity."""

        return f"https://github.com/{self.repository}/releases/download/{self.tag}/{self.descriptor_asset_name}"


@dataclass(frozen=True)
class SealedInstallerReleaseTrustExpectation:
    """Public V2 trust facts loaded from the current code-signed bundle.

    Signature keys and threshold remain in :class:`SignatureThresholdPolicy`.
    This separate, immutable locator prevents a descriptor that is correctly
    signed under the key policy from redirecting self-update transport to a
    different GitHub namespace or application identity.
    """

    repository: str
    descriptor_asset_name: str
    expected_bundle_identifier: str
    expected_team_identifier: str
    configuration_sha256: str

    def __post_init__(self) -> None:
        if not isinstance(self.repository, str) or _GITHUB_REPOSITORY.fullmatch(self.repository) is None:
            raise ValueError("sealed installer release trust repository is invalid")
        if (
            not isinstance(self.descriptor_asset_name, str)
            or _GITHUB_DESCRIPTOR_ASSET_NAME.fullmatch(self.descriptor_asset_name) is None
        ):
            raise ValueError("sealed installer release trust descriptor asset name is invalid")
        if (
            not isinstance(self.expected_bundle_identifier, str)
            or _BUNDLE_IDENTIFIER.fullmatch(self.expected_bundle_identifier) is None
        ):
            raise ValueError("sealed installer release trust bundle identifier is invalid")
        if (
            not isinstance(self.expected_team_identifier, str)
            or _TEAM_IDENTIFIER.fullmatch(self.expected_team_identifier) is None
        ):
            raise ValueError("sealed installer release trust team identifier is invalid")
        _raw_sha256(self.configuration_sha256, "sealed installer release trust configuration digest")

    def require_release_binding(
        self,
        *,
        github_release: GitHubInstallerReleaseIdentity,
        assets: tuple["InstallerAsset", ...],
    ) -> None:
        """Require descriptor transport and app identity to match current V2 facts.

        The descriptor's trust-configuration digest describes the *target*
        installer and must be allowed to rotate. Its target-bundle comparison
        belongs to staging/activation, not this current-bundle locator gate.
        """

        if not isinstance(github_release, GitHubInstallerReleaseIdentity):
            raise ValueError("installer release GitHub identity is invalid")
        if (
            github_release.repository != self.repository
            or github_release.descriptor_asset_name != self.descriptor_asset_name
        ):
            raise ValueError(
                "installer release GitHub identity does not match the sealed trust configuration"
            )
        for asset in assets:
            if (
                asset.bundle_identifier != self.expected_bundle_identifier
                or asset.team_identifier != self.expected_team_identifier
            ):
                raise ValueError(
                    "installer archive signing identity does not match the sealed trust configuration"
                )


@dataclass(frozen=True)
class InstallerAsset:
    """One macOS archive bound to a canonical GitHub Release asset name."""

    operating_system: str
    architecture: str
    minimum_macos_version: str
    asset_name: str
    archive_digest: str
    bundle_identifier: str
    team_identifier: str
    code_directory_sha256: str
    notarization_receipt_reference: str

    def __post_init__(self) -> None:
        if self.operating_system != "macos":
            raise ValueError("installer asset operating_system must be macos")
        if self.architecture not in SUPPORTED_MACOS_ARCHITECTURES:
            raise ValueError("installer asset architecture is unsupported")
        if self.minimum_macos_version != MINIMUM_MACOS_SEMANTIC_VERSION:
            raise ValueError("installer asset minimum_macos_version must be 26.0.0")
        if not isinstance(self.asset_name, str) or _GITHUB_ARCHIVE_ASSET_NAME.fullmatch(self.asset_name) is None:
            raise ValueError("installer asset name is invalid")
        _digest(self.archive_digest, "installer asset archive digest")
        if not isinstance(self.bundle_identifier, str) or _BUNDLE_IDENTIFIER.fullmatch(self.bundle_identifier) is None:
            raise ValueError("installer asset bundle identifier is invalid")
        if not isinstance(self.team_identifier, str) or _TEAM_IDENTIFIER.fullmatch(self.team_identifier) is None:
            raise ValueError("installer asset team identifier is invalid")
        _raw_sha256(self.code_directory_sha256, "installer asset CodeDirectory digest")
        if (
            not isinstance(self.notarization_receipt_reference, str)
            or _OPAQUE_JOURNAL_REFERENCE.fullmatch(self.notarization_receipt_reference) is None
        ):
            raise ValueError("installer asset notarization receipt reference is invalid")

    @classmethod
    def from_mapping(cls, value: object) -> "InstallerAsset":
        payload = _mapping(
            value,
            frozenset({
                "operating_system", "architecture", "minimum_macos_version", "asset_name", "digest",
                "bundle_identifier", "team_identifier",
                "code_directory_sha256", "notarization_receipt_reference",
            }),
            "installer asset",
        )
        return cls(
            operating_system=_required(payload["operating_system"], "installer asset operating_system"),
            architecture=_required(payload["architecture"], "installer asset architecture"),
            minimum_macos_version=_required(
                payload["minimum_macos_version"], "installer asset minimum_macos_version"
            ),
            asset_name=_required(payload["asset_name"], "installer asset name"),
            archive_digest=_digest(payload["digest"], "installer asset digest"),
            bundle_identifier=_required(payload["bundle_identifier"], "installer asset bundle_identifier"),
            team_identifier=_required(payload["team_identifier"], "installer asset team_identifier"),
            code_directory_sha256=_raw_sha256(
                payload["code_directory_sha256"], "installer asset CodeDirectory digest"
            ),
            notarization_receipt_reference=_required(
                payload["notarization_receipt_reference"], "installer asset notarization receipt reference"
            ),
        )


@dataclass(frozen=True)
class PublicSignatureEnvelope:
    """One non-secret signature over canonical installer metadata.

    The descriptor carries a public signing algorithm, public key identity and
    canonical base64url signature.  It intentionally carries neither a public
    key nor any credential: the verifier resolves an approved key ID through
    its independently protected trust root.
    """

    algorithm: str
    key_id: str
    signature: str

    def __post_init__(self) -> None:
        if self.algorithm != "ed25519":
            raise ValueError("metadata signature algorithm is unsupported")
        if not isinstance(self.key_id, str) or _SIGNING_KEY_ID.fullmatch(self.key_id) is None:
            raise ValueError("metadata signature key_id is invalid")
        if not isinstance(self.signature, str) or _ED25519_SIGNATURE.fullmatch(self.signature) is None:
            raise ValueError("metadata Ed25519 signature must be canonical unpadded base64url")
        try:
            raw_signature = base64.b64decode(self.signature + "==", altchars=b"-_", validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError("metadata Ed25519 signature encoding is invalid") from error
        if len(raw_signature) != 64:
            raise ValueError("metadata Ed25519 signature has invalid length")

    @classmethod
    def from_mapping(cls, value: object) -> "PublicSignatureEnvelope":
        payload = _mapping(value, frozenset({"algorithm", "key_id", "signature"}), "metadata signature envelope")
        return cls(
            algorithm=_required(payload["algorithm"], "metadata signature algorithm"),
            key_id=_required(payload["key_id"], "metadata signature key_id"),
            signature=_required(payload["signature"], "metadata signature"),
        )


@dataclass(frozen=True)
class SignatureThresholdPolicy:
    """Public trust-policy facts enforced before a cryptographic verifier runs.

    Key IDs and threshold are not substitute public keys.  They bind the
    metadata parser to the protected key set which the supplied verifier must
    resolve independently.  Unknown, duplicate, mixed-algorithm or
    insufficient envelopes fail before a verifier can accidentally count them.
    """

    algorithm: str
    trusted_key_ids: frozenset[str]
    threshold: int

    def __post_init__(self) -> None:
        if self.algorithm != "ed25519":
            raise ValueError("metadata signature policy algorithm is unsupported")
        if not isinstance(self.trusted_key_ids, (frozenset, set, tuple, list)):
            raise ValueError("metadata signature policy trusted key IDs are invalid")
        if any(not isinstance(key_id, str) or _SIGNING_KEY_ID.fullmatch(key_id) is None for key_id in self.trusted_key_ids):
            raise ValueError("metadata signature policy key ID is invalid")
        normalized_key_ids = frozenset(self.trusted_key_ids)
        if not normalized_key_ids or len(normalized_key_ids) != len(self.trusted_key_ids):
            raise ValueError("metadata signature policy key IDs must be non-empty and unique")
        if (
            isinstance(self.threshold, bool)
            or not isinstance(self.threshold, int)
            or self.threshold <= 0
            or self.threshold > len(normalized_key_ids)
        ):
            raise ValueError("metadata signature policy threshold is invalid")
        object.__setattr__(self, "trusted_key_ids", normalized_key_ids)

    def require_eligible(self, signatures: tuple[PublicSignatureEnvelope, ...]) -> None:
        """Reject every envelope set that cannot meet this exact policy."""

        if not isinstance(signatures, tuple) or not signatures:
            raise ValueError("metadata signatures are required")
        observed_key_ids: set[str] = set()
        for envelope in signatures:
            if not isinstance(envelope, PublicSignatureEnvelope):
                raise ValueError("metadata signature envelope is invalid")
            if envelope.algorithm != self.algorithm:
                raise ValueError("metadata signature envelope algorithm does not match policy")
            if envelope.key_id not in self.trusted_key_ids:
                raise ValueError("metadata signature envelope key_id is not trusted by policy")
            if envelope.key_id in observed_key_ids:
                raise ValueError("metadata signature envelope key_id is duplicated")
            observed_key_ids.add(envelope.key_id)
        if len(observed_key_ids) < self.threshold:
            raise ValueError("metadata signature envelopes do not meet the policy threshold")


def parse_public_signature_envelopes(value: object, *, label: str) -> tuple[PublicSignatureEnvelope, ...]:
    """Parse the sole accepted public envelope shape for signed metadata."""

    if not isinstance(value, list) or not value:
        raise ValueError(f"{label} signatures are required")
    envelopes = tuple(PublicSignatureEnvelope.from_mapping(item) for item in value)
    key_ids = tuple(envelope.key_id for envelope in envelopes)
    if len(set(key_ids)) != len(key_ids):
        raise ValueError(f"{label} signature key IDs must be unique")
    return envelopes


class InstallerMetadataVerifier(Protocol):
    """Trust-root adapter; GitHub's ``latest`` marker is never this verifier."""

    def verify(
        self,
        canonical_payload: bytes,
        signatures: tuple[PublicSignatureEnvelope, ...],
        *,
        policy: SignatureThresholdPolicy,
    ) -> bool:
        """Cryptographically verify every counted envelope under ``policy``."""


def _verify_metadata_signatures(
    canonical_payload: bytes,
    signatures: tuple[PublicSignatureEnvelope, ...],
    verifier: InstallerMetadataVerifier,
    policy: SignatureThresholdPolicy,
    *,
    label: str,
) -> None:
    """Apply public threshold policy before delegating cryptographic checks."""

    if not isinstance(policy, SignatureThresholdPolicy):
        raise ValueError("metadata signature policy is required")
    policy.require_eligible(signatures)
    try:
        verified = verifier.verify(canonical_payload, signatures, policy=policy)
    except Exception as error:
        raise UniversalInstallerError(f"{label} signature verification failed") from error
    if verified is not True:
        raise UniversalInstallerError(f"{label} signature verification failed")


@dataclass(frozen=True)
class InstallerRelease:
    """A verified immutable installer release descriptor from a GitHub Release."""

    sequence: int
    channel: str
    version: SemanticVersion
    source_revision: str
    policy_revision: str
    github_release: GitHubInstallerReleaseIdentity
    release_trust_configuration_sha256: str
    provenance_sha256: str
    published_at: datetime
    expires_at: datetime
    capabilities: frozenset[str]
    assets: tuple[InstallerAsset, ...]
    composition_catalog_feed: CatalogFeedLocator
    signatures: tuple[PublicSignatureEnvelope, ...]

    def __post_init__(self) -> None:
        _sequence(self.sequence, "installer sequence")
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("installer channel is unsupported")
        if not isinstance(self.version, SemanticVersion):
            raise ValueError("installer version must be semantic")
        _source_revision(self.source_revision, "installer source_revision")
        if not isinstance(self.policy_revision, str) or _POLICY_REVISION.fullmatch(self.policy_revision) is None:
            raise ValueError("installer policy_revision is invalid")
        if not isinstance(self.github_release, GitHubInstallerReleaseIdentity):
            raise ValueError("installer release requires a canonical GitHub release identity")
        _raw_sha256(self.release_trust_configuration_sha256, "installer release trust configuration digest")
        _raw_sha256(self.provenance_sha256, "installer release provenance digest")
        if self.expires_at <= self.published_at:
            raise ValueError("installer metadata must expire after publication")
        if not self.capabilities:
            raise ValueError("installer release must declare capabilities")
        for capability in self.capabilities:
            if not isinstance(capability, str) or not _CAPABILITY.fullmatch(capability):
                raise ValueError("installer release capability identity is invalid")
        if (
            not isinstance(self.assets, tuple)
            or len(self.assets) != 1
            or not isinstance(self.assets[0], InstallerAsset)
            or self.assets[0].operating_system != "macos"
            or self.assets[0].architecture != INSTALLER_ARCHITECTURE
        ):
            raise ValueError("installer release must include exactly one arm64 macOS asset")
        seen_assets: set[tuple[str, str]] = set()
        seen_asset_names: set[str] = set()
        for asset in self.assets:
            if not isinstance(asset, InstallerAsset):
                raise ValueError("installer release assets are invalid")
            key = (asset.operating_system, asset.architecture)
            if key in seen_assets:
                raise ValueError("installer release contains duplicate host assets")
            seen_assets.add(key)
            if asset.asset_name in seen_asset_names:
                raise ValueError("installer release contains duplicate GitHub archive asset names")
            seen_asset_names.add(asset.asset_name)
        if not isinstance(self.composition_catalog_feed, CatalogFeedLocator):
            raise ValueError("installer release requires a composition catalog feed locator")
        if (
            not isinstance(self.signatures, tuple)
            or not self.signatures
            or any(not isinstance(signature, PublicSignatureEnvelope) for signature in self.signatures)
        ):
            raise ValueError("installer release requires public signature envelopes")
        if len({signature.key_id for signature in self.signatures}) != len(self.signatures):
            raise ValueError("installer release signature key IDs must be unique")

    @classmethod
    def from_signed_metadata(
        cls,
        value: object,
        verifier: InstallerMetadataVerifier,
        *,
        signature_policy: SignatureThresholdPolicy,
        sealed_release_trust: SealedInstallerReleaseTrustExpectation,
    ) -> "InstallerRelease":
        payload = _mapping(
            value,
            frozenset({
                "schema", "sequence", "channel", "published_at", "expires_at", "github_release", "installer",
                "composition_catalog", "signatures",
            }),
            "installer release metadata",
        )
        if payload["schema"] != INSTALLER_RELEASE_SCHEMA:
            raise UniversalInstallerError("installer release schema is unsupported")
        signatures = parse_public_signature_envelopes(payload["signatures"], label="installer release metadata")
        unsigned = {key: entry for key, entry in payload.items() if key != "signatures"}
        _verify_metadata_signatures(
            _canonical_json(unsigned),
            signatures,
            verifier,
            signature_policy,
            label="installer release metadata",
        )
        installer = _mapping(
            payload["installer"],
            frozenset({
                "version", "source_revision", "policy_revision", "release_trust_configuration_sha256",
                "provenance_sha256", "capabilities", "assets",
            }),
            "installer release",
        )
        capabilities = installer["capabilities"]
        if not isinstance(capabilities, list) or not capabilities:
            raise ValueError("installer capabilities must be a non-empty list")
        parsed_capabilities = tuple(_required(capability, "installer capability") for capability in capabilities)
        if len(parsed_capabilities) != len(set(parsed_capabilities)):
            raise ValueError("installer capabilities must be unique")
        if parsed_capabilities != tuple(sorted(parsed_capabilities)):
            raise ValueError("installer capabilities must be strictly sorted")
        assets = installer["assets"]
        if not isinstance(assets, list):
            raise ValueError("installer assets must be a list")
        catalog = _mapping(
            payload["composition_catalog"],
            frozenset({"url"}),
            "composition catalog",
        )
        release = cls(
            sequence=_sequence(payload["sequence"], "installer sequence"),
            channel=_required(payload["channel"], "installer channel"),
            version=SemanticVersion.parse(installer["version"], "installer version"),
            source_revision=_source_revision(installer["source_revision"], "installer source_revision"),
            policy_revision=_required(installer["policy_revision"], "installer policy_revision"),
            github_release=GitHubInstallerReleaseIdentity.from_mapping(payload["github_release"]),
            release_trust_configuration_sha256=_raw_sha256(
                installer["release_trust_configuration_sha256"], "installer release trust configuration digest"
            ),
            provenance_sha256=_raw_sha256(installer["provenance_sha256"], "installer provenance digest"),
            published_at=_timestamp(payload["published_at"], "installer published_at"),
            expires_at=_timestamp(payload["expires_at"], "installer expires_at"),
            capabilities=frozenset(parsed_capabilities),
            assets=tuple(InstallerAsset.from_mapping(asset) for asset in assets),
            composition_catalog_feed=CatalogFeedLocator(_https_url(catalog["url"], "catalog URL")),
            signatures=signatures,
        )
        if not isinstance(sealed_release_trust, SealedInstallerReleaseTrustExpectation):
            raise ValueError("sealed installer release trust expectation is required")
        sealed_release_trust.require_release_binding(
            github_release=release.github_release,
            assets=release.assets,
        )
        return release

    @classmethod
    def from_signed_bytes(
        cls,
        raw_bytes: bytes,
        verifier: InstallerMetadataVerifier,
        *,
        signature_policy: SignatureThresholdPolicy,
        sealed_release_trust: SealedInstallerReleaseTrustExpectation,
    ) -> "InstallerRelease":
        """Parse exactly the signed descriptor bytes fetched from a release."""

        if (
            not isinstance(raw_bytes, bytes)
            or not raw_bytes
            or len(raw_bytes) > MAXIMUM_INSTALLER_RELEASE_DESCRIPTOR_BYTES
        ):
            raise UniversalInstallerError("installer release descriptor exceeds the accepted byte bound")
        return cls.from_signed_metadata(
            _strict_json_mapping(raw_bytes, "installer release metadata"),
            verifier,
            signature_policy=signature_policy,
            sealed_release_trust=sealed_release_trust,
        )

    def asset_for(self, architecture: str) -> InstallerAsset | None:
        return next(
            (asset for asset in self.assets if asset.operating_system == "macos" and asset.architecture == architecture),
            None,
        )

    def is_expired(self, now: datetime) -> bool:
        return self.expires_at <= now.astimezone(timezone.utc)


@dataclass(frozen=True)
class InstalledInstallerIdentity:
    """The old process proves its own immutable bundle before it can hand off."""

    version: SemanticVersion
    source_revision: str
    accepted_policy_revision: str
    bundle_digest: str
    bundle_identifier: str
    team_identifier: str
    code_directory_sha256: str
    notarization_receipt_reference: str
    accepted_channel: str
    accepted_sequence: int
    accepted_release_trust_configuration_sha256: str
    accepted_provenance_sha256: str
    accepted_capabilities: frozenset[str]

    def __post_init__(self) -> None:
        if not isinstance(self.version, SemanticVersion):
            raise ValueError("installed installer version must be semantic")
        _source_revision(self.source_revision, "installed installer source_revision")
        if (
            not isinstance(self.accepted_policy_revision, str)
            or _POLICY_REVISION.fullmatch(self.accepted_policy_revision) is None
        ):
            raise ValueError("installed installer accepted policy revision is invalid")
        _digest(self.bundle_digest, "installed installer bundle_digest")
        if not isinstance(self.bundle_identifier, str) or _BUNDLE_IDENTIFIER.fullmatch(self.bundle_identifier) is None:
            raise ValueError("installed installer bundle identifier is invalid")
        if not isinstance(self.team_identifier, str) or _TEAM_IDENTIFIER.fullmatch(self.team_identifier) is None:
            raise ValueError("installed installer team identifier is invalid")
        _raw_sha256(self.code_directory_sha256, "installed installer CodeDirectory digest")
        if (
            not isinstance(self.notarization_receipt_reference, str)
            or _OPAQUE_JOURNAL_REFERENCE.fullmatch(self.notarization_receipt_reference) is None
        ):
            raise ValueError("installed installer notarization receipt reference is invalid")
        if self.accepted_channel not in INSTALLER_CHANNELS:
            raise ValueError("installed installer accepted channel is unsupported")
        _sequence(self.accepted_sequence, "installed installer accepted_sequence")
        _raw_sha256(
            self.accepted_release_trust_configuration_sha256,
            "installed installer accepted release trust configuration digest",
        )
        _raw_sha256(self.accepted_provenance_sha256, "installed installer accepted provenance digest")
        if not self.accepted_capabilities:
            raise ValueError("installed installer accepted_capabilities are required")
        for capability in self.accepted_capabilities:
            if not isinstance(capability, str) or not _CAPABILITY.fullmatch(capability):
                raise ValueError("installed installer accepted capability identity is invalid")


@dataclass(frozen=True)
class SelfUpdateDecision:
    """The only update decision an older process is allowed to make."""

    state: str
    reason: str
    installed: InstalledInstallerIdentity
    current_release: InstallerRelease | None = None
    target_release: InstallerRelease | None = None
    target_asset: InstallerAsset | None = None

    def __post_init__(self) -> None:
        if self.state not in {"CURRENT", "SELF_UPDATE_REQUIRED", "SELF_UPDATE_BLOCKED"}:
            raise ValueError("unsupported self-update state")
        _required(self.reason, "self-update reason")
        if not isinstance(self.installed, InstalledInstallerIdentity):
            raise ValueError("self-update decision must identify the installed bundle")
        if self.state == "CURRENT":
            if not isinstance(self.current_release, InstallerRelease):
                raise ValueError("current installer decision requires its verified release")
            if self.target_release is not None or self.target_asset is not None:
                raise ValueError("current installer decision cannot retain a handoff target")
        elif self.state == "SELF_UPDATE_REQUIRED":
            if not isinstance(self.target_release, InstallerRelease) or not isinstance(self.target_asset, InstallerAsset):
                raise ValueError("self-update handoff requires an exact release asset")
            if self.current_release is not None:
                raise ValueError("self-update handoff cannot retain a current release")
        elif self.current_release is not None or self.target_release is not None or self.target_asset is not None:
            raise ValueError("blocked self-update decision cannot retain a release target")

    @property
    def permits_platform_mutation(self) -> bool:
        return self.state == "CURRENT"

    @property
    def old_process_must_exit(self) -> bool:
        return self.state == "SELF_UPDATE_REQUIRED"


@dataclass(frozen=True)
class ReleaseFeedReadback:
    """Freshness and trusted-time evidence for this launch's release lookup."""

    source_url: str
    observed_at: datetime
    fresh_until: datetime
    trusted_clock: bool

    def __post_init__(self) -> None:
        _https_url(self.source_url, "installer release feed source URL")
        if self.observed_at.tzinfo is None or self.fresh_until.tzinfo is None:
            raise ValueError("installer release feed timestamps must include an offset")
        if self.fresh_until <= self.observed_at:
            raise ValueError("installer release feed freshness must follow observation")
        if not isinstance(self.trusted_clock, bool):
            raise ValueError("installer release feed trusted_clock must be boolean")


def select_self_update(
    installed: InstalledInstallerIdentity,
    releases: Iterable[InstallerRelease],
    *,
    channel: str,
    architecture: str,
    now: datetime,
    release_feed: ReleaseFeedReadback,
    sealed_release_trust: SealedInstallerReleaseTrustExpectation,
) -> SelfUpdateDecision:
    """Select a newer trusted GitHub-release asset or fail closed.

    Callers must first create every :class:`InstallerRelease` with a trust-root
    verifier.  A GitHub ``latest`` redirect is only a locator for those signed
    descriptors and is intentionally not accepted here.
    """

    if channel not in INSTALLER_CHANNELS:
        raise ValueError("self-update channel is unsupported")
    if architecture != INSTALLER_ARCHITECTURE:
        raise ValueError("self-update requires a native arm64 process")
    if not isinstance(release_feed, ReleaseFeedReadback):
        raise ValueError("fresh installer release feed readback is required")
    if not isinstance(sealed_release_trust, SealedInstallerReleaseTrustExpectation):
        raise ValueError("sealed installer release trust expectation is required")
    if (
        installed.bundle_identifier != sealed_release_trust.expected_bundle_identifier
        or installed.team_identifier != sealed_release_trust.expected_team_identifier
        or (
            installed.accepted_release_trust_configuration_sha256
            != sealed_release_trust.configuration_sha256
        )
    ):
        return SelfUpdateDecision(
            "SELF_UPDATE_BLOCKED",
            "installed installer identity does not match the sealed trust configuration",
            installed,
        )
    if channel != installed.accepted_channel:
        return SelfUpdateDecision(
            "SELF_UPDATE_BLOCKED",
            "requested installer channel does not match the locally accepted channel",
            installed,
        )
    now = now.astimezone(timezone.utc)
    if (
        not release_feed.trusted_clock
        or release_feed.observed_at.astimezone(timezone.utc) > now
        or release_feed.fresh_until.astimezone(timezone.utc) <= now
    ):
        return SelfUpdateDecision(
            "SELF_UPDATE_BLOCKED",
            "installer release feed is stale or lacks trusted-clock evidence",
            installed,
        )
    candidates = [release for release in releases if release.channel == channel and not release.is_expired(now)]
    if not candidates:
        return SelfUpdateDecision("SELF_UPDATE_BLOCKED", "no current trusted installer release is available", installed)
    sequences: set[int] = set()
    versions: dict[SemanticVersion, InstallerRelease] = {}
    for release in candidates:
        try:
            sealed_release_trust.require_release_binding(
                github_release=release.github_release,
                assets=release.assets,
            )
        except ValueError as error:
            raise UniversalInstallerError(
                "trusted installer metadata does not bind the sealed trust configuration"
            ) from error
        if release.sequence in sequences:
            raise UniversalInstallerError("trusted installer metadata has duplicate sequence values")
        sequences.add(release.sequence)
        previous = versions.get(release.version)
        if previous is not None and (
            previous.source_revision != release.source_revision
            or previous.policy_revision != release.policy_revision
            or previous.github_release != release.github_release
            or previous.release_trust_configuration_sha256 != release.release_trust_configuration_sha256
            or previous.provenance_sha256 != release.provenance_sha256
            or previous.assets != release.assets
            or previous.composition_catalog_feed != release.composition_catalog_feed
            or previous.capabilities != release.capabilities
        ):
            raise UniversalInstallerError("one installer version maps to conflicting immutable metadata")
        versions[release.version] = release
    latest = max(candidates, key=lambda release: (release.sequence, release.version))
    if any(release.version > latest.version for release in candidates):
        raise UniversalInstallerError("installer release sequence regresses the stable version")
    if latest.sequence < installed.accepted_sequence:
        return SelfUpdateDecision("SELF_UPDATE_BLOCKED", "trusted installer release sequence regresses accepted local provenance", installed)
    if installed.version == latest.version:
        asset = latest.asset_for(architecture)
        if asset is None:
            return SelfUpdateDecision("SELF_UPDATE_BLOCKED", "current release has no compatible macOS asset", installed)
        if (
            latest.sequence != installed.accepted_sequence
            or
            installed.source_revision != latest.source_revision
            or installed.accepted_policy_revision != latest.policy_revision
            or installed.bundle_digest != asset.archive_digest
            or installed.bundle_identifier != asset.bundle_identifier
            or installed.team_identifier != asset.team_identifier
            or installed.code_directory_sha256 != asset.code_directory_sha256
            or installed.notarization_receipt_reference != asset.notarization_receipt_reference
            or (
                installed.accepted_release_trust_configuration_sha256
                != latest.release_trust_configuration_sha256
            )
            or installed.accepted_provenance_sha256 != latest.provenance_sha256
            or installed.accepted_capabilities != latest.capabilities
        ):
            return SelfUpdateDecision(
                "SELF_UPDATE_BLOCKED",
                "same installer version has different immutable provenance, bytes, signing identity, or capabilities",
                installed,
            )
        return SelfUpdateDecision("CURRENT", "installed verified release is current", installed, current_release=latest)
    if installed.version > latest.version:
        return SelfUpdateDecision("SELF_UPDATE_BLOCKED", "trusted installer release version regresses accepted local provenance", installed)
    asset = latest.asset_for(architecture)
    if asset is None:
        return SelfUpdateDecision("SELF_UPDATE_BLOCKED", "newer release has no compatible macOS asset", installed)
    return SelfUpdateDecision(
        "SELF_UPDATE_REQUIRED",
        "a newer verified installer must replace this process",
        installed,
        target_release=latest,
        target_asset=asset,
    )


@dataclass(frozen=True)
class InstallerCapabilitySet:
    version: SemanticVersion
    capabilities: frozenset[str]

    def __post_init__(self) -> None:
        if not isinstance(self.version, SemanticVersion):
            raise ValueError("installer capabilities require a semantic version")
        for capability in self.capabilities:
            if not isinstance(capability, str) or not _CAPABILITY.fullmatch(capability):
                raise ValueError("installer capability identity is invalid")

    @classmethod
    def from_release(cls, release: InstallerRelease) -> "InstallerCapabilitySet":
        """Derive capabilities only from an already verified release descriptor."""

        if not isinstance(release, InstallerRelease):
            raise ValueError("verified installer release is required")
        return cls(release.version, release.capabilities)


_VERIFIED_INSTALLER_CONTEXT_MARKER = object()


@dataclass(frozen=True, init=False)
class VerifiedInstallerContext:
    """An unforgeable-in-normal-use bridge from verified self-update to planning.

    The planner accepts this context rather than caller-assembled version/capability
    assertions.  Its only public constructor evaluates the signed release set and
    permits construction solely when the running bundle is the current immutable
    release for the selected channel and architecture.
    """

    release: InstallerRelease
    self_update: SelfUpdateDecision
    capabilities: InstallerCapabilitySet

    def __init__(
        self,
        release: InstallerRelease,
        self_update: SelfUpdateDecision,
        capabilities: InstallerCapabilitySet,
        *,
        _marker: object,
    ) -> None:
        if _marker is not _VERIFIED_INSTALLER_CONTEXT_MARKER:
            raise TypeError("VerifiedInstallerContext must be established from verified release metadata")
        if not isinstance(release, InstallerRelease) or not isinstance(self_update, SelfUpdateDecision):
            raise ValueError("verified installer release and decision are required")
        if self_update.state != "CURRENT" or self_update.current_release != release:
            raise UniversalInstallerError("installer context is not current and verified")
        if capabilities != InstallerCapabilitySet.from_release(release):
            raise UniversalInstallerError("installer capability context is not bound to the verified release")
        object.__setattr__(self, "release", release)
        object.__setattr__(self, "self_update", self_update)
        object.__setattr__(self, "capabilities", capabilities)

    @classmethod
    def establish(
        cls,
        installed: InstalledInstallerIdentity,
        releases: Iterable[InstallerRelease],
        *,
        channel: str,
        architecture: str,
        now: datetime,
        release_feed: ReleaseFeedReadback,
        sealed_release_trust: SealedInstallerReleaseTrustExpectation,
    ) -> "VerifiedInstallerContext":
        decision = select_self_update(
            installed,
            releases,
            channel=channel,
            architecture=architecture,
            now=now,
            release_feed=release_feed,
            sealed_release_trust=sealed_release_trust,
        )
        if decision.state != "CURRENT" or decision.current_release is None:
            raise UniversalInstallerError(decision.reason)
        release = decision.current_release
        return cls(
            release,
            decision,
            InstallerCapabilitySet.from_release(release),
            _marker=_VERIFIED_INSTALLER_CONTEXT_MARKER,
        )


@dataclass(frozen=True)
class InstallerRequirement:
    minimum_version: SemanticVersion
    capabilities: frozenset[str]

    def __post_init__(self) -> None:
        if not isinstance(self.minimum_version, SemanticVersion):
            raise ValueError("minimum installer version must be semantic")
        for capability in self.capabilities:
            if not isinstance(capability, str) or not _CAPABILITY.fullmatch(capability):
                raise ValueError("required installer capability identity is invalid")

    def unmet_by(self, installer: InstallerCapabilitySet) -> tuple[str, ...]:
        if not isinstance(installer, InstallerCapabilitySet):
            raise ValueError("installer capabilities are required")
        unmet = []
        if installer.version < self.minimum_version:
            unmet.append(f"installer version {self.minimum_version} or newer")
        unmet.extend(f"installer capability {capability}" for capability in sorted(self.capabilities - installer.capabilities))
        return tuple(unmet)


@dataclass(frozen=True)
class CompositionCatalogEntry:
    """A signed catalog locator for one immutable composition manifest."""

    composition_id: str
    channel: str
    manifest: DownloadIdentity
    installer_requirement: InstallerRequirement

    def __post_init__(self) -> None:
        _composition_catalog_id(self.composition_id, "composition catalog composition_id")
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("composition catalog channel is unsupported")
        if not isinstance(self.manifest, DownloadIdentity) or not isinstance(self.installer_requirement, InstallerRequirement):
            raise ValueError("composition catalog entry is invalid")

    @classmethod
    def from_mapping(cls, value: object) -> "CompositionCatalogEntry":
        payload = _mapping(
            value,
            frozenset({"composition_id", "channel", "url", "digest", "requires_installer"}),
            "composition catalog entry",
        )
        requirement = _mapping(payload["requires_installer"], frozenset({"minimum_version", "capabilities"}), "catalog installer requirement")
        capabilities = requirement["capabilities"]
        if not isinstance(capabilities, list):
            raise ValueError("catalog installer capabilities must be a list")
        parsed_capabilities = tuple(_required(capability, "catalog installer capability") for capability in capabilities)
        if len(parsed_capabilities) != len(set(parsed_capabilities)):
            raise ValueError("catalog installer capabilities must be unique")
        return cls(
            _composition_catalog_id(payload["composition_id"], "composition catalog composition_id"),
            _required(payload["channel"], "composition catalog channel"),
            DownloadIdentity(_https_url(payload["url"], "composition manifest URL"), _digest(payload["digest"], "composition manifest digest")),
            InstallerRequirement(
                SemanticVersion.parse(requirement["minimum_version"], "catalog minimum installer version"),
                frozenset(parsed_capabilities),
            ),
        )


_VERIFIED_COMPOSITION_CATALOG_MARKER = object()


@dataclass(frozen=True)
class CompositionCatalog:
    """A separately signed mutable index of immutable composition bytes."""

    sequence: int
    channel: str
    published_at: datetime
    expires_at: datetime
    approved_python_runtime_identity: str
    entries: tuple[CompositionCatalogEntry, ...]
    component_combination_catalog: DownloadIdentity | None
    catalog_digest: str
    signatures: tuple[PublicSignatureEnvelope, ...]
    _verification_marker: object = field(default=None, repr=False, compare=False)

    def __post_init__(self) -> None:
        _sequence(self.sequence, "composition catalog sequence")
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("composition catalog channel is unsupported")
        if self.expires_at <= self.published_at:
            raise ValueError("composition catalog must expire after publication")
        _digest(self.approved_python_runtime_identity, "approved Python runtime identity")
        if not self.entries or any(not isinstance(entry, CompositionCatalogEntry) for entry in self.entries):
            raise ValueError("composition catalog entries are invalid")
        if any(entry.channel != self.channel for entry in self.entries):
            raise ValueError("composition catalog entry channel must match the catalog channel")
        identities = [entry.composition_id for entry in self.entries]
        if len(identities) != len(set(identities)):
            raise ValueError("composition catalog contains duplicate composition identities")
        if self.component_combination_catalog is not None and not isinstance(
            self.component_combination_catalog,
            DownloadIdentity,
        ):
            raise ValueError("composition catalog component-combination locator is invalid")
        _digest(self.catalog_digest, "composition catalog digest")
        if (
            not isinstance(self.signatures, tuple)
            or not self.signatures
            or any(not isinstance(signature, PublicSignatureEnvelope) for signature in self.signatures)
        ):
            raise ValueError("composition catalog requires public signature envelopes")
        if len({signature.key_id for signature in self.signatures}) != len(self.signatures):
            raise ValueError("composition catalog signature key IDs must be unique")
        if self._verification_marker is not _VERIFIED_COMPOSITION_CATALOG_MARKER:
            raise TypeError("CompositionCatalog must be established from verified signed metadata")

    @classmethod
    def from_signed_metadata(
        cls,
        value: object,
        verifier: InstallerMetadataVerifier,
        *,
        raw_bytes: bytes,
        signature_policy: SignatureThresholdPolicy,
    ) -> "CompositionCatalog":
        """Verify downloaded catalog bytes before parsing their signed contents."""

        if not isinstance(raw_bytes, bytes) or not raw_bytes or len(raw_bytes) > MAXIMUM_COMPOSITION_CATALOG_BYTES:
            raise UniversalInstallerError("composition catalog bytes exceed the native admission limit")
        actual = "sha256:" + sha256(raw_bytes).hexdigest()
        parsed_raw = _strict_json_mapping(
            raw_bytes,
            "composition catalog",
            maximum_nesting_depth=MAXIMUM_COMPOSITION_CATALOG_JSON_NESTING_DEPTH,
            maximum_node_count=MAXIMUM_COMPOSITION_CATALOG_JSON_NODES,
        )
        if not isinstance(value, Mapping) or dict(parsed_raw) != dict(value):
            raise UniversalInstallerError("composition catalog object does not match verified catalog bytes")
        required_fields = frozenset({
            "schema", "sequence", "channel", "published_at", "expires_at",
            "approved_python_runtime_identity", "compositions", "signatures",
        })
        selection_index_fields = required_fields | frozenset({"component_combination_catalog"})
        if not isinstance(value, Mapping) or frozenset(value) not in {required_fields, selection_index_fields}:
            raise ValueError("composition catalog fields are invalid")
        payload = value
        if payload["schema"] != COMPOSITION_CATALOG_SCHEMA:
            raise UniversalInstallerError("composition catalog schema is unsupported")
        signatures = parse_public_signature_envelopes(payload["signatures"], label="composition catalog")
        unsigned = {key: entry for key, entry in payload.items() if key != "signatures"}
        _verify_metadata_signatures(
            _canonical_json(unsigned),
            signatures,
            verifier,
            signature_policy,
            label="composition catalog",
        )
        entries = payload["compositions"]
        if not isinstance(entries, list):
            raise ValueError("composition catalog entries must be a list")
        selection_index = None
        if "component_combination_catalog" in payload:
            locator = _mapping(
                payload["component_combination_catalog"],
                frozenset({"url", "digest"}),
                "component-combination catalog locator",
            )
            selection_index = DownloadIdentity(
                _https_url(locator["url"], "component-combination catalog URL"),
                _digest(locator["digest"], "component-combination catalog digest"),
            )
        return cls(
            sequence=_sequence(payload["sequence"], "composition catalog sequence"),
            channel=_required(payload["channel"], "composition catalog channel"),
            published_at=_timestamp(payload["published_at"], "composition catalog published_at"),
            expires_at=_timestamp(payload["expires_at"], "composition catalog expires_at"),
            approved_python_runtime_identity=_digest(
                payload["approved_python_runtime_identity"],
                "approved Python runtime identity",
            ),
            entries=tuple(CompositionCatalogEntry.from_mapping(entry) for entry in entries),
            component_combination_catalog=selection_index,
            catalog_digest=actual,
            signatures=signatures,
            _verification_marker=_VERIFIED_COMPOSITION_CATALOG_MARKER,
        )

    @classmethod
    def from_signed_bytes(
        cls,
        raw_bytes: bytes,
        verifier: InstallerMetadataVerifier,
        *,
        signature_policy: SignatureThresholdPolicy,
    ) -> "CompositionCatalog":
        """Parse exact, separately signed catalog bytes from the signed feed."""

        if not isinstance(raw_bytes, bytes) or not raw_bytes or len(raw_bytes) > MAXIMUM_COMPOSITION_CATALOG_BYTES:
            raise UniversalInstallerError("composition catalog bytes exceed the native admission limit")
        value = _strict_json_mapping(
            raw_bytes,
            "composition catalog",
            maximum_nesting_depth=MAXIMUM_COMPOSITION_CATALOG_JSON_NESTING_DEPTH,
            maximum_node_count=MAXIMUM_COMPOSITION_CATALOG_JSON_NODES,
        )
        return cls.from_signed_metadata(
            value,
            verifier,
            raw_bytes=raw_bytes,
            signature_policy=signature_policy,
        )

    def selectable_entries(
        self,
        installer_context: VerifiedInstallerContext,
        *,
        now: datetime,
    ) -> tuple[CompositionCatalogEntry, ...]:
        if not isinstance(installer_context, VerifiedInstallerContext):
            raise ValueError("verified installer context is required for catalog selection")
        if self.expires_at <= now.astimezone(timezone.utc):
            raise UniversalInstallerError("composition catalog is expired")
        if self.channel != installer_context.release.channel:
            raise UniversalInstallerError("composition catalog channel does not match the verified installer channel")
        return tuple(
            entry
            for entry in self.entries
            if not entry.installer_requirement.unmet_by(installer_context.capabilities)
        )

    def component_combination_catalog_binding(
        self,
        *,
        outer_catalog_acceptance: "AcceptedCatalogIdentity",
    ) -> "CatalogPublicationBinding":
        """Return the selection-index binding only from this verified catalog.

        The import stays local to avoid a module import cycle: the selection
        policy consumes :class:`CompositionCatalog`, while the signed catalog
        remains the sole owner of the upstream verification boundary.  The
        caller must provide the exact scoped outer-catalog acceptance emitted
        by that boundary; a channel-only component-index anchor is unsafe
        across trust or feed rotation.
        """

        from .composition_catalog import CatalogPublicationBinding

        return CatalogPublicationBinding.from_verified_composition_catalog(
            self,
            outer_catalog_acceptance=outer_catalog_acceptance,
        )


@dataclass(frozen=True)
class CatalogAcceptanceScope:
    """The exact verified-installer context for one catalog anti-replay anchor.

    A catalog signature policy may rotate without discarding its accepted
    provenance.  The anchor is therefore scoped by the current installer's
    raw release-trust configuration, signed channel, and exact feed locator;
    it is never keyed only by a display version or catalog channel.
    """

    installer_release_trust_configuration_sha256: str
    channel: str
    catalog_feed_url: str

    def __post_init__(self) -> None:
        _raw_sha256(
            self.installer_release_trust_configuration_sha256,
            "accepted catalog installer release trust configuration digest",
        )
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("accepted catalog channel is unsupported")
        _https_url(self.catalog_feed_url, "accepted catalog feed URL")

    @classmethod
    def from_verified_installer_context(
        cls,
        installer_context: VerifiedInstallerContext,
    ) -> "CatalogAcceptanceScope":
        if not isinstance(installer_context, VerifiedInstallerContext):
            raise ValueError("verified installer context is required for accepted catalog scope")
        return cls(
            installer_context.release.release_trust_configuration_sha256,
            installer_context.release.channel,
            installer_context.release.composition_catalog_feed.url,
        )


@dataclass(frozen=True)
class AcceptedCatalogIdentity:
    """Candidate durable anti-replay anchor for one scoped signed catalog feed.

    A future operation coordinator persists this only after its resulting
    product operation reaches a verified terminal state. This policy model
    deliberately provides no filesystem persistence or runtime wiring.
    """

    scope: CatalogAcceptanceScope
    sequence: int
    catalog_digest: str

    def __post_init__(self) -> None:
        if not isinstance(self.scope, CatalogAcceptanceScope):
            raise ValueError("accepted catalog scope is invalid")
        _sequence(self.sequence, "accepted catalog sequence")
        _digest(self.catalog_digest, "accepted catalog digest")

    @property
    def installer_release_trust_configuration_sha256(self) -> str:
        """Compatibility projection of the required raw trust scope."""

        return self.scope.installer_release_trust_configuration_sha256

    @property
    def channel(self) -> str:
        """Compatibility projection; an anchor can no longer omit its scope."""

        return self.scope.channel

    @property
    def catalog_feed_url(self) -> str:
        """Exact signed feed locator retained by this anti-replay anchor."""

        return self.scope.catalog_feed_url


@dataclass(frozen=True)
class HostRequirement:
    minimum_macos_version: SemanticVersion
    supported_architectures: frozenset[str]
    minimum_available_disk_bytes: int
    backup_reserve_bytes: int
    minimum_memory_bytes: int
    requires_administrator: bool
    requires_network: bool
    requires_trusted_clock: bool

    def __post_init__(self) -> None:
        if not isinstance(self.minimum_macos_version, SemanticVersion):
            raise ValueError("minimum macOS version must be semantic")
        if self.minimum_macos_version.major < MINIMUM_MACOS_MAJOR:
            raise ValueError("host minimum macOS version must be 26 or newer")
        if self.supported_architectures != INSTALLER_ARCHITECTURES:
            raise ValueError("host supported architectures must be exactly arm64")
        for label in ("minimum_available_disk_bytes", "backup_reserve_bytes", "minimum_memory_bytes"):
            value = getattr(self, label)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ValueError(f"{label} must be a non-negative integer")
        for label in ("requires_administrator", "requires_network", "requires_trusted_clock"):
            if not isinstance(getattr(self, label), bool):
                raise ValueError(f"{label} must be boolean")


@dataclass(frozen=True)
class HostFacts:
    """Read-only observations.  No PATH-derived component observation belongs here."""

    operating_system: str
    macos_version: SemanticVersion
    architecture: str
    available_disk_bytes: int
    memory_bytes: int
    administrator_authorized: bool
    network_available: bool
    trusted_clock: bool
    hardware_architecture: str
    is_rosetta_translated: bool

    def __post_init__(self) -> None:
        if self.operating_system != "macos":
            raise ValueError("universal installer currently supports only macos")
        if not isinstance(self.macos_version, SemanticVersion):
            raise ValueError("macOS version must be semantic")
        if self.architecture not in OBSERVABLE_MACOS_ARCHITECTURES:
            raise ValueError("host process architecture is unsupported")
        if self.hardware_architecture not in OBSERVABLE_MACOS_ARCHITECTURES:
            raise ValueError("host hardware architecture is unsupported")
        for label in ("available_disk_bytes", "memory_bytes"):
            value = getattr(self, label)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ValueError(f"{label} must be a non-negative integer")
        for label in ("administrator_authorized", "network_available", "trusted_clock"):
            if not isinstance(getattr(self, label), bool):
                raise ValueError(f"{label} must be boolean")
        if not isinstance(self.is_rosetta_translated, bool):
            raise ValueError("is_rosetta_translated must be boolean")


@dataclass(frozen=True)
class HostPreflight:
    state: str
    failures: tuple[str, ...]
    facts: HostFacts

    def __post_init__(self) -> None:
        if self.state not in {"PASS", "BLOCKED"}:
            raise ValueError("unsupported host preflight state")
        if not isinstance(self.facts, HostFacts):
            raise ValueError("host preflight facts are invalid")
        if self.state == "PASS" and self.failures:
            raise ValueError("passing host preflight cannot retain failures")
        if self.state == "BLOCKED" and not self.failures:
            raise ValueError("blocked host preflight requires failures")

    @property
    def permits_platform_mutation(self) -> bool:
        return self.state == "PASS"


def preflight_host(requirement: HostRequirement, facts: HostFacts) -> HostPreflight:
    """Evaluate the explicit composition requirements without altering the host."""

    if not isinstance(requirement, HostRequirement) or not isinstance(facts, HostFacts):
        raise ValueError("host requirement and facts are required")
    failures: list[str] = []
    if facts.macos_version.major < MINIMUM_MACOS_MAJOR:
        failures.append("macOS 26 or newer is required by the installer platform")
    if facts.architecture != INSTALLER_ARCHITECTURE:
        failures.append("the installer process must run natively as arm64")
    if facts.hardware_architecture != INSTALLER_ARCHITECTURE:
        failures.append("Apple Silicon hardware is required")
    if facts.is_rosetta_translated:
        failures.append("running the installer under Rosetta is not supported")
    if facts.macos_version < requirement.minimum_macos_version:
        failures.append(f"macOS {requirement.minimum_macos_version} or newer is required")
    if facts.architecture not in requirement.supported_architectures:
        failures.append(f"architecture {facts.architecture} is not supported by this composition")
    required_disk = requirement.minimum_available_disk_bytes + requirement.backup_reserve_bytes
    if facts.available_disk_bytes < required_disk:
        failures.append("insufficient free disk space including required backup reserve")
    if facts.memory_bytes < requirement.minimum_memory_bytes:
        failures.append("insufficient memory")
    if requirement.requires_administrator and not facts.administrator_authorized:
        failures.append("administrator authorization is required for system LaunchDaemons")
    if requirement.requires_network and not facts.network_available:
        failures.append("network connectivity is required")
    if requirement.requires_trusted_clock and not facts.trusted_clock:
        failures.append("trusted system time is required")
    return HostPreflight("PASS" if not failures else "BLOCKED", tuple(failures), facts)


@dataclass(frozen=True)
class ManagedToolRequirement:
    """A toolchain managed under the installer root, never a global/PATH replacement."""

    identity: str
    version: SemanticVersion
    artifact: DownloadIdentity

    def __post_init__(self) -> None:
        if self.identity not in MANAGED_TOOL_IDENTITIES:
            raise ValueError("managed tool identity is unsupported")
        if not isinstance(self.version, SemanticVersion):
            raise ValueError("managed tool version must be semantic")
        if not isinstance(self.artifact, DownloadIdentity):
            raise ValueError("managed tool requires an immutable artifact")


@dataclass(frozen=True)
class ManagedToolReadback:
    """A non-PATH observation from an installer-owned managed tool root."""

    identity: str
    state: str
    version: SemanticVersion | None
    artifact_digest: str | None
    managed_root_identity: str | None
    evidence_reference: str

    def __post_init__(self) -> None:
        if self.identity not in MANAGED_TOOL_IDENTITIES:
            raise ValueError("managed tool identity is unsupported")
        if self.state not in TOOL_STATES:
            raise ValueError("managed tool state is unsupported")
        _required(self.evidence_reference, "managed tool evidence_reference")
        if self.state == "ACTIVE":
            if not isinstance(self.version, SemanticVersion):
                raise ValueError("active managed tool requires a version")
            _digest(self.artifact_digest, "active managed tool artifact_digest")
            _required(self.managed_root_identity, "active managed tool managed_root_identity")
        elif any(value is not None for value in (self.version, self.artifact_digest, self.managed_root_identity)):
            raise ValueError("absent or unknown managed tool cannot identify a tool runtime")


@dataclass(frozen=True)
class ManagedToolAction:
    identity: str
    action: str
    reason: str
    requirement: ManagedToolRequirement
    readback: ManagedToolReadback

    def __post_init__(self) -> None:
        if self.action not in {"INSTALL", "UPGRADE", "NO_CHANGE", "BLOCKED"}:
            raise ValueError("managed tool action is unsupported")
        _required(self.reason, "managed tool action reason")
        if self.identity != self.requirement.identity or self.identity != self.readback.identity:
            raise ValueError("managed tool action identity mismatch")


def plan_managed_tools(
    requirements: Iterable[ManagedToolRequirement],
    readbacks: Mapping[str, ManagedToolReadback],
) -> tuple[ManagedToolAction, ...]:
    """Plan generic managed tools; Python has a stronger, separate contract."""

    result: list[ManagedToolAction] = []
    identities: set[str] = set()
    for requirement in requirements:
        if not isinstance(requirement, ManagedToolRequirement):
            raise ValueError("managed tool requirements are invalid")
        if requirement.identity in identities:
            raise ValueError("managed tool requirements contain a duplicate identity")
        identities.add(requirement.identity)
        readback = readbacks.get(requirement.identity)
        if not isinstance(readback, ManagedToolReadback):
            raise UniversalInstallerError(f"managed tool {requirement.identity} lacks a trusted readback")
        if readback.state == "UNKNOWN":
            result.append(ManagedToolAction(requirement.identity, "BLOCKED", "managed tool inventory is unknown", requirement, readback))
        elif readback.state == "ABSENT":
            result.append(ManagedToolAction(requirement.identity, "INSTALL", "required managed tool is absent", requirement, readback))
        elif readback.version == requirement.version and readback.artifact_digest == requirement.artifact.digest:
            result.append(ManagedToolAction(requirement.identity, "NO_CHANGE", "exact managed tool is active", requirement, readback))
        else:
            result.append(ManagedToolAction(requirement.identity, "UPGRADE", "managed tool differs from exact required identity", requirement, readback))
    return tuple(result)


@dataclass(frozen=True)
class ManagedPythonRuntimeReadback:
    """Trusted observation from the installer-owned Python root, never PATH."""

    state: str
    runtime_identity: str | None
    managed_root_identity: str | None
    runtime_slot_identity: str | None
    retained_runtime_identities: tuple[str, ...]
    evidence_reference: str

    def __post_init__(self) -> None:
        if self.state not in TOOL_STATES:
            raise ValueError("managed Python runtime state is unsupported")
        _required(self.evidence_reference, "managed Python readback evidence_reference")
        if not isinstance(self.retained_runtime_identities, tuple):
            raise ValueError("managed Python retained runtime identities must be a tuple")
        for identity in self.retained_runtime_identities:
            _digest(identity, "retained managed Python runtime identity")
        if len(set(self.retained_runtime_identities)) != len(self.retained_runtime_identities):
            raise ValueError("managed Python retained runtime identities must be unique")
        if self.state == "ACTIVE":
            identity = _digest(self.runtime_identity, "active managed Python runtime identity")
            if self.managed_root_identity != MANAGED_PYTHON_ROOT_IDENTITY:
                raise ValueError("active managed Python runtime is outside the installer-owned root")
            expected_slot = "sha256-" + identity.removeprefix("sha256:")
            if self.runtime_slot_identity != expected_slot:
                raise ValueError("active managed Python slot does not match its exact runtime identity")
        elif any(
            value is not None
            for value in (self.runtime_identity, self.managed_root_identity, self.runtime_slot_identity)
        ) or self.retained_runtime_identities:
            raise ValueError("absent or unknown managed Python readback cannot identify runtime slots")


@dataclass(frozen=True)
class ManagedPythonRuntimeAction:
    action: str
    reason: str
    requirement: ManagedPythonRuntimeIdentity
    readback: ManagedPythonRuntimeReadback
    rollback_runtime_identity: str | None

    def __post_init__(self) -> None:
        if self.action not in {"INSTALL", "UPGRADE", "NO_CHANGE", "BLOCKED"}:
            raise ValueError("managed Python runtime action is unsupported")
        _required(self.reason, "managed Python runtime action reason")
        if not isinstance(self.requirement, ManagedPythonRuntimeIdentity) or not isinstance(
            self.readback,
            ManagedPythonRuntimeReadback,
        ):
            raise ValueError("managed Python runtime action inputs are invalid")
        if self.rollback_runtime_identity is not None:
            _digest(self.rollback_runtime_identity, "managed Python rollback runtime identity")
        if self.action == "UPGRADE" and self.rollback_runtime_identity != self.readback.runtime_identity:
            raise ValueError("managed Python upgrade must retain the active runtime for rollback")
        if self.action != "UPGRADE" and self.rollback_runtime_identity is not None:
            raise ValueError("only a managed Python upgrade can bind a rollback runtime")


def plan_managed_python_runtime(
    requirement: ManagedPythonRuntimeIdentity,
    readback: ManagedPythonRuntimeReadback,
) -> ManagedPythonRuntimeAction:
    """Select only the signed exact runtime and retain an upgrade rollback identity."""

    if not isinstance(requirement, ManagedPythonRuntimeIdentity) or not isinstance(
        readback,
        ManagedPythonRuntimeReadback,
    ):
        raise ValueError("managed Python requirement and trusted readback are required")
    if readback.state == "UNKNOWN":
        return ManagedPythonRuntimeAction(
            "BLOCKED", "managed Python runtime inventory is unknown", requirement, readback, None
        )
    if readback.state == "ABSENT":
        return ManagedPythonRuntimeAction(
            "INSTALL", "approved managed Python runtime is absent", requirement, readback, None
        )
    if readback.runtime_identity == requirement.identity_digest:
        return ManagedPythonRuntimeAction(
            "NO_CHANGE", "exact approved managed Python runtime is active", requirement, readback, None
        )
    return ManagedPythonRuntimeAction(
        "UPGRADE",
        "active managed Python runtime differs from the exact approved identity",
        requirement,
        readback,
        readback.runtime_identity,
    )


def _provider_binding_key(identity: str, owner_component: str | None, target_identity: str | None) -> str:
    if owner_component is None and target_identity is None:
        return identity
    if owner_component is None or target_identity is None:
        raise ValueError("provider target requires owner_component and target_identity together")
    return f"{identity}:{owner_component}:{target_identity}"


def _validate_provider_target(
    identity: str,
    credential_scope: str,
    owner_component: str | None,
    target_identity: str | None,
) -> None:
    if identity not in PROVIDER_IDENTITIES:
        raise ValueError("provider identity is unsupported")
    if owner_component is None and target_identity is None:
        if credential_scope != "user":
            raise ValueError("provider credentials must remain user-scoped")
        return
    if credential_scope not in PROVIDER_CREDENTIAL_SCOPES:
        raise ValueError("provider credential_scope is unsupported")
    if owner_component not in PROVIDER_OWNER_COMPONENTS:
        raise ValueError("provider owner_component is unsupported")
    if not isinstance(target_identity, str) or _SAFE_TARGET_ID.fullmatch(target_identity) is None:
        raise ValueError("provider target_identity must be a safe opaque identifier")
    expected_scope = (
        "user"
        if owner_component == "engineering-platform-project-agent"
        else "component"
    )
    if credential_scope != expected_scope:
        raise ValueError(
            f"provider target {owner_component} requires {expected_scope}-owned credentials"
        )


@dataclass(frozen=True)
class ProviderRequirement:
    """One provider requirement bound to its owning component-instance target.

    Legacy composition/v1 requirements omit the target and remain user-scoped.
    composition/v2 requirements identify an owning component plus an immutable
    target binding so the same human provider can back multiple isolated
    runtime/auth contexts without conflating them.
    """

    identity: str
    required: bool
    minimum_version: SemanticVersion | None
    credential_scope: str = "user"
    owner_component: str | None = None
    target_identity: str | None = None

    def __post_init__(self) -> None:
        _validate_provider_target(
            self.identity, self.credential_scope, self.owner_component, self.target_identity
        )
        if not isinstance(self.required, bool):
            raise ValueError("provider required must be boolean")
        if self.minimum_version is not None and not isinstance(self.minimum_version, SemanticVersion):
            raise ValueError("provider minimum version must be semantic")

    @property
    def key(self) -> str:
        return _provider_binding_key(self.identity, self.owner_component, self.target_identity)


@dataclass(frozen=True)
class ProviderSelection:
    identity: str
    enabled: bool
    owner_component: str | None = None
    target_identity: str | None = None

    def __post_init__(self) -> None:
        if self.identity not in PROVIDER_IDENTITIES:
            raise ValueError("provider selection identity is unsupported")
        if not isinstance(self.enabled, bool):
            raise ValueError("provider selection enabled must be boolean")
        if (self.owner_component is None) != (self.target_identity is None):
            raise ValueError("provider selection target is incomplete")
        if self.owner_component is not None:
            if self.owner_component not in PROVIDER_OWNER_COMPONENTS:
                raise ValueError("provider selection owner_component is unsupported")
            if not isinstance(self.target_identity, str) or _SAFE_TARGET_ID.fullmatch(self.target_identity) is None:
                raise ValueError("provider selection target_identity is invalid")

    @property
    def key(self) -> str:
        return _provider_binding_key(self.identity, self.owner_component, self.target_identity)


@dataclass(frozen=True)
class ProviderReadback:
    """Non-secret provider evidence for one exact owning target."""

    identity: str
    state: str
    version: SemanticVersion | None
    executable_identity: str | None
    evidence_reference: str
    owner_component: str | None = None
    target_identity: str | None = None

    def __post_init__(self) -> None:
        if self.identity not in PROVIDER_IDENTITIES:
            raise ValueError("provider identity is unsupported")
        if self.state not in PROVIDER_STATES:
            raise ValueError("provider state is unsupported")
        if (self.owner_component is None) != (self.target_identity is None):
            raise ValueError("provider readback target is incomplete")
        if self.owner_component is not None:
            if self.owner_component not in PROVIDER_OWNER_COMPONENTS:
                raise ValueError("provider readback owner_component is unsupported")
            if not isinstance(self.target_identity, str) or _SAFE_TARGET_ID.fullmatch(self.target_identity) is None:
                raise ValueError("provider readback target_identity is invalid")
        _required(self.evidence_reference, "provider evidence_reference")
        if self.state == "VERIFIED":
            if not isinstance(self.version, SemanticVersion):
                raise ValueError("verified provider requires a version")
            _required(self.executable_identity, "verified provider executable_identity")
        elif self.executable_identity is not None:
            _required(self.executable_identity, "provider executable_identity")

    @property
    def key(self) -> str:
        return _provider_binding_key(self.identity, self.owner_component, self.target_identity)


@dataclass(frozen=True)
class ProviderAction:
    identity: str
    action: str
    reason: str
    readback: ProviderReadback | None
    owner_component: str | None = None
    target_identity: str | None = None

    def __post_init__(self) -> None:
        if self.identity not in PROVIDER_IDENTITIES:
            raise ValueError("provider action identity is unsupported")
        if self.action not in {"INSTALL", "AUTHENTICATE", "VERIFY", "NO_CHANGE", "RESOLVE_FAILURE"}:
            raise ValueError("provider action is unsupported")
        if (self.owner_component is None) != (self.target_identity is None):
            raise ValueError("provider action target is incomplete")
        _required(self.reason, "provider action reason")
        if self.readback is not None and self.readback.key != self.key:
            raise ValueError("provider action readback target mismatch")

    @property
    def key(self) -> str:
        return _provider_binding_key(self.identity, self.owner_component, self.target_identity)


@dataclass(frozen=True)
class ProviderGate:
    """The wizard advances only when every enabled provider target is verified."""

    required: tuple[str, ...]
    actions: tuple[ProviderAction, ...]
    blocking_providers: tuple[str, ...]

    def __post_init__(self) -> None:
        if len(set(self.required)) != len(self.required):
            raise ValueError("provider gate requirements are duplicated")
        action_ids = tuple(action.key for action in self.actions)
        if len(set(action_ids)) != len(action_ids):
            raise ValueError("provider gate actions are duplicated")
        if tuple(sorted(self.blocking_providers)) != self.blocking_providers:
            raise ValueError("provider gate blockers must be sorted")
        if not set(self.blocking_providers) <= set(self.required):
            raise ValueError("provider gate blockers must be required provider targets")

    @property
    def permits_platform_mutation(self) -> bool:
        return not self.blocking_providers


def provider_command(identity: str, action: str) -> tuple[str, ...]:
    """Return a fixed vendor command, never a caller-supplied shell command.

    Installation itself is delegated to a verified provider artifact handler;
    these command descriptors are limited to user-visible auth/status flow.
    Their output must not be stored in installer receipts or logs.
    """

    commands = {
        ("codex", "VERIFY"): ("codex", "login", "status"),
        ("codex", "AUTHENTICATE"): ("codex", "login", "--device-auth"),
        ("github-cli", "VERIFY"): ("gh", "auth", "status", "--active", "--hostname", "github.com"),
        ("github-cli", "AUTHENTICATE"): ("gh", "auth", "login", "--web", "--hostname", "github.com"),
    }
    try:
        return commands[(identity, action)]
    except KeyError as error:
        raise ValueError("provider action has no fixed command descriptor") from error


def evaluate_provider_gate(
    requirements: Iterable[ProviderRequirement],
    selections: Mapping[str, ProviderSelection],
    readbacks: Mapping[str, ProviderReadback],
) -> ProviderGate:
    """Evaluate exact provider targets without storing or interpreting credentials."""

    requirements_by_id: dict[str, ProviderRequirement] = {}
    for requirement in requirements:
        if not isinstance(requirement, ProviderRequirement):
            raise ValueError("provider requirements are invalid")
        if requirement.key in requirements_by_id:
            raise ValueError("provider requirements contain a duplicate target binding")
        requirements_by_id[requirement.key] = requirement
    if set(selections) - set(requirements_by_id) or set(readbacks) - set(requirements_by_id):
        raise ValueError("provider selections/readbacks must belong to the composition requirements")
    actions: list[ProviderAction] = []
    blocking: list[str] = []
    enabled_requirements: list[str] = []
    for key in sorted(requirements_by_id):
        requirement = requirements_by_id[key]
        selection = selections.get(
            key,
            ProviderSelection(
                requirement.identity,
                requirement.required,
                requirement.owner_component,
                requirement.target_identity,
            ),
        )
        if not isinstance(selection, ProviderSelection) or selection.key != key:
            raise ValueError("provider selection is invalid")
        if requirement.required and not selection.enabled:
            raise UniversalInstallerError(f"required provider target {key} cannot be deselected")
        if not selection.enabled:
            continue
        enabled_requirements.append(key)
        readback = readbacks.get(key)
        action_args = (requirement.owner_component, requirement.target_identity)
        if readback is None:
            actions.append(ProviderAction(
                requirement.identity, "INSTALL", "provider target has not been inventoried", None, *action_args
            ))
            blocking.append(key)
            continue
        if not isinstance(readback, ProviderReadback) or readback.key != key:
            raise ValueError("provider readback is invalid")
        if readback.state == "ABSENT":
            actions.append(ProviderAction(
                requirement.identity, "INSTALL", "provider target is absent", readback, *action_args
            ))
            blocking.append(key)
        elif readback.state in {"INSTALLED", "AUTHENTICATION_REQUIRED"}:
            actions.append(ProviderAction(
                requirement.identity, "AUTHENTICATE", "provider target authentication is required", readback, *action_args
            ))
            blocking.append(key)
        elif readback.state == "FAILED":
            actions.append(ProviderAction(
                requirement.identity, "RESOLVE_FAILURE", "provider target validation failed", readback, *action_args
            ))
            blocking.append(key)
        elif requirement.minimum_version is not None and readback.version < requirement.minimum_version:
            actions.append(ProviderAction(
                requirement.identity, "INSTALL", "provider target is older than the qualified minimum", readback, *action_args
            ))
            blocking.append(key)
        else:
            actions.append(ProviderAction(
                requirement.identity, "NO_CHANGE", "provider target is installed and authenticated", readback, *action_args
            ))
    return ProviderGate(tuple(enabled_requirements), tuple(actions), tuple(sorted(blocking)))


@dataclass(frozen=True)
class SystemServiceContract:
    """The only supported server service form on macOS: a system LaunchDaemon."""

    manager: str
    domain: str
    kind: str
    product_service_reference: str

    def __post_init__(self) -> None:
        if self.manager != "launchd" or self.domain != "system" or self.kind != "LaunchDaemon":
            raise ValueError("server services must be system-domain launchd LaunchDaemons")
        _required(self.product_service_reference, "product_service_reference")


@dataclass(frozen=True)
class PythonRuntimeQualification:
    """Product-owned build and test evidence for one exact Python identity."""

    runtime_identity_digest: str
    build_evidence: DownloadIdentity
    test_evidence: DownloadIdentity

    def __post_init__(self) -> None:
        _digest(self.runtime_identity_digest, "component Python runtime identity")
        if not isinstance(self.build_evidence, DownloadIdentity) or not isinstance(
            self.test_evidence,
            DownloadIdentity,
        ):
            raise ValueError("component Python qualification evidence is invalid")


@dataclass(frozen=True)
class ProductVenvRequirement:
    """A product-isolated venv identity, with no caller-controlled filesystem path."""

    component_identity: str
    venv_identity: str
    python_runtime_identity: str

    def __post_init__(self) -> None:
        if self.component_identity not in COMPONENT_IDENTITIES:
            raise ValueError("product venv component identity is unsupported")
        if not _SAFE_TARGET_ID.fullmatch(self.venv_identity):
            raise ValueError("product venv identity must be a safe opaque identifier")
        _digest(self.python_runtime_identity, "product venv Python runtime identity")


@dataclass(frozen=True)
class CompositionComponent:
    identity: str
    role: str
    artifact: QualifiedArtifact
    python_runtime_qualification: PythonRuntimeQualification
    service: SystemServiceContract | None

    def __post_init__(self) -> None:
        if self.identity not in COMPONENT_IDENTITIES:
            raise ValueError("composition component identity is unsupported")
        _required(self.role, "composition component role")
        if not isinstance(self.artifact, QualifiedArtifact):
            raise ValueError("composition component requires a qualified artifact")
        if not isinstance(self.python_runtime_qualification, PythonRuntimeQualification):
            raise ValueError("composition component requires exact Python build and test evidence")
        if self.identity in SERVICE_COMPONENTS and not isinstance(self.service, SystemServiceContract):
            raise ValueError("server composition component requires a system LaunchDaemon contract")
        if self.identity in LOCAL_COMPONENTS and self.service is not None:
            raise ValueError("local components cannot be modelled as system LaunchDaemons")


@dataclass(frozen=True)
class CompositionManifest:
    """An immutable qualified component composition, parsed after its digest check."""

    composition_id: str
    channel: str
    manifest_digest: str
    installer_requirement: InstallerRequirement
    host_requirement: HostRequirement
    managed_tools: tuple[ManagedToolRequirement, ...]
    python_runtime: ManagedPythonRuntimeIdentity
    product_venvs: tuple[ProductVenvRequirement, ...]
    providers: tuple[ProviderRequirement, ...]
    components: tuple[CompositionComponent, ...]
    upgrade_from: tuple[str, ...]

    def __post_init__(self) -> None:
        _composition_catalog_id(self.composition_id, "composition_id")
        if self.channel not in INSTALLER_CHANNELS:
            raise ValueError("composition channel is unsupported")
        _digest(self.manifest_digest, "composition manifest_digest")
        if not isinstance(self.installer_requirement, InstallerRequirement):
            raise ValueError("composition installer requirement is invalid")
        if not isinstance(self.host_requirement, HostRequirement):
            raise ValueError("composition host requirement is invalid")
        if not isinstance(self.python_runtime, ManagedPythonRuntimeIdentity):
            raise ValueError("composition managed Python runtime is invalid")
        for label, items, expected_type, identity in (
            ("managed tools", self.managed_tools, ManagedToolRequirement, "identity"),
            ("components", self.components, CompositionComponent, "identity"),
        ):
            if not items or any(not isinstance(item, expected_type) for item in items):
                raise ValueError(f"composition {label} are invalid")
            values = [getattr(item, identity) for item in items]
            if len(values) != len(set(values)):
                raise ValueError(f"composition {label} contain duplicate identities")
        if any(not isinstance(provider, ProviderRequirement) for provider in self.providers):
            raise ValueError("composition providers are invalid")
        provider_bindings = [provider.key for provider in self.providers]
        if len(provider_bindings) != len(set(provider_bindings)):
            raise ValueError("composition providers contain duplicate target bindings")
        service_references = [
            component.service.product_service_reference
            for component in self.components
            if component.service is not None
        ]
        if len(service_references) != len(set(service_references)):
            raise ValueError("composition system service references must be unique")
        if any(not isinstance(venv, ProductVenvRequirement) for venv in self.product_venvs):
            raise ValueError("composition product venv requirements are invalid")
        component_identities = {component.identity for component in self.components}
        if {venv.component_identity for venv in self.product_venvs} != component_identities:
            raise ValueError("composition requires exactly one product venv for every component")
        if len(self.product_venvs) != len(component_identities):
            raise ValueError("composition product venv component identities must be unique")
        venv_identities = [venv.venv_identity for venv in self.product_venvs]
        if len(venv_identities) != len(set(venv_identities)):
            raise ValueError("composition product venv identities must be unique")
        if any(
            venv.python_runtime_identity != self.python_runtime.identity_digest
            for venv in self.product_venvs
        ):
            raise ValueError("composition product venvs must bind the approved Python runtime")
        if any(
            component.python_runtime_qualification.runtime_identity_digest
            != self.python_runtime.identity_digest
            for component in self.components
        ):
            raise ValueError("composition components must be built and tested against the approved Python runtime")
        if not isinstance(self.upgrade_from, tuple):
            raise ValueError("composition upgrade_from is invalid")
        for identity in self.upgrade_from:
            _composition_catalog_id(identity, "composition upgrade_from")
        if len(set(self.upgrade_from)) != len(self.upgrade_from):
            raise ValueError("composition upgrade_from is invalid")

    @classmethod
    def from_catalog_bytes(
        cls,
        entry: CompositionCatalogEntry,
        raw_bytes: bytes,
    ) -> "CompositionManifest":
        """Parse exactly the manifest bytes bound by a verified catalog entry."""

        if not isinstance(entry, CompositionCatalogEntry):
            raise ValueError("verified composition catalog entry is required")
        actual = "sha256:" + sha256(raw_bytes).hexdigest()
        if actual != entry.manifest.digest:
            raise UniversalInstallerError("composition manifest bytes do not match the catalog digest")
        manifest = cls._from_verified_mapping(
            _strict_json_mapping(raw_bytes, "composition manifest"),
            manifest_digest=entry.manifest.digest,
        )
        if manifest.composition_id != entry.composition_id or manifest.channel != entry.channel:
            raise UniversalInstallerError("composition manifest identity does not match the verified catalog entry")
        if manifest.installer_requirement != entry.installer_requirement:
            raise UniversalInstallerError("composition manifest installer requirement does not match the verified catalog entry")
        return manifest

    @classmethod
    def _from_verified_mapping(cls, value: object, *, manifest_digest: str) -> "CompositionManifest":
        """Internal parser used only after a catalog digest binds raw bytes."""
        payload = _mapping(
            value,
            frozenset({"schema", "composition_id", "channel", "requires_installer", "host_requirements", "managed_tools", "python_runtime", "product_venvs", "providers", "components", "upgrade_from"}),
            "composition manifest",
        )
        manifest_schema = payload["schema"]
        if manifest_schema not in COMPOSITION_SCHEMAS:
            raise UniversalInstallerError("composition manifest schema is unsupported")
        installer = _mapping(payload["requires_installer"], frozenset({"minimum_version", "capabilities"}), "installer requirement")
        capabilities = installer["capabilities"]
        if not isinstance(capabilities, list):
            raise ValueError("installer capabilities must be a list")
        host = _mapping(
            payload["host_requirements"],
            frozenset({"minimum_macos_version", "supported_architectures", "minimum_available_disk_bytes", "backup_reserve_bytes", "minimum_memory_bytes", "requires_administrator", "requires_network", "requires_trusted_clock"}),
            "host requirements",
        )
        architectures = host["supported_architectures"]
        if not isinstance(architectures, list):
            raise ValueError("host supported_architectures must be a list")
        return cls(
            composition_id=_composition_catalog_id(payload["composition_id"], "composition_id"),
            channel=_required(payload["channel"], "composition channel"),
            manifest_digest=_digest(manifest_digest, "composition manifest_digest"),
            installer_requirement=InstallerRequirement(
                SemanticVersion.parse(installer["minimum_version"], "minimum installer version"),
                frozenset(_required(capability, "installer capability") for capability in capabilities),
            ),
            host_requirement=HostRequirement(
                SemanticVersion.parse(host["minimum_macos_version"], "minimum macOS version"),
                frozenset(_required(architecture, "host architecture") for architecture in architectures),
                _nonnegative_int(host["minimum_available_disk_bytes"], "minimum_available_disk_bytes"),
                _nonnegative_int(host["backup_reserve_bytes"], "backup_reserve_bytes"),
                _nonnegative_int(host["minimum_memory_bytes"], "minimum_memory_bytes"),
                _boolean(host["requires_administrator"], "requires_administrator"),
                _boolean(host["requires_network"], "requires_network"),
                _boolean(host["requires_trusted_clock"], "requires_trusted_clock"),
            ),
            managed_tools=_parse_managed_tools(payload["managed_tools"]),
            python_runtime=ManagedPythonRuntimeIdentity.from_mapping(payload["python_runtime"]),
            product_venvs=_parse_product_venvs(payload["product_venvs"]),
            providers=_parse_providers(payload["providers"], schema=manifest_schema),
            components=_parse_components(payload["components"]),
            upgrade_from=tuple(
                _composition_catalog_id(identity, "composition upgrade_from")
                for identity in _parse_string_list(payload["upgrade_from"], "upgrade_from")
            ),
        )


def _boolean(value: object, label: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{label} must be boolean")
    return value


def _parse_string_list(value: object, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list")
    return tuple(_required(item, label) for item in value)


def _parse_managed_tools(value: object) -> tuple[ManagedToolRequirement, ...]:
    if not isinstance(value, list):
        raise ValueError("managed_tools must be a list")
    result = []
    for entry in value:
        item = _mapping(entry, frozenset({"identity", "version", "url", "digest"}), "managed tool")
        result.append(ManagedToolRequirement(
            _required(item["identity"], "managed tool identity"),
            SemanticVersion.parse(item["version"], "managed tool version"),
            DownloadIdentity(_https_url(item["url"], "managed tool URL"), _digest(item["digest"], "managed tool digest")),
        ))
    return tuple(result)


def _parse_product_venvs(value: object) -> tuple[ProductVenvRequirement, ...]:
    if not isinstance(value, list):
        raise ValueError("product_venvs must be a list")
    result = []
    for entry in value:
        item = _mapping(
            entry,
            frozenset({"component_identity", "venv_identity", "python_runtime_identity"}),
            "product venv",
        )
        result.append(ProductVenvRequirement(
            _required(item["component_identity"], "product venv component_identity"),
            _required(item["venv_identity"], "product venv venv_identity"),
            _digest(item["python_runtime_identity"], "product venv python_runtime_identity"),
        ))
    return tuple(result)


def _parse_providers(value: object, *, schema: str = COMPOSITION_SCHEMA) -> tuple[ProviderRequirement, ...]:
    if not isinstance(value, list):
        raise ValueError("providers must be a list")
    result = []
    for entry in value:
        if schema == COMPOSITION_SCHEMA:
            item = _mapping(
                entry,
                frozenset({"identity", "required", "minimum_version", "credential_scope"}),
                "provider",
            )
            owner_component = None
            target_identity = None
        elif schema == COMPOSITION_SCHEMA_V2:
            item = _mapping(
                entry,
                frozenset({
                    "identity", "required", "minimum_version", "credential_scope",
                    "owner_component", "target_identity",
                }),
                "provider",
            )
            owner_component = _required(item["owner_component"], "provider owner_component")
            target_identity = _required(item["target_identity"], "provider target_identity")
        else:
            raise ValueError("provider schema is unsupported")
        version = item["minimum_version"]
        result.append(ProviderRequirement(
            _required(item["identity"], "provider identity"),
            _boolean(item["required"], "provider required"),
            None if version is None else SemanticVersion.parse(version, "provider minimum_version"),
            _required(item["credential_scope"], "provider credential_scope"),
            owner_component,
            target_identity,
        ))
    return tuple(result)


def _parse_components(value: object) -> tuple[CompositionComponent, ...]:
    if not isinstance(value, list):
        raise ValueError("components must be a list")
    result = []
    for entry in value:
        item = _mapping(
            entry,
            frozenset({"identity", "role", "artifact", "python_runtime_qualification", "service"}),
            "composition component",
        )
        artifact = _mapping(item["artifact"], frozenset({"version", "source_revision", "source", "digest", "qualification"}), "component artifact")
        python_qualification = _mapping(
            item["python_runtime_qualification"],
            frozenset({"runtime_identity_digest", "build_evidence", "test_evidence"}),
            "component Python runtime qualification",
        )

        def evidence(name: str) -> DownloadIdentity:
            locator = _mapping(
                python_qualification[name],
                frozenset({"url", "digest"}),
                f"component Python {name}",
            )
            return DownloadIdentity(
                _https_url(locator["url"], f"component Python {name} URL"),
                _digest(locator["digest"], f"component Python {name} digest"),
            )

        service_value = item["service"]
        service = None
        if service_value is not None:
            service_payload = _mapping(service_value, frozenset({"manager", "domain", "kind", "product_service_reference"}), "system service")
            service = SystemServiceContract(
                _required(service_payload["manager"], "service manager"),
                _required(service_payload["domain"], "service domain"),
                _required(service_payload["kind"], "service kind"),
                _required(service_payload["product_service_reference"], "product service reference"),
            )
        result.append(CompositionComponent(
            _required(item["identity"], "component identity"),
            _required(item["role"], "component role"),
            QualifiedArtifact(
                _required(artifact["version"], "component version"),
                _required(artifact["source_revision"], "component source_revision"),
                _https_url(artifact["source"], "component source"),
                _digest(artifact["digest"], "component digest"),
                _required(artifact["qualification"], "component qualification"),
            ),
            PythonRuntimeQualification(
                _digest(
                    python_qualification["runtime_identity_digest"],
                    "component Python runtime identity",
                ),
                evidence("build_evidence"),
                evidence("test_evidence"),
            ),
            service,
        ))
    return tuple(result)


@dataclass(frozen=True)
class InstalledCompositionIdentity:
    """The last successful immutable composition recorded by the installer.

    Product readbacks establish component state; this separate record establishes
    whether a multi-product route is explicitly approved by ``upgrade_from``.
    """

    composition_id: str
    manifest_digest: str

    def __post_init__(self) -> None:
        _composition_catalog_id(self.composition_id, "installed composition_id")
        _digest(self.manifest_digest, "installed composition manifest_digest")


_VERIFIED_COMPOSITION_SELECTION_MARKER = object()


@dataclass(frozen=True, init=False)
class VerifiedCompositionSelection:
    """A manifest selection bound to the current installer and signed catalog.

    This prevents a planner caller from splicing a hand-built manifest, a catalog
    fetched from another feed, or a replayed catalog into a current installer
    context. The caller persists ``catalog_identity`` only after its resulting
    product operation reaches a verified terminal state.
    """

    installer_context: VerifiedInstallerContext
    catalog: CompositionCatalog
    catalog_identity: AcceptedCatalogIdentity
    entry: CompositionCatalogEntry
    manifest: CompositionManifest

    def __init__(
        self,
        installer_context: VerifiedInstallerContext,
        catalog: CompositionCatalog,
        catalog_identity: AcceptedCatalogIdentity,
        entry: CompositionCatalogEntry,
        manifest: CompositionManifest,
        *,
        _marker: object,
    ) -> None:
        if _marker is not _VERIFIED_COMPOSITION_SELECTION_MARKER:
            raise TypeError("VerifiedCompositionSelection must be established from a signed catalog feed")
        if not isinstance(installer_context, VerifiedInstallerContext) or not isinstance(catalog, CompositionCatalog):
            raise ValueError("verified installer context and composition catalog are required")
        if not isinstance(catalog_identity, AcceptedCatalogIdentity) or not isinstance(entry, CompositionCatalogEntry):
            raise ValueError("verified catalog identity and entry are required")
        if not isinstance(manifest, CompositionManifest):
            raise ValueError("verified composition manifest is required")
        expected_catalog_scope = CatalogAcceptanceScope.from_verified_installer_context(installer_context)
        if (
            catalog_identity.scope != expected_catalog_scope
            or catalog.channel != installer_context.release.channel
            or catalog_identity.channel != catalog.channel
        ):
            raise UniversalInstallerError("catalog channel is not bound to the verified installer context")
        if catalog_identity.sequence != catalog.sequence or catalog_identity.catalog_digest != catalog.catalog_digest:
            raise UniversalInstallerError("catalog identity is not bound to the verified catalog bytes")
        if entry not in catalog.entries:
            raise UniversalInstallerError("composition entry is not a member of the verified catalog")
        if manifest.composition_id != entry.composition_id or manifest.manifest_digest != entry.manifest.digest:
            raise UniversalInstallerError("composition manifest is not bound to the verified catalog entry")
        if manifest.python_runtime.identity_digest != catalog.approved_python_runtime_identity:
            raise UniversalInstallerError(
                "composition Python runtime is not the exact identity approved by the signed catalog"
            )
        object.__setattr__(self, "installer_context", installer_context)
        object.__setattr__(self, "catalog", catalog)
        object.__setattr__(self, "catalog_identity", catalog_identity)
        object.__setattr__(self, "entry", entry)
        object.__setattr__(self, "manifest", manifest)

    @classmethod
    def establish(
        cls,
        installer_context: VerifiedInstallerContext,
        *,
        catalog_source_url: str,
        catalog_raw_bytes: bytes,
        catalog_verifier: InstallerMetadataVerifier,
        catalog_signature_policy: SignatureThresholdPolicy,
        accepted_catalog: AcceptedCatalogIdentity | None,
        composition_id: str,
        manifest_raw_bytes: bytes,
        now: datetime,
        trusted_clock: bool,
    ) -> "VerifiedCompositionSelection":
        if not isinstance(installer_context, VerifiedInstallerContext):
            raise ValueError("verified installer context is required")
        if not trusted_clock:
            raise UniversalInstallerError("trusted clock is required before composition feed selection")
        composition_id = _composition_catalog_id(composition_id, "requested composition_id")
        if _https_url(catalog_source_url, "composition catalog source URL") != installer_context.release.composition_catalog_feed.url:
            raise UniversalInstallerError("composition catalog source does not match the verified installer release")
        expected_catalog_scope = CatalogAcceptanceScope.from_verified_installer_context(installer_context)
        catalog = CompositionCatalog.from_signed_bytes(
            catalog_raw_bytes,
            catalog_verifier,
            signature_policy=catalog_signature_policy,
        )
        now = now.astimezone(timezone.utc)
        if catalog.channel != installer_context.release.channel:
            raise UniversalInstallerError("composition catalog channel does not match the verified installer channel")
        if catalog.published_at > now or catalog.expires_at <= now:
            raise UniversalInstallerError("composition catalog is not currently valid")
        if accepted_catalog is not None:
            if not isinstance(accepted_catalog, AcceptedCatalogIdentity):
                raise ValueError("accepted catalog identity is invalid")
            if accepted_catalog.scope != expected_catalog_scope:
                raise UniversalInstallerError(
                    "composition catalog anchor scope does not match the current verified installer context"
                )
            if accepted_catalog.channel != catalog.channel:
                raise UniversalInstallerError("composition catalog channel regresses accepted local provenance")
            if catalog.sequence < accepted_catalog.sequence:
                raise UniversalInstallerError("composition catalog sequence regresses accepted local provenance")
            if catalog.sequence == accepted_catalog.sequence and catalog.catalog_digest != accepted_catalog.catalog_digest:
                raise UniversalInstallerError("composition catalog sequence maps to conflicting immutable bytes")
        entry = next((candidate for candidate in catalog.entries if candidate.composition_id == composition_id), None)
        if entry is None:
            raise UniversalInstallerError("requested composition is not present in the verified catalog")
        if entry.installer_requirement.unmet_by(installer_context.capabilities):
            raise UniversalInstallerError("requested composition requires a newer installer capability")
        manifest = CompositionManifest.from_catalog_bytes(entry, manifest_raw_bytes)
        return cls(
            installer_context,
            catalog,
            AcceptedCatalogIdentity(expected_catalog_scope, catalog.sequence, catalog.catalog_digest),
            entry,
            manifest,
            _marker=_VERIFIED_COMPOSITION_SELECTION_MARKER,
        )


@dataclass(frozen=True)
class DiscoveredInstallation:
    """A product-owned inventory item, including a removal capability declaration."""

    readback: ProductInstallationReadback
    removal_support: str

    def __post_init__(self) -> None:
        if not isinstance(self.readback, ProductInstallationReadback):
            raise ValueError("discovered installation requires product readback")
        if self.removal_support not in REMOVAL_SUPPORT_STATES:
            raise ValueError("discovered installation removal support is invalid")


@dataclass(frozen=True)
class ComponentDiff:
    component: str
    installation_identity: str
    action: str
    reason: str
    target_artifact: ArtifactCorrelation | None
    readback: ProductInstallationReadback
    assessment: ProductUpdateAssessment | None

    def __post_init__(self) -> None:
        if self.component not in COMPONENT_IDENTITIES or self.action not in DIFF_ACTIONS:
            raise ValueError("component diff identity or action is invalid")
        _required(self.installation_identity, "component diff installation_identity")
        _required(self.reason, "component diff reason")
        if not isinstance(self.readback, ProductInstallationReadback):
            raise ValueError("component diff requires a product readback")
        if self.component != self.readback.component or self.installation_identity != self.readback.installation_identity:
            raise ValueError("component diff must retain the exact product readback target")
        if self.target_artifact is not None and not isinstance(self.target_artifact, ArtifactCorrelation):
            raise ValueError("component diff target artifact is invalid")
        if self.assessment is not None and (
            not isinstance(self.assessment, ProductUpdateAssessment)
            or self.assessment.component != self.component
            or self.assessment.installation_identity != self.installation_identity
            or self.assessment.candidate_artifact != self.target_artifact
        ):
            raise ValueError("component diff update assessment does not match target")


@dataclass(frozen=True)
class CompositionPlan:
    """A read-only diff.  Product operations remain separately delegated later."""

    composition_id: str
    manifest_digest: str
    installer_context: VerifiedInstallerContext
    catalog_identity: AcceptedCatalogIdentity
    installed_composition: InstalledCompositionIdentity | None
    composition_route_failures: tuple[str, ...]
    installer_unmet_requirements: tuple[str, ...]
    host_preflight: HostPreflight
    provider_gate: ProviderGate
    managed_tool_actions: tuple[ManagedToolAction, ...]
    python_runtime_action: ManagedPythonRuntimeAction
    product_venvs: tuple[ProductVenvRequirement, ...]
    component_diffs: tuple[ComponentDiff, ...]

    def __post_init__(self) -> None:
        _composition_catalog_id(self.composition_id, "composition plan composition_id")
        _digest(self.manifest_digest, "composition plan manifest_digest")
        if not isinstance(self.installer_context, VerifiedInstallerContext):
            raise ValueError("composition plan requires a verified installer context")
        if not isinstance(self.catalog_identity, AcceptedCatalogIdentity):
            raise ValueError("composition plan requires a verified catalog identity")
        if self.catalog_identity.scope != CatalogAcceptanceScope.from_verified_installer_context(
            self.installer_context
        ):
            raise ValueError("composition plan catalog identity scope does not match verified installer context")
        if self.installed_composition is not None and not isinstance(self.installed_composition, InstalledCompositionIdentity):
            raise ValueError("composition plan installed composition identity is invalid")
        if any(not isinstance(reason, str) or not reason for reason in self.composition_route_failures):
            raise ValueError("composition plan route failures are invalid")
        if not isinstance(self.host_preflight, HostPreflight) or not isinstance(self.provider_gate, ProviderGate):
            raise ValueError("composition plan gates are invalid")
        if any(not isinstance(action, ManagedToolAction) for action in self.managed_tool_actions):
            raise ValueError("composition plan managed tool actions are invalid")
        if not isinstance(self.python_runtime_action, ManagedPythonRuntimeAction):
            raise ValueError("composition plan managed Python runtime action is invalid")
        if any(not isinstance(venv, ProductVenvRequirement) for venv in self.product_venvs):
            raise ValueError("composition plan product venv requirements are invalid")
        if any(
            venv.python_runtime_identity != self.python_runtime_action.requirement.identity_digest
            for venv in self.product_venvs
        ):
            raise ValueError("composition plan product venvs do not bind its exact Python runtime")
        if len({venv.component_identity for venv in self.product_venvs}) != len(self.product_venvs):
            raise ValueError("composition plan product venv component identities must be unique")
        if len({venv.venv_identity for venv in self.product_venvs}) != len(self.product_venvs):
            raise ValueError("composition plan product venv identities must be unique")
        if any(not isinstance(diff, ComponentDiff) for diff in self.component_diffs):
            raise ValueError("composition plan component diffs are invalid")

    @property
    def non_tool_blocking_reasons(self) -> tuple[str, ...]:
        reasons: list[str] = []
        reasons.extend(self.composition_route_failures)
        reasons.extend(self.installer_unmet_requirements)
        reasons.extend(self.host_preflight.failures)
        reasons.extend(f"provider {identity} is not verified" for identity in self.provider_gate.blocking_providers)
        reasons.extend(f"component {diff.component}: {diff.reason}" for diff in self.component_diffs if diff.action == "BLOCKED")
        return tuple(reasons)

    @property
    def blocking_reasons(self) -> tuple[str, ...]:
        reasons = list(self.non_tool_blocking_reasons)
        reasons.extend(
            f"managed tool {action.identity}: {action.reason}"
            for action in self.managed_tool_actions
            if action.action != "NO_CHANGE"
        )
        if self.python_runtime_action.action != "NO_CHANGE":
            reasons.append(f"managed Python runtime: {self.python_runtime_action.reason}")
        return tuple(reasons)

    @property
    def permits_product_operation_dispatch(self) -> bool:
        return not self.blocking_reasons

    @property
    def permits_installer_operation_start(self) -> bool:
        """Whether a journal may start managed-tool work before product dispatch.

        A required managed-tool install/upgrade is a planned installer action,
        not a reason to dispatch product operations. The coordinator must
        re-read managed tools and build a fresh all-``NO_CHANGE`` plan before
        it calls any product adapter.
        """

        return (
            not self.non_tool_blocking_reasons
            and self.python_runtime_action.action != "BLOCKED"
            and all(
                action.action != "BLOCKED" for action in self.managed_tool_actions
            )
        )

    @property
    def requires_managed_tool_reconciliation(self) -> bool:
        """A fresh readback/plan is mandatory before product dispatch after tools."""

        return (
            self.python_runtime_action.action != "NO_CHANGE"
            or any(action.action != "NO_CHANGE" for action in self.managed_tool_actions)
        )

    def fingerprint(self) -> str:
        """Bind a durable future install operation to this exact read-only plan."""

        material = {
            "composition_id": self.composition_id,
            "manifest_digest": self.manifest_digest,
            "installer": {
                "version": str(self.installer_context.self_update.installed.version),
                "source_revision": self.installer_context.self_update.installed.source_revision,
                "bundle_digest": self.installer_context.self_update.installed.bundle_digest,
                "bundle_identifier": self.installer_context.self_update.installed.bundle_identifier,
                "team_identifier": self.installer_context.self_update.installed.team_identifier,
                "code_directory_sha256": self.installer_context.self_update.installed.code_directory_sha256,
                "notarization_receipt_reference": self.installer_context.self_update.installed.notarization_receipt_reference,
                "accepted_channel": self.installer_context.self_update.installed.accepted_channel,
                "accepted_sequence": self.installer_context.self_update.installed.accepted_sequence,
                "accepted_release_trust_configuration_sha256": (
                    self.installer_context.self_update.installed.accepted_release_trust_configuration_sha256
                ),
                "accepted_provenance_sha256": self.installer_context.self_update.installed.accepted_provenance_sha256,
                "capabilities": sorted(self.installer_context.capabilities.capabilities),
            },
            "installed_composition": None if self.installed_composition is None else {
                "composition_id": self.installed_composition.composition_id,
                "manifest_digest": self.installed_composition.manifest_digest,
            },
            "catalog": {
                "installer_release_trust_configuration_sha256": (
                    self.catalog_identity.installer_release_trust_configuration_sha256
                ),
                "channel": self.catalog_identity.channel,
                "feed_url": self.catalog_identity.catalog_feed_url,
                "sequence": self.catalog_identity.sequence,
                "digest": self.catalog_identity.catalog_digest,
            },
            "composition_route_failures": self.composition_route_failures,
            "tools": [(action.identity, action.action, action.requirement.artifact.digest) for action in self.managed_tool_actions],
            "python_runtime": {
                "required_identity": self.python_runtime_action.requirement.identity_digest,
                "action": self.python_runtime_action.action,
                "observed_identity": self.python_runtime_action.readback.runtime_identity,
                "rollback_identity": self.python_runtime_action.rollback_runtime_identity,
                "identity_material": self.python_runtime_action.requirement.identity_material(),
            },
            "product_venvs": [
                (venv.component_identity, venv.venv_identity, venv.python_runtime_identity)
                for venv in self.product_venvs
            ],
            "providers": [(action.identity, action.action) for action in self.provider_gate.actions],
            "components": [
                (diff.component, diff.installation_identity, diff.action, None if diff.target_artifact is None else diff.target_artifact.digest)
                for diff in self.component_diffs
            ],
        }
        return sha256(_canonical_json(material)).hexdigest()


INSTALLER_OPERATION_STATES = frozenset({
    "PLANNED", "MANAGED_TOOLS", "PRODUCT_OPERATIONS", "READINESS", "CLEANUP_PENDING", "RECOVERY_PENDING", "COMPLETE", "FAILED",
})
_INSTALLER_OPERATION_TRANSITIONS = {
    "PLANNED": frozenset({"MANAGED_TOOLS", "PRODUCT_OPERATIONS", "FAILED"}),
    "MANAGED_TOOLS": frozenset({"PRODUCT_OPERATIONS", "RECOVERY_PENDING", "FAILED"}),
    "PRODUCT_OPERATIONS": frozenset({"READINESS", "RECOVERY_PENDING", "FAILED"}),
    "READINESS": frozenset({"COMPLETE", "CLEANUP_PENDING", "RECOVERY_PENDING", "FAILED"}),
    "CLEANUP_PENDING": frozenset({"COMPLETE", "RECOVERY_PENDING", "FAILED"}),
    "RECOVERY_PENDING": frozenset({"PRODUCT_OPERATIONS", "CLEANUP_PENDING", "FAILED"}),
    "COMPLETE": frozenset(),
    "FAILED": frozenset(),
}


def _opaque_references(value: object, label: str) -> None:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{label} must be a non-empty list of opaque references")
    for reference in value:
        if not isinstance(reference, str) or not _OPAQUE_JOURNAL_REFERENCE.fullmatch(reference):
            raise ValueError(f"{label} contains an invalid opaque reference")


def _validate_journal_evidence(state: str, evidence: Mapping[str, object]) -> None:
    """Store only typed operation results and opaque receipt IDs, never raw logs."""

    if not isinstance(evidence, Mapping):
        raise ValueError("installer journal evidence must be a mapping")
    expected: dict[str, tuple[frozenset[str], str]] = {
        "PLANNED": (frozenset({"result"}), "PLAN_ACCEPTED"),
        "MANAGED_TOOLS": (frozenset({
            "result", "tool_receipt_references", "python_runtime_receipt_reference",
            "python_runtime_identity", "retained_python_runtime_identity", "post_tool_plan_fingerprint",
        }), "TOOLS_VERIFIED"),
        "PRODUCT_OPERATIONS": (frozenset({"result", "product_receipt_references"}), "PRODUCT_OPERATIONS_DISPATCHED"),
        "READINESS": (frozenset({"result", "readiness_receipt_references"}), "READINESS_VERIFIED"),
        "CLEANUP_PENDING": (frozenset({"result", "cleanup_receipt_references", "failed_target_ids"}), "CLEANUP_PENDING"),
        "RECOVERY_PENDING": (frozenset({
            "result", "recovery_receipt_references", "python_runtime_rollback_receipt_reference",
            "restored_python_runtime_identity",
        }), "RECOVERY_PENDING"),
        "COMPLETE": (frozenset({"result", "cleanup_receipt_references"}), "CLEANUP_COMPLETE"),
        "FAILED": (frozenset({"result", "failure_code", "recovery_receipt_references"}), "FAILED"),
    }
    allowed, result = expected[state]
    if set(evidence) - allowed or evidence.get("result") != result:
        raise ValueError("installer journal evidence has unsupported fields or result")
    required_keys: dict[str, frozenset[str]] = {
        "PLANNED": frozenset({"result"}),
        "MANAGED_TOOLS": frozenset({
            "result", "tool_receipt_references", "python_runtime_receipt_reference",
            "python_runtime_identity", "retained_python_runtime_identity", "post_tool_plan_fingerprint",
        }),
        "PRODUCT_OPERATIONS": frozenset({"result", "product_receipt_references"}),
        "READINESS": frozenset({"result", "readiness_receipt_references"}),
        "CLEANUP_PENDING": frozenset({"result", "cleanup_receipt_references", "failed_target_ids"}),
        "RECOVERY_PENDING": frozenset({"result", "recovery_receipt_references"}),
        "COMPLETE": frozenset({"result", "cleanup_receipt_references"}),
        "FAILED": frozenset({"result", "failure_code"}),
    }
    if not required_keys[state] <= set(evidence):
        raise ValueError("installer journal evidence omits required typed receipt references")
    for key in evidence:
        normalized = key.casefold().replace("-", "_")
        if any(fragment in normalized for fragment in _JOURNAL_FORBIDDEN_KEY_FRAGMENTS):
            raise ValueError(f"installer journal cannot retain secret-bearing key: {normalized}")
    for key in (
        "tool_receipt_references",
        "product_receipt_references",
        "readiness_receipt_references",
        "cleanup_receipt_references",
        "recovery_receipt_references",
    ):
        if key in evidence:
            _opaque_references(evidence[key], key)
    if "failed_target_ids" in evidence:
        value = evidence["failed_target_ids"]
        if not isinstance(value, list) or not value or any(not isinstance(item, str) or not _SAFE_TARGET_ID.fullmatch(item) for item in value):
            raise ValueError("failed_target_ids must be non-empty safe identifiers")
    if "failure_code" in evidence:
        value = evidence["failure_code"]
        if not isinstance(value, str) or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", value):
            raise ValueError("failure_code is invalid")
    if "post_tool_plan_fingerprint" in evidence:
        value = evidence["post_tool_plan_fingerprint"]
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise ValueError("post_tool_plan_fingerprint must be a SHA-256 hex value")
    if "python_runtime_receipt_reference" in evidence:
        reference = evidence["python_runtime_receipt_reference"]
        if not isinstance(reference, str) or not _OPAQUE_JOURNAL_REFERENCE.fullmatch(reference):
            raise ValueError("python_runtime_receipt_reference must be an opaque reference")
    if "python_runtime_identity" in evidence:
        _digest(evidence["python_runtime_identity"], "journal Python runtime identity")
        rollback = evidence["retained_python_runtime_identity"]
        if rollback is not None:
            _digest(rollback, "journal retained Python runtime identity")
    recovery_pair = {
        "python_runtime_rollback_receipt_reference",
        "restored_python_runtime_identity",
    }
    if set(evidence) & recovery_pair:
        if not recovery_pair <= set(evidence):
            raise ValueError("Python runtime recovery evidence must be complete")
        reference = evidence["python_runtime_rollback_receipt_reference"]
        if not isinstance(reference, str) or not _OPAQUE_JOURNAL_REFERENCE.fullmatch(reference):
            raise ValueError("python_runtime_rollback_receipt_reference must be an opaque reference")
        _digest(evidence["restored_python_runtime_identity"], "restored Python runtime identity")


@dataclass(frozen=True)
class InstallerJournalEvent:
    state: str
    evidence: Mapping[str, object]

    def __post_init__(self) -> None:
        if self.state not in INSTALLER_OPERATION_STATES:
            raise ValueError("installer journal event state is unsupported")
        if not isinstance(self.evidence, Mapping):
            raise ValueError("installer journal event evidence must be a mapping")
        _validate_journal_evidence(self.state, self.evidence)
        _canonical_json(dict(self.evidence))


@dataclass(frozen=True)
class InstallerOperationRecord:
    """Non-secret durable correlation for an installer operation outside CENTRAL."""

    operation_id: str
    plan_fingerprint: str
    requires_managed_tool_reconciliation: bool
    installer_version: str
    installer_source_revision: str
    installer_bundle_digest: str
    composition_id: str
    composition_manifest_digest: str
    python_runtime_identity: str
    python_runtime_rollback_identity: str | None
    product_venv_identities: tuple[tuple[str, str], ...]
    state: str
    events: tuple[InstallerJournalEvent, ...]

    @classmethod
    def create(cls, operation_id: str, plan: CompositionPlan) -> "InstallerOperationRecord":
        if not isinstance(plan, CompositionPlan):
            raise ValueError("composition plan is required for an installer operation")
        if not plan.permits_installer_operation_start:
            raise UniversalInstallerError("blocked composition plan cannot create an installer-operation journal")
        return cls(
            operation_id,
            plan.fingerprint(),
            plan.requires_managed_tool_reconciliation,
            str(plan.installer_context.self_update.installed.version),
            plan.installer_context.self_update.installed.source_revision,
            plan.installer_context.self_update.installed.bundle_digest,
            plan.composition_id,
            plan.manifest_digest,
            plan.python_runtime_action.requirement.identity_digest,
            plan.python_runtime_action.rollback_runtime_identity,
            tuple(
                (venv.component_identity, venv.venv_identity)
                for venv in plan.product_venvs
            ),
            "PLANNED",
            (InstallerJournalEvent("PLANNED", {"result": "PLAN_ACCEPTED"}),),
        )

    def __post_init__(self) -> None:
        if not _SAFE_OPERATION_ID.fullmatch(self.operation_id):
            raise ValueError("installer operation_id must be a safe relative identifier")
        if not re.fullmatch(r"[0-9a-f]{64}", self.plan_fingerprint):
            raise ValueError("installer operation plan_fingerprint must be a SHA-256 hex value")
        if not isinstance(self.requires_managed_tool_reconciliation, bool):
            raise ValueError("installer operation managed-tool reconciliation flag must be boolean")
        SemanticVersion.parse(self.installer_version, "installer journal installer_version")
        _required(self.installer_source_revision, "installer journal installer_source_revision")
        _digest(self.installer_bundle_digest, "installer journal installer_bundle_digest")
        _composition_catalog_id(self.composition_id, "installer journal composition_id")
        _digest(self.composition_manifest_digest, "installer journal composition_manifest_digest")
        _digest(self.python_runtime_identity, "installer journal Python runtime identity")
        if self.python_runtime_rollback_identity is not None:
            _digest(
                self.python_runtime_rollback_identity,
                "installer journal Python rollback runtime identity",
            )
            if self.python_runtime_rollback_identity == self.python_runtime_identity:
                raise ValueError("installer journal Python rollback identity must differ from its target")
        if (
            not self.product_venv_identities
            or any(
                not isinstance(item, tuple)
                or len(item) != 2
                or item[0] not in COMPONENT_IDENTITIES
                or not isinstance(item[1], str)
                or not _SAFE_TARGET_ID.fullmatch(item[1])
                for item in self.product_venv_identities
            )
        ):
            raise ValueError("installer journal product venv identities are invalid")
        if len({item[0] for item in self.product_venv_identities}) != len(self.product_venv_identities):
            raise ValueError("installer journal product venv component identities must be unique")
        if len({item[1] for item in self.product_venv_identities}) != len(self.product_venv_identities):
            raise ValueError("installer journal product venv identities must be unique")
        if self.state not in INSTALLER_OPERATION_STATES:
            raise ValueError("installer operation state is unsupported")
        if not self.events or any(not isinstance(event, InstallerJournalEvent) for event in self.events):
            raise ValueError("installer operation requires journal events")
        if self.events[-1].state != self.state:
            raise ValueError("installer operation state must equal its latest journal event")
        if self.events[0].state != "PLANNED":
            raise ValueError("installer operation journal must begin with PLANNED")
        for before, after in zip(self.events, self.events[1:]):
            if after.state not in _INSTALLER_OPERATION_TRANSITIONS[before.state]:
                raise ValueError("installer operation journal has an invalid state transition")
        for event in self.events:
            if event.state == "MANAGED_TOOLS":
                if event.evidence.get("python_runtime_identity") != self.python_runtime_identity:
                    raise ValueError("installer journal managed-tool event has a different Python target")
                if (
                    event.evidence.get("retained_python_runtime_identity")
                    != self.python_runtime_rollback_identity
                ):
                    raise ValueError("installer journal managed-tool event has a different Python rollback")
            if event.state == "RECOVERY_PENDING" and "restored_python_runtime_identity" in event.evidence:
                if (
                    self.python_runtime_rollback_identity is None
                    or event.evidence["restored_python_runtime_identity"]
                    != self.python_runtime_rollback_identity
                ):
                    raise ValueError("installer journal recovery event has a different Python rollback")

    def transition(self, state: str, evidence: Mapping[str, object]) -> "InstallerOperationRecord":
        if state not in _INSTALLER_OPERATION_TRANSITIONS[self.state]:
            raise UniversalInstallerError(f"installer operation transition {self.state} -> {state} is not permitted")
        if (
            self.state == "PLANNED"
            and state == "PRODUCT_OPERATIONS"
            and self.requires_managed_tool_reconciliation
        ):
            raise UniversalInstallerError(
                "managed tools require a verified reconciliation event before product operations"
            )
        event = InstallerJournalEvent(state, evidence)
        if state == "MANAGED_TOOLS":
            if evidence.get("python_runtime_identity") != self.python_runtime_identity:
                raise UniversalInstallerError(
                    "managed-tool receipt does not activate the journaled Python runtime identity"
                )
            if evidence.get("retained_python_runtime_identity") != self.python_runtime_rollback_identity:
                raise UniversalInstallerError(
                    "managed-tool receipt does not retain the journaled Python rollback identity"
                )
        if state == "RECOVERY_PENDING" and "restored_python_runtime_identity" in evidence:
            if (
                self.python_runtime_rollback_identity is None
                or evidence["restored_python_runtime_identity"] != self.python_runtime_rollback_identity
            ):
                raise UniversalInstallerError(
                    "recovery receipt does not restore the journaled Python rollback identity"
                )
        return InstallerOperationRecord(
            self.operation_id,
            self.plan_fingerprint,
            self.requires_managed_tool_reconciliation,
            self.installer_version,
            self.installer_source_revision,
            self.installer_bundle_digest,
            self.composition_id,
            self.composition_manifest_digest,
            self.python_runtime_identity,
            self.python_runtime_rollback_identity,
            self.product_venv_identities,
            state,
            self.events + (event,),
        )


_INSTALLER_RECORD_FIELDS = frozenset({
    "operation_id", "plan_fingerprint", "requires_managed_tool_reconciliation", "installer_version", "installer_source_revision", "installer_bundle_digest",
    "composition_id", "composition_manifest_digest", "python_runtime_identity",
    "python_runtime_rollback_identity", "product_venv_identities", "state", "events",
})
_INSTALLER_EVENT_FIELDS = frozenset({"state", "evidence"})


class StandaloneInstallerJournal:
    """Atomic mode-0600 journal storage, intentionally separate from product data.

    This is a local installer coordination journal, not a product lock. Every
    mutation still requires the product's own installation lock and receipt.
    """

    def __init__(self, operations_root: Path) -> None:
        if not isinstance(operations_root, Path) or not operations_root.is_absolute():
            raise ValueError("installer journal operations_root must be absolute")
        self.operations_root = operations_root.resolve(strict=False)

    def start(self, record: InstallerOperationRecord) -> InstallerOperationRecord:
        if not isinstance(record, InstallerOperationRecord):
            raise ValueError("installer journal record is invalid")
        with self._host_lock():
            with self._lock(record.operation_id):
                existing = self.load(record.operation_id)
                if existing is not None:
                    if existing != record:
                        raise UniversalInstallerError("installer operation ID already binds a different immutable plan or state")
                    return existing
                active = self._active_operation()
                if active is not None:
                    raise UniversalInstallerError(
                        f"installer host already has active operation {active.operation_id}; resume or finish it before starting another"
                    )
                self._write(record)
                return record

    def advance(self, operation_id: str, state: str, evidence: Mapping[str, object]) -> InstallerOperationRecord:
        with self._host_lock():
            with self._lock(operation_id):
                existing = self.load(operation_id)
                if existing is None:
                    raise UniversalInstallerError("installer operation journal is unavailable")
                updated = existing.transition(state, evidence)
                self._write(updated)
                return updated

    def load(self, operation_id: str) -> InstallerOperationRecord | None:
        path = self._record_path(operation_id)
        if not path.exists():
            return None
        try:
            payload = _strict_json_mapping(path.read_bytes(), "installer operation journal")
            parsed = self._parse_record(payload)
        except (OSError, ValueError, UniversalInstallerError) as error:
            raise UniversalInstallerError("installer operation journal is invalid") from error
        if parsed.operation_id != operation_id:
            raise UniversalInstallerError("installer operation journal identity does not match its path")
        return parsed

    def _record_path(self, operation_id: str) -> Path:
        if not _SAFE_OPERATION_ID.fullmatch(operation_id):
            raise ValueError("installer operation_id must be a safe relative identifier")
        return self.operations_root / f"{operation_id}.json"

    @contextmanager
    def _lock(self, operation_id: str) -> Iterator[None]:
        self._record_path(operation_id)
        self._secure_operations_root()
        lock_path = self.operations_root / f".{operation_id}.lock"
        with self._exclusive_lock(lock_path, "installer operation is already in progress"):
            yield

    @contextmanager
    def _host_lock(self) -> Iterator[None]:
        """Serialize all host-mutating installer plans across operation IDs.

        The lock is acquired for journal state changes and paired with an active
        non-terminal-record check. This survives a process crash/reboot: a later
        launcher sees the durable pending record instead of starting a second
        composition operation.
        """

        self._secure_operations_root()
        with self._exclusive_lock(
            self.operations_root / ".host-platform-mutation.lock",
            "another installer operation is coordinating this host",
        ):
            yield

    def _secure_operations_root(self) -> None:
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(self.operations_root, 0o700)
        except OSError as error:
            raise UniversalInstallerError("installer journal root permissions could not be secured") from error

    @contextmanager
    def _exclusive_lock(self, lock_path: Path, contention_message: str) -> Iterator[None]:
        descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise UniversalInstallerError(contention_message) from error
            yield
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _active_operation(self) -> InstallerOperationRecord | None:
        """Return the one recoverable host operation, failing closed on corruption."""

        active: list[InstallerOperationRecord] = []
        for path in sorted(self.operations_root.glob("*.json")):
            operation_id = path.stem
            if not _SAFE_OPERATION_ID.fullmatch(operation_id):
                raise UniversalInstallerError("installer journal contains an unsafe operation record path")
            record = self.load(operation_id)
            if record is not None and record.state not in {"COMPLETE", "FAILED"}:
                active.append(record)
        if len(active) > 1:
            raise UniversalInstallerError("installer journal contains multiple active host operations")
        return active[0] if active else None

    def _write(self, record: InstallerOperationRecord) -> None:
        self.operations_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        target = self._record_path(record.operation_id)
        descriptor, temporary_name = tempfile.mkstemp(prefix=".installer-operation-", dir=self.operations_root)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(asdict(record), handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, target)
            directory = os.open(self.operations_root, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    @staticmethod
    def _parse_record(value: Mapping[str, object]) -> InstallerOperationRecord:
        payload = _mapping(value, _INSTALLER_RECORD_FIELDS, "installer operation journal")
        events_payload = payload["events"]
        if not isinstance(events_payload, list):
            raise ValueError("installer operation journal events must be a list")
        events: list[InstallerJournalEvent] = []
        for event in events_payload:
            event_payload = _mapping(event, _INSTALLER_EVENT_FIELDS, "installer journal event")
            if not isinstance(event_payload["evidence"], Mapping):
                raise ValueError("installer journal event evidence must be a mapping")
            events.append(InstallerJournalEvent(
                _required(event_payload["state"], "installer journal event state"),
                dict(event_payload["evidence"]),
            ))
        return InstallerOperationRecord(
            _required(payload["operation_id"], "installer operation_id"),
            _required(payload["plan_fingerprint"], "installer plan_fingerprint"),
            _boolean(payload["requires_managed_tool_reconciliation"], "installer managed-tool reconciliation flag"),
            _required(payload["installer_version"], "installer journal installer_version"),
            _required(payload["installer_source_revision"], "installer journal installer_source_revision"),
            _required(payload["installer_bundle_digest"], "installer journal installer_bundle_digest"),
            _composition_catalog_id(payload["composition_id"], "installer journal composition_id"),
            _required(payload["composition_manifest_digest"], "installer journal composition_manifest_digest"),
            _required(payload["python_runtime_identity"], "installer journal Python runtime identity"),
            (
                None
                if payload["python_runtime_rollback_identity"] is None
                else _required(
                    payload["python_runtime_rollback_identity"],
                    "installer journal Python rollback runtime identity",
                )
            ),
            StandaloneInstallerJournal._parse_product_venv_identities(payload["product_venv_identities"]),
            _required(payload["state"], "installer operation state"),
            tuple(events),
        )

    @staticmethod
    def _parse_product_venv_identities(value: object) -> tuple[tuple[str, str], ...]:
        if not isinstance(value, list):
            raise ValueError("installer journal product venv identities must be a list")
        parsed: list[tuple[str, str]] = []
        for item in value:
            if not isinstance(item, list) or len(item) != 2:
                raise ValueError("installer journal product venv identity is invalid")
            parsed.append((
                _required(item[0], "installer journal product venv component"),
                _required(item[1], "installer journal product venv identity"),
            ))
        return tuple(parsed)


class CompositionPlanner:
    """Build a composition diff from product readback only; it cannot dispatch it."""

    @staticmethod
    def plan(
        selection: VerifiedCompositionSelection,
        *,
        host_facts: HostFacts,
        managed_tool_readbacks: Mapping[str, ManagedToolReadback],
        python_runtime_readback: ManagedPythonRuntimeReadback,
        provider_selections: Mapping[str, ProviderSelection],
        provider_readbacks: Mapping[str, ProviderReadback],
        selected_readbacks: Mapping[str, ProductInstallationReadback],
        update_assessments: Mapping[tuple[str, str], ProductUpdateAssessment],
        installed_composition: InstalledCompositionIdentity | None = None,
        discovered_installations: Sequence[DiscoveredInstallation] = (),
        managed_deployment_scope: bool = False,
    ) -> CompositionPlan:
        if not isinstance(selection, VerifiedCompositionSelection):
            raise ValueError("verified composition selection is required")
        manifest = selection.manifest
        installer_context = selection.installer_context
        if set(selected_readbacks) != {component.identity for component in manifest.components}:
            raise UniversalInstallerError("composition requires one product-owned readback for every selected component")
        for identity, readback in selected_readbacks.items():
            if not isinstance(readback, ProductInstallationReadback) or readback.component != identity:
                raise UniversalInstallerError("selected product readback is invalid")
        tool_actions = plan_managed_tools(manifest.managed_tools, managed_tool_readbacks)
        python_runtime_action = plan_managed_python_runtime(manifest.python_runtime, python_runtime_readback)
        provider_gate = evaluate_provider_gate(manifest.providers, provider_selections, provider_readbacks)
        component_diffs = CompositionPlanner._component_diffs(
            manifest,
            selected_readbacks,
            update_assessments,
            discovered_installations,
            managed_deployment_scope=managed_deployment_scope,
        )
        return CompositionPlan(
            manifest.composition_id,
            manifest.manifest_digest,
            installer_context,
            selection.catalog_identity,
            installed_composition,
            CompositionPlanner._composition_route_failures(
                manifest,
                selected_readbacks,
                discovered_installations,
                installed_composition,
            ),
            manifest.installer_requirement.unmet_by(installer_context.capabilities),
            preflight_host(manifest.host_requirement, host_facts),
            provider_gate,
            tool_actions,
            python_runtime_action,
            manifest.product_venvs,
            component_diffs,
        )

    @staticmethod
    def _composition_route_failures(
        manifest: CompositionManifest,
        selected_readbacks: Mapping[str, ProductInstallationReadback],
        discovered: Sequence[DiscoveredInstallation],
        installed_composition: InstalledCompositionIdentity | None,
    ) -> tuple[str, ...]:
        """Require an explicit, immutable route before mutating an existing set."""

        existing_components = any(
            readback.state != "ABSENT"
            for readback in selected_readbacks.values()
        ) or any(installation.readback.state != "ABSENT" for installation in discovered)
        if not existing_components:
            if installed_composition is None:
                return ()
            return (
                "installer composition record conflicts with an otherwise absent product inventory",
            )
        if installed_composition is None:
            return (
                "existing product installations require a durable current composition identity before an update route can be selected",
            )
        if installed_composition.composition_id == manifest.composition_id:
            if installed_composition.manifest_digest != manifest.manifest_digest:
                return (
                    "installed composition ID is bound to different immutable manifest bytes",
                )
            return ()
        if installed_composition.composition_id not in manifest.upgrade_from:
            return (
                f"composition {installed_composition.composition_id} is not an approved upgrade route to {manifest.composition_id}",
            )
        return ()

    @staticmethod
    def _component_diffs(
        manifest: CompositionManifest,
        selected_readbacks: Mapping[str, ProductInstallationReadback],
        assessments: Mapping[tuple[str, str], ProductUpdateAssessment],
        discovered: Sequence[DiscoveredInstallation],
        *,
        managed_deployment_scope: bool = False,
    ) -> tuple[ComponentDiff, ...]:
        diffs: list[ComponentDiff] = []
        selected_targets: set[tuple[str, str]] = set()
        for component in manifest.components:
            readback = selected_readbacks[component.identity]
            selected_targets.add((readback.component, readback.installation_identity))
            target = component.artifact.correlation
            diffs.append(CompositionPlanner._selected_diff(
                component,
                readback,
                assessments,
                managed_deployment_scope=managed_deployment_scope,
            ))
        seen_discovered: set[tuple[str, str]] = set()
        for installation in discovered:
            if not isinstance(installation, DiscoveredInstallation):
                raise ValueError("discovered installation is invalid")
            key = (installation.readback.component, installation.readback.installation_identity)
            if key in seen_discovered:
                raise UniversalInstallerError("product inventory contains a duplicate installation identity")
            seen_discovered.add(key)
            if key in selected_targets:
                continue
            if managed_deployment_scope:
                # Same-host product instances outside the selected managed
                # deployment are valid inventory context, not implicit removal
                # targets or blockers.
                continue
            action = "BLOCKED"
            reason = (
                "unselected product installation reports removal support, but no product-owned uninstall dispatcher is published"
                if installation.removal_support == "SUPPORTED"
                else "unselected product installation lacks a product-owned removal contract"
            )
            diffs.append(ComponentDiff(
                installation.readback.component,
                installation.readback.installation_identity,
                action,
                reason,
                None,
                installation.readback,
                None,
            ))
        return tuple(diffs)

    @staticmethod
    def _selected_diff(
        component: CompositionComponent,
        readback: ProductInstallationReadback,
        assessments: Mapping[tuple[str, str], ProductUpdateAssessment],
        *,
        managed_deployment_scope: bool = False,
    ) -> ComponentDiff:
        target = component.artifact.correlation
        if readback.conflict_state != "NONE":
            return ComponentDiff(component.identity, readback.installation_identity, "BLOCKED", "product inventory reports a conflicting or unknown installation", target, readback, None)
        if not managed_deployment_scope:
            if component.identity == "engineering-platform-server" and readback.inventory_coverage != "MACHINE_WIDE":
                return ComponentDiff(component.identity, readback.installation_identity, "BLOCKED", "EP did not prove machine-wide installation inventory", target, readback, None)
            if component.identity == "engineering-platform-server" and readback.state != "ABSENT" and not readback.single_operational_installation_verified:
                return ComponentDiff(component.identity, readback.installation_identity, "BLOCKED", "EP did not prove one healthy machine-wide operational installation", target, readback, None)
        if readback.state == "ABSENT":
            return ComponentDiff(component.identity, readback.installation_identity, "INSTALL", "selected component is absent", target, readback, None)
        if readback.state == "UNKNOWN":
            return ComponentDiff(component.identity, readback.installation_identity, "BLOCKED", "product installation inventory is unknown", target, readback, None)
        if readback.artifact == target and readback.state == "ACTIVE":
            return ComponentDiff(component.identity, readback.installation_identity, "NO_CHANGE", "exact selected artifact is healthy", target, readback, None)
        if readback.artifact == target and readback.state == "UNHEALTHY":
            return ComponentDiff(component.identity, readback.installation_identity, "REPAIR", "exact selected artifact is unhealthy", target, readback, None)
        assessment = assessments.get((component.identity, readback.installation_identity))
        if not isinstance(assessment, ProductUpdateAssessment):
            return ComponentDiff(component.identity, readback.installation_identity, "BLOCKED", "product has not supplied an exact update assessment", target, readback, None)
        if assessment.candidate_artifact != target:
            raise UniversalInstallerError("product update assessment does not bind the exact composition artifact")
        if assessment.state != "UPDATE_AVAILABLE":
            return ComponentDiff(component.identity, readback.installation_identity, "BLOCKED", f"product did not authorize the selected update: {assessment.state}", target, readback, assessment)
        return ComponentDiff(component.identity, readback.installation_identity, "UPDATE", "product authorized the exact selected update", target, readback, assessment)
