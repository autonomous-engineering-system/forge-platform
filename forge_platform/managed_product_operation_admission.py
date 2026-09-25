"""Fail-closed helper admission for the native Forge+EP product request.

The native installer may describe reviewed public intent, but it is not the
authority for product artifacts, managed topology, provider targets, or the
currently executing installer release.  This module strictly decodes the
canonical request and compares it with helper-owned objects before any product
adapter, path, command, environment value, or credential can be selected.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from pathlib import PurePosixPath
import re
from typing import Mapping
from urllib.parse import urlsplit

from .composition_identity import require_composition_identity
from .managed_deployments import ManagedDeployment, ManagedDeploymentRegistry
from .universal_installer import CompositionManifest


NATIVE_PRODUCT_OPERATION_REQUEST_SCHEMA = (
    "forge-platform.native-product-operation-request/v2"
)
MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES = 128 * 1_024
_COMPONENTS = frozenset({"forge-runtime", "engineering-platform-server"})
_CHANGES = frozenset({"install", "update", "repair", "retain"})
_FIELDS = frozenset({
    "schema", "stable_plan_fingerprint", "operation_id", "session_id",
    "deployment_id", "deployment_exists", "forge_instance_id",
    "engineering_platform_instance_id", "installed_composition_identity",
    "installed_composition_manifest_sha256", "inventory_evidence_reference",
    "composition_identity", "manifest_sha256", "installer_release",
    "components", "provider_target_ids", "runtime_evidence_references",
    "request_fingerprint",
})
_INSTALLER_FIELDS = frozenset({
    "version", "release_page", "asset_name", "sha256", "signing_key_id",
})
_COMPONENT_FIELDS = frozenset({
    "identity", "change", "installed_version", "candidate_version",
    "artifact_sha256",
})
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_PROVIDER_TARGET = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,383}$")
_KEY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_FINGERPRINT = re.compile(r"^[0-9a-f]{64}$")


class ManagedProductOperationAdmissionError(RuntimeError):
    """The native request is malformed, stale, substituted, or unauthorized."""


@dataclass(frozen=True)
class NativeInstallerReleaseBinding:
    version: str
    release_page: str
    asset_name: str
    sha256: str
    signing_key_id: str

    def __post_init__(self) -> None:
        _bounded_text(self.version, "installer version", maximum=128)
        parsed = urlsplit(self.release_page)
        if (
            len(self.release_page.encode("utf-8")) > 2_048
            or parsed.scheme != "https"
            or not parsed.netloc
            or parsed.username is not None
            or parsed.password is not None
            or parsed.fragment
        ):
            raise ValueError("installer release page must be a bounded HTTPS URL")
        if (
            len(self.asset_name.encode("utf-8")) > 128
            or not self.asset_name.endswith(".zip")
            or PurePosixPath(self.asset_name).name != self.asset_name
            or "\\" in self.asset_name
            or _SAFE_ID.fullmatch(self.asset_name[:-4]) is None
        ):
            raise ValueError("installer asset name is invalid")
        _digest(self.sha256, "installer archive sha256")
        if _KEY_ID.fullmatch(self.signing_key_id) is None:
            raise ValueError("installer signing key identity is invalid")


@dataclass(frozen=True)
class NativeProductComponentOperation:
    identity: str
    change: str
    installed_version: str | None
    candidate_version: str
    artifact_sha256: str

    def __post_init__(self) -> None:
        if self.identity not in _COMPONENTS or self.change not in _CHANGES:
            raise ValueError("product component operation is unsupported")
        if self.installed_version is not None:
            _bounded_text(self.installed_version, "installed version", maximum=128)
        _bounded_text(self.candidate_version, "candidate version", maximum=128)
        _digest(self.artifact_sha256, "candidate artifact sha256")
        if self.change == "install" and self.installed_version is not None:
            raise ValueError("install cannot carry an installed version")
        if self.change != "install" and self.installed_version is None:
            raise ValueError("existing-component action requires an installed version")


@dataclass(frozen=True)
class NativeProductOperationRequest:
    stable_plan_fingerprint: str
    operation_id: str
    session_id: str
    deployment_id: str
    deployment_exists: bool
    forge_instance_id: str | None
    engineering_platform_instance_id: str | None
    installed_composition_identity: str | None
    installed_composition_manifest_sha256: str | None
    inventory_evidence_reference: str
    composition_identity: str
    manifest_sha256: str
    installer_release: NativeInstallerReleaseBinding
    components: tuple[NativeProductComponentOperation, ...]
    provider_target_ids: tuple[str, ...]
    runtime_evidence_references: tuple[str, ...]
    request_fingerprint: str


@dataclass(frozen=True)
class AdmittedNativeProductOperation:
    """Public correlation proven against helper-owned authority.

    No executable adapter, filesystem locator, command, environment value, or
    credential is exposed by this result.  A later dispatcher must still
    resolve product targets and construct the durable saga from sealed helper
    configuration.
    """

    request: NativeProductOperationRequest
    manifest: CompositionManifest
    current_deployment: ManagedDeployment | None


def decode_native_product_operation_request(
    raw_bytes: bytes,
) -> NativeProductOperationRequest:
    """Decode one canonical request and independently verify its fingerprint."""

    if (
        not isinstance(raw_bytes, bytes)
        or not raw_bytes
        or len(raw_bytes) > MAXIMUM_NATIVE_PRODUCT_OPERATION_REQUEST_BYTES
    ):
        raise ManagedProductOperationAdmissionError("product request size is invalid")
    try:
        payload = json.loads(
            raw_bytes.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ManagedProductOperationAdmissionError(
            "product request is not strict JSON"
        ) from error
    if not isinstance(payload, dict) or frozenset(payload) != _FIELDS:
        raise ManagedProductOperationAdmissionError("product request shape is invalid")
    if _canonical_json(payload) != raw_bytes:
        raise ManagedProductOperationAdmissionError("product request is not canonical")
    if payload["schema"] != NATIVE_PRODUCT_OPERATION_REQUEST_SCHEMA:
        raise ManagedProductOperationAdmissionError("product request schema is unsupported")

    supplied_fingerprint = _typed_string(payload["request_fingerprint"], "request fingerprint")
    unsigned = dict(payload)
    del unsigned["request_fingerprint"]
    actual_fingerprint = sha256(_canonical_json(unsigned)).hexdigest()
    if _FINGERPRINT.fullmatch(supplied_fingerprint) is None or supplied_fingerprint != actual_fingerprint:
        raise ManagedProductOperationAdmissionError("product request fingerprint changed")

    try:
        release_payload = _exact_mapping(payload["installer_release"], _INSTALLER_FIELDS)
        release = NativeInstallerReleaseBinding(
            _typed_string(release_payload["version"], "installer version"),
            _typed_string(release_payload["release_page"], "installer release page"),
            _typed_string(release_payload["asset_name"], "installer asset name"),
            _typed_string(release_payload["sha256"], "installer sha256"),
            _typed_string(release_payload["signing_key_id"], "installer signing key id"),
        )
        components = tuple(
            _decode_component(value)
            for value in _typed_list(payload["components"], "components")
        )
        providers = _typed_strings(payload["provider_target_ids"], "provider target ids")
        evidence = _typed_strings(
            payload["runtime_evidence_references"], "runtime evidence references"
        )
        request = NativeProductOperationRequest(
            _fingerprint(payload["stable_plan_fingerprint"], "stable plan fingerprint"),
            _safe_id(payload["operation_id"], "operation id"),
            _safe_id(payload["session_id"], "session id"),
            _safe_id(payload["deployment_id"], "deployment id"),
            _typed_bool(payload["deployment_exists"], "deployment exists"),
            _optional_safe_id(payload["forge_instance_id"], "Forge instance id"),
            _optional_safe_id(
                payload["engineering_platform_instance_id"], "EP instance id"
            ),
            _optional_composition_identity(payload["installed_composition_identity"]),
            _optional_digest(
                payload["installed_composition_manifest_sha256"],
                "installed composition manifest sha256",
            ),
            _bounded_text(
                payload["inventory_evidence_reference"],
                "inventory evidence reference",
                maximum=256,
            ),
            require_composition_identity(payload["composition_identity"], "composition identity"),
            _digest(payload["manifest_sha256"], "manifest sha256"),
            release,
            components,
            providers,
            evidence,
            supplied_fingerprint,
        )
    except (TypeError, ValueError) as error:
        raise ManagedProductOperationAdmissionError(
            "product request value is invalid"
        ) from error

    if tuple(component.identity for component in components) != tuple(sorted(_COMPONENTS)):
        raise ManagedProductOperationAdmissionError("exact Forge and EP components are required")
    if providers != tuple(sorted(providers)) or len(set(providers)) != len(providers) or any(
        _PROVIDER_TARGET.fullmatch(value) is None for value in providers
    ):
        raise ManagedProductOperationAdmissionError("provider targets are invalid")
    if evidence != tuple(sorted(evidence)) or not evidence or len(set(evidence)) != len(evidence) or any(
        not _is_evidence_reference(value) for value in evidence
    ):
        raise ManagedProductOperationAdmissionError("runtime evidence is invalid")
    if (request.installed_composition_identity is None) != (
        request.installed_composition_manifest_sha256 is None
    ):
        raise ManagedProductOperationAdmissionError("installed composition binding is incomplete")
    if request.deployment_exists:
        if request.forge_instance_id is None or request.engineering_platform_instance_id is None:
            raise ManagedProductOperationAdmissionError("existing deployment topology is incomplete")
    elif any((
        request.forge_instance_id,
        request.engineering_platform_instance_id,
        request.installed_composition_identity,
        request.installed_composition_manifest_sha256,
    )):
        raise ManagedProductOperationAdmissionError("fresh deployment contains installed authority")
    return request


def admit_native_product_operation(
    request: NativeProductOperationRequest,
    *,
    manifest: CompositionManifest,
    registry: ManagedDeploymentRegistry,
    current_installer_release: NativeInstallerReleaseBinding,
    installed_manifest: CompositionManifest | None = None,
) -> AdmittedNativeProductOperation:
    """Compare native intent with the exact manifest and durable registry."""

    if not isinstance(request, NativeProductOperationRequest):
        raise TypeError("decoded native product request is required")
    if not isinstance(manifest, CompositionManifest):
        raise TypeError("verified composition manifest is required")
    if not isinstance(registry, ManagedDeploymentRegistry):
        raise TypeError("managed deployment registry is required")
    if request.installer_release != current_installer_release:
        raise ManagedProductOperationAdmissionError("installer release authority changed")
    if (
        manifest.composition_id != request.composition_identity
        or manifest.manifest_digest != request.manifest_sha256
    ):
        raise ManagedProductOperationAdmissionError("composition manifest authority changed")

    manifest_components = {component.identity: component for component in manifest.components}
    if set(manifest_components) != _COMPONENTS:
        raise ManagedProductOperationAdmissionError("manifest is not the exact Forge and EP composition")
    operations = {component.identity: component for component in request.components}
    for identity, operation in operations.items():
        artifact = manifest_components[identity].artifact
        if (
            operation.candidate_version != artifact.version
            or operation.artifact_sha256 != artifact.digest
        ):
            raise ManagedProductOperationAdmissionError("candidate artifact changed after review")

    allowed_providers = {provider.key for provider in manifest.providers}
    required_providers = {provider.key for provider in manifest.providers if provider.required}
    requested_providers = set(request.provider_target_ids)
    if not required_providers <= requested_providers or not requested_providers <= allowed_providers:
        raise ManagedProductOperationAdmissionError("provider selection changed after review")

    current = registry.load(request.deployment_id)
    if (current is not None) != request.deployment_exists:
        raise ManagedProductOperationAdmissionError("deployment existence changed after review")
    if current is None:
        if any(operation.change != "install" for operation in operations.values()):
            raise ManagedProductOperationAdmissionError("fresh deployment requires exact install actions")
        if installed_manifest is not None:
            raise ManagedProductOperationAdmissionError("fresh deployment cannot have an installed manifest")
    else:
        if set(current.by_component) != _COMPONENTS:
            raise ManagedProductOperationAdmissionError("registered topology is not exact Forge and EP")
        if (
            current.by_component["forge-runtime"].instance_id != request.forge_instance_id
            or current.by_component["engineering-platform-server"].instance_id
            != request.engineering_platform_instance_id
        ):
            raise ManagedProductOperationAdmissionError("registered product topology changed after review")
        binding = current.composition_binding
        request_binding = (
            request.installed_composition_identity,
            request.installed_composition_manifest_sha256,
        )
        actual_binding = (
            None if binding is None else binding.composition_id,
            None if binding is None else binding.manifest_digest,
        )
        if request_binding != actual_binding:
            raise ManagedProductOperationAdmissionError("installed composition changed after review")
        if any(operation.change == "install" for operation in operations.values()):
            raise ManagedProductOperationAdmissionError("existing exact topology cannot install a component")
        _admit_installed_manifest(request, manifest, installed_manifest)

    return AdmittedNativeProductOperation(request, manifest, current)


def _admit_installed_manifest(
    request: NativeProductOperationRequest,
    candidate: CompositionManifest,
    installed: CompositionManifest | None,
) -> None:
    if request.installed_composition_identity is None:
        if installed is not None:
            raise ManagedProductOperationAdmissionError("legacy topology cannot acquire invented provenance")
        return
    if not isinstance(installed, CompositionManifest):
        raise ManagedProductOperationAdmissionError("installed manifest authority is unavailable")
    if (
        installed.composition_id != request.installed_composition_identity
        or installed.manifest_digest != request.installed_composition_manifest_sha256
    ):
        raise ManagedProductOperationAdmissionError("installed manifest authority changed")
    installed_components = {component.identity: component for component in installed.components}
    if set(installed_components) != _COMPONENTS:
        raise ManagedProductOperationAdmissionError("installed manifest is not exact Forge and EP")
    for operation in request.components:
        if operation.installed_version != installed_components[operation.identity].artifact.version:
            raise ManagedProductOperationAdmissionError("installed component version changed after review")
        if operation.change in {"retain", "repair"} and (
            operation.candidate_version != operation.installed_version
        ):
            raise ManagedProductOperationAdmissionError("non-update action changed component version")
    if candidate.composition_id != installed.composition_id and (
        installed.composition_id not in candidate.upgrade_from
    ):
        raise ManagedProductOperationAdmissionError("composition upgrade route is not authorized")


def _decode_component(value: object) -> NativeProductComponentOperation:
    fields = _exact_mapping(value, _COMPONENT_FIELDS)
    installed = fields["installed_version"]
    if installed is not None and not isinstance(installed, str):
        raise ValueError("installed version must be a string or null")
    return NativeProductComponentOperation(
        _typed_string(fields["identity"], "component identity"),
        _typed_string(fields["change"], "component change"),
        installed,
        _typed_string(fields["candidate_version"], "candidate version"),
        _typed_string(fields["artifact_sha256"], "artifact sha256"),
    )


def _canonical_json(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ValueError("value is not canonical JSON") from error


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValueError(f"invalid JSON constant: {value}")


def _exact_mapping(value: object, fields: frozenset[str]) -> Mapping[str, object]:
    if not isinstance(value, dict) or frozenset(value) != fields:
        raise ValueError("JSON object shape is invalid")
    return value


def _typed_list(value: object, label: str) -> list[object]:
    if not isinstance(value, list):
        raise ValueError(f"{label} must be a list")
    return value


def _typed_strings(value: object, label: str) -> tuple[str, ...]:
    return tuple(_typed_string(item, label) for item in _typed_list(value, label))


def _typed_string(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    return value


def _typed_bool(value: object, label: str) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{label} must be boolean")
    return value


def _safe_id(value: object, label: str) -> str:
    if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
        raise ValueError(f"{label} must be a safe opaque identifier")
    return value


def _optional_safe_id(value: object, label: str) -> str | None:
    return None if value is None else _safe_id(value, label)


def _bounded_text(value: object, label: str, *, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > maximum
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{label} is invalid")
    return value


def _digest(value: object, label: str) -> str:
    if not isinstance(value, str) or _DIGEST.fullmatch(value) is None:
        raise ValueError(f"{label} must be a tagged SHA-256 digest")
    return value


def _optional_digest(value: object, label: str) -> str | None:
    return None if value is None else _digest(value, label)


def _fingerprint(value: object, label: str) -> str:
    if not isinstance(value, str) or _FINGERPRINT.fullmatch(value) is None:
        raise ValueError(f"{label} must be a SHA-256 fingerprint")
    return value


def _optional_composition_identity(value: object) -> str | None:
    if value is None:
        return None
    return require_composition_identity(value, "installed composition identity")


def _is_evidence_reference(value: str) -> bool:
    if not value or len(value.encode("utf-8")) > 256:
        return False
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return False
    lowered = value.casefold()
    return not any(fragment in lowered for fragment in (
        "authorization:", "bearer ", "password=", "secret=", "token=",
    ))
