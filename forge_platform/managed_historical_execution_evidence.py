"""Closed execution-record correlation, never execution admission by itself.

The expected binding must come from fresh native current-helper/original-owner
admission and a sole durable reservation. This decoder does not establish those
facts, load private files, mint AdmittedNativeProductOperation, or run products.
A production loader/dispatcher must separately enforce them under its lease.
"""
from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from types import MappingProxyType
from typing import Mapping
import uuid

from .managed_product_operation_admission import (
    ManagedProductOperationAdmissionError, NativeInstallerReleaseBinding, NativeProductOperationRequest,
    decode_native_product_operation_request,
)
from .universal_installer import SemanticVersion

SCHEMA = "forge-platform.historical-product-execution-permit/v1"
CONTINUATION_SCHEMA = "forge-platform.historical-product-continuation-permit/v1"
MAXIMUM_BYTES = 256 * 1024
ROLES = frozenset({"parent", "selection", "route", "authority", "operator", "git", "product_request"})
_EXECUTOR = frozenset({"version", "release_page", "asset_name", "sha256", "signing_key_id", "sequence", "source_revision", "release_trust_sha256", "code_directory_sha256", "team_identifier"})
_INSPECTION = frozenset({"schema", "state", "execution_authorized", "scope", "original_request", "original_ep_operation_id", "original_descriptor_sha256", "original_operator_identity_sha256", "protected_sha256_by_role", "current_executor", "preserve_original_journals", "preserve_historical_uncertainty"})
_FIELDS = frozenset({"schema", "state", "execution_authorized", "inspection", "inspection_sha256", "worker_id", "nonce", "original_effect_sha256", "reserved_effect_sha256", "original_forge_operation_id"})


class HistoricalExecutionEvidenceError(RuntimeError):
    pass


def _require(ok):
    if not ok:
        raise HistoricalExecutionEvidenceError("historical execution evidence conflicts")


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def _digest(value):
    _require(isinstance(value, str) and len(value) == 71 and value.startswith("sha256:")
             and all(c in "0123456789abcdef" for c in value[7:]))
    return value


def _trust_digest(value):
    """Native release/provenance trust identities use canonical bare SHA256."""
    _require(isinstance(value, str) and len(value) == 64
             and all(c in "0123456789abcdef" for c in value))
    return value


def _uuid(value):
    _require(isinstance(value, str) and len(value) == 36)
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise HistoricalExecutionEvidenceError("historical execution evidence conflicts") from error
    _require(str(parsed) == value and parsed.int != 0)
    return value


def _shape(value, fields):
    _require(isinstance(value, dict) and frozenset(value) == fields)
    return value


def _component_id(request, component):
    return "product-" + sha256((request.request_fingerprint + "\x1f" + component + "\x1fmutation").encode()).hexdigest()


@dataclass(frozen=True)
class HistoricalExecutionExpectedBinding:
    """Correlation inputs, not proof that the current native gate admitted them."""
    request: NativeProductOperationRequest
    protected_sha256_by_role: Mapping[str, str]
    descriptor_sha256: str
    operator_sha256: str
    original_trust_sha256: str
    current_executor: Mapping[str, object]
    worker_id: str
    nonce: str
    original_effect_sha256: str
    reserved_effect_sha256: str
    previous_record_sha256: str | None = None
    denial_proof_sha256: str | None = None

    def __post_init__(self):
        _require((self.previous_record_sha256 is None) == (self.denial_proof_sha256 is None))
        if self.previous_record_sha256 is not None:
            _digest(self.previous_record_sha256); _digest(self.denial_proof_sha256)
        request = self.request
        _require(isinstance(request, NativeProductOperationRequest)
                 and not request.deployment_exists
                 and request.forge_instance_id is None and request.engineering_platform_instance_id is None
                 and request.installed_composition_identity is None and request.installed_composition_manifest_sha256 is None
                 and {c.identity for c in request.components} == {"engineering-platform-server", "forge-runtime"}
                 and all(c.change == "install" and c.installed_version is None and c.update_assessment_reference is None for c in request.components))
        roles = dict(self.protected_sha256_by_role)
        _require(frozenset(roles) == ROLES)
        for value in roles.values(): _digest(value)
        for value in (self.descriptor_sha256, self.operator_sha256,
                      self.original_effect_sha256, self.reserved_effect_sha256): _digest(value)
        _require(self.original_effect_sha256 != self.reserved_effect_sha256)
        _trust_digest(self.original_trust_sha256)
        _uuid(self.worker_id); _uuid(self.nonce)
        current = dict(self.current_executor)
        _shape(current, _EXECUTOR)
        _require(type(current["sequence"]) is int and 0 < current["sequence"] <= 2**63 - 1)
        _require(isinstance(current["source_revision"], str) and len(current["source_revision"]) == 40
                 and all(c in "0123456789abcdef" for c in current["source_revision"]))
        _require(isinstance(current["team_identifier"], str) and len(current["team_identifier"]) == 10
                 and all(c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" for c in current["team_identifier"]))
        _digest(current["code_directory_sha256"]); _trust_digest(current["release_trust_sha256"])
        try:
            release = NativeInstallerReleaseBinding(*(current[k] for k in ("version", "release_page", "asset_name", "sha256", "signing_key_id")))
            old = SemanticVersion.parse(request.installer_release.version)
            new = SemanticVersion.parse(release.version)
        except (TypeError, ValueError) as error:
            raise HistoricalExecutionEvidenceError("historical execution evidence conflicts") from error
        _require((new.major, new.minor, new.patch) > (old.major, old.minor, old.patch)
                 and release.sha256 != request.installer_release.sha256
                 and release.signing_key_id == request.installer_release.signing_key_id
                 and current["release_trust_sha256"] == self.original_trust_sha256)
        object.__setattr__(self, "protected_sha256_by_role", MappingProxyType(roles))
        object.__setattr__(self, "current_executor", MappingProxyType(current))


@dataclass(frozen=True)
class HistoricalExecutionPermitEvidence:
    """Decoded correlation only: deliberately not AdmittedNativeProductOperation."""
    request: NativeProductOperationRequest
    worker_id: str
    nonce: str
    record_sha256: str


def decode_historical_execution_evidence(raw: bytes, *, expected: HistoricalExecutionExpectedBinding):
    _require(isinstance(expected, HistoricalExecutionExpectedBinding)
             and isinstance(raw, bytes) and 0 < len(raw) <= MAXIMUM_BYTES)
    def pairs(items):
        result = {}
        for key, value in items:
            _require(key not in result); result[key] = value
        return result
    def invalid(value):
        raise HistoricalExecutionEvidenceError("historical execution evidence conflicts")
    try:
        value = json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)
        _require(_canonical(value) == raw)
        continuation = expected.previous_record_sha256 is not None
        value = _shape(value, _FIELDS | ({"previous_record_sha256", "denial_proof_sha256"} if continuation else set()))
        if continuation:
            _require(value["previous_record_sha256"] == expected.previous_record_sha256
                     and value["denial_proof_sha256"] == expected.denial_proof_sha256)
        _require(value["schema"] == (CONTINUATION_SCHEMA if continuation else SCHEMA) and value["state"] == "RESERVED"
                 and value["execution_authorized"] is True)
        inspection = _shape(value["inspection"], _INSPECTION)
        _require(inspection["schema"] == "forge-platform.historical-inspection-binding/v1"
                 and inspection["state"] == "INSPECTED" and inspection["execution_authorized"] is False
                 and inspection["scope"] == "original-dual-create-and-installation-pairing"
                 and inspection["preserve_original_journals"] is True
                 and inspection["preserve_historical_uncertainty"] is True)
        actual_executor = _shape(inspection["current_executor"], _EXECUTOR)
        _require(type(actual_executor["sequence"]) is int)
        request = decode_native_product_operation_request(_canonical(inspection["original_request"]))
        _require(request == expected.request
                 and inspection["original_ep_operation_id"] == _component_id(request, "engineering-platform-server")
                 and value["original_forge_operation_id"] == _component_id(request, "forge-runtime")
                 and inspection["original_descriptor_sha256"] == expected.descriptor_sha256
                 and inspection["original_operator_identity_sha256"] == expected.operator_sha256
                 and _shape(inspection["protected_sha256_by_role"], ROLES) == dict(expected.protected_sha256_by_role)
                 and actual_executor == dict(expected.current_executor)
                 and value["inspection_sha256"] == "sha256:" + sha256(_canonical(inspection)).hexdigest()
                 and value["worker_id"] == expected.worker_id and value["nonce"] == expected.nonce
                 and value["original_effect_sha256"] == expected.original_effect_sha256
                 and value["reserved_effect_sha256"] == expected.reserved_effect_sha256)
        return HistoricalExecutionPermitEvidence(request, expected.worker_id, expected.nonce, "sha256:" + sha256(raw).hexdigest())
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError, KeyError, RecursionError, ManagedProductOperationAdmissionError) as error:
        raise HistoricalExecutionEvidenceError("historical execution evidence conflicts") from error
