"""Admit a confirmed repair only against a fresh, sealed product review.

The request contains public identities and review evidence. It cannot supply
credential material, product commands, paths, consumer IDs or endpoints.
Admission performs no mutation; the helper must repeat currency checks at the
execution boundary.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import re
from typing import Mapping

from .managed_deployments import ManagedDeploymentRegistry
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .released_pairing_repair_review import (
    decode_repair_review_intent, prepare_repair_review,
)
from .released_pairing_repair_selection import ReleasedPairingRepairSelection
from .released_product_routes import ReleasedManagedProductRouteConfiguration
from .universal_installer import CompositionManifest


REQUEST_SCHEMA = "forge-platform.native-pairing-repair-request/v1"
PREFLIGHT_SCHEMA = "forge-platform.native-pairing-repair-preflight/v1"
MAXIMUM_REQUEST_BYTES = 12 * 1024
MAXIMUM_PREFLIGHT_BYTES = 2 * 1024
_FIELDS = frozenset({
    "schema", "review_intent", "reviewed_revision",
    "reviewed_deployment_sha256", "reviewed_plan_fingerprint",
    "confirmed", "request_fingerprint",
})
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")


class ReleasedPairingRepairAdmissionError(RuntimeError):
    """The reviewed mutation target is malformed, stale or ambiguous."""


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("utf-8")


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate repair request field")
        value[key] = item
    return value


@dataclass(frozen=True)
class AdmittedPairingRepair:
    request_fingerprint: str
    selection: ReleasedPairingRepairSelection


def decode_repair_request(raw: bytes) -> dict[str, object]:
    """Decode a bounded canonical public request with explicit confirmation."""
    try:
        if not isinstance(raw, bytes) or not 0 < len(raw) <= MAXIMUM_REQUEST_BYTES:
            raise ValueError("repair request size")
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if (not isinstance(value, dict) or frozenset(value) != _FIELDS
                or value["schema"] != REQUEST_SCHEMA or _canonical(value) != raw
                or value["confirmed"] is not True):
            raise ValueError("repair request shape")
        supplied = value["request_fingerprint"]
        unsigned = dict(value)
        del unsigned["request_fingerprint"]
        if (not isinstance(supplied, str) or not _HEX.fullmatch(supplied)
                or supplied != sha256(_canonical(unsigned)).hexdigest()):
            raise ValueError("repair request fingerprint")
        if (type(value["reviewed_revision"]) is not int
                or value["reviewed_revision"] < 1
                or not isinstance(value["reviewed_deployment_sha256"], str)
                or not _HEX.fullmatch(value["reviewed_deployment_sha256"])
                or not isinstance(value["reviewed_plan_fingerprint"], str)
                or not _DIGEST.fullmatch(value["reviewed_plan_fingerprint"])):
            raise ValueError("repair review evidence")
        if not isinstance(value["review_intent"], dict):
            raise ValueError("repair intent shape")
        decode_repair_review_intent(_canonical(value["review_intent"]))
        return value
    except (TypeError, ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleasedPairingRepairAdmissionError("repair request is invalid") from error


def admit_repair_request(
    raw: bytes, *, registry: ManagedDeploymentRegistry,
    installed_manifest: CompositionManifest,
    current_installer_release: NativeInstallerReleaseBinding,
    routes: Mapping[str, ReleasedManagedProductRouteConfiguration],
) -> AdmittedPairingRepair:
    """Recompute the exact review and sibling ownership from fresh authority."""
    try:
        request = decode_repair_request(raw)
        intent = request["review_intent"]
        if not isinstance(intent, dict):
            raise ValueError("repair intent is unavailable")
        fresh = json.loads(prepare_repair_review(
            _canonical(intent), registry=registry,
            installed_manifest=installed_manifest,
            current_installer_release=current_installer_release,
            routes=routes,
        ))
        if any(request[field] != fresh[field] for field in (
            "reviewed_revision", "reviewed_deployment_sha256",
            "reviewed_plan_fingerprint",
        )):
            raise ValueError("review changed before mutation")
        current = registry.load(intent["deployment_id"])
        route = routes.get(intent["deployment_id"])
        if current is None or not isinstance(route, ReleasedManagedProductRouteConfiguration):
            raise ValueError("repair route unavailable")
        selection = ReleasedPairingRepairSelection.derive(
            operation_id=intent["operation_id"],
            reviewed_current=current, route=route,
        )
        if selection.reviewed_plan_fingerprint != request["reviewed_plan_fingerprint"]:
            raise ValueError("repair selection changed")
        claims = {
            (item.component, item.instance_id)
            for item in current.components
        }
        if any(
            other.deployment_id != current.deployment_id
            and claims.intersection(
                (item.component, item.instance_id) for item in other.components
            )
            for other in registry.inventory()
        ):
            raise ValueError("repair instance belongs to another deployment")
        return AdmittedPairingRepair(request["request_fingerprint"], selection)
    except Exception as error:
        raise ReleasedPairingRepairAdmissionError(
            "confirmed repair authority is unavailable"
        ) from error


def encode_repair_preflight(admitted: AdmittedPairingRepair) -> bytes:
    """Report current admission only; this is never a mutation receipt."""
    if not isinstance(admitted, AdmittedPairingRepair):
        raise ReleasedPairingRepairAdmissionError("repair admission is unavailable")
    selection = admitted.selection
    return _canonical({
        "schema": PREFLIGHT_SCHEMA,
        "request_fingerprint": admitted.request_fingerprint,
        "operation_id": selection.operation_id,
        "deployment_id": selection.deployment_id,
        "reviewed_plan_fingerprint": selection.reviewed_plan_fingerprint,
        "state": "REVIEW_CURRENT_NO_MUTATION",
    })


def decode_repair_preflight(raw: bytes, *, request: Mapping[str, object]) -> dict[str, object]:
    """Reject substituted or terminal-looking worker responses."""
    try:
        if not isinstance(raw, bytes) or not 0 < len(raw) <= MAXIMUM_PREFLIGHT_BYTES:
            raise ValueError("repair preflight size")
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        intent = request["review_intent"]
        if (not isinstance(value, dict) or not isinstance(intent, dict)
                or frozenset(value) != frozenset({
                    "schema", "request_fingerprint", "operation_id", "deployment_id",
                    "reviewed_plan_fingerprint", "state",
                }) or _canonical(value) != raw
                or value["schema"] != PREFLIGHT_SCHEMA
                or value["state"] != "REVIEW_CURRENT_NO_MUTATION"
                or value["request_fingerprint"] != request["request_fingerprint"]
                or value["operation_id"] != intent["operation_id"]
                or value["deployment_id"] != intent["deployment_id"]
                or value["reviewed_plan_fingerprint"] != request["reviewed_plan_fingerprint"]):
            raise ValueError("repair preflight mismatch")
        return value
    except (KeyError, TypeError, ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleasedPairingRepairAdmissionError("repair preflight is invalid") from error
