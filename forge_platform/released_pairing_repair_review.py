"""Canonical, read-only repair review from a sealed released product route."""

from __future__ import annotations

from dataclasses import asdict
from hashlib import sha256
import json
import re
from typing import Mapping

from .managed_deployments import ManagedDeploymentRegistry
from .managed_product_operation_admission import NativeInstallerReleaseBinding
from .released_pairing_repair_selection import ReleasedPairingRepairSelection
from .released_product_routes import ReleasedManagedProductRouteConfiguration
from .universal_installer import CompositionManifest


INTENT_SCHEMA = "forge-platform.native-pairing-repair-review-intent/v1"
PROPOSAL_SCHEMA = "forge-platform.native-pairing-repair-review-proposal/v1"
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
_HASH = re.compile(r"[0-9a-f]{64}\Z")
_INTENT_FIELDS = frozenset({
    "schema", "operation_id", "deployment_id", "forge_instance_id",
    "engineering_platform_instance_id", "installed_composition_identity",
    "installed_manifest_sha256", "installer_release", "intent_fingerprint",
})
_RELEASE_FIELDS = frozenset(NativeInstallerReleaseBinding.__dataclass_fields__)


class ReleasedPairingRepairReviewError(RuntimeError):
    """The released repair proposal is malformed, stale or unavailable."""


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("utf-8")


def _fingerprint(value: object) -> str:
    return sha256(_canonical(value)).hexdigest()


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate repair review field")
        result[key] = value
    return result


def decode_repair_review_intent(raw: bytes) -> dict[str, object]:
    try:
        if not isinstance(raw, bytes) or not 0 < len(raw) <= 8192:
            raise ValueError("repair review intent size")
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if (not isinstance(value, dict) or frozenset(value) != _INTENT_FIELDS
                or value["schema"] != INTENT_SCHEMA or _canonical(value) != raw):
            raise ValueError("repair review intent shape")
        supplied = value["intent_fingerprint"]
        unsigned = dict(value)
        del unsigned["intent_fingerprint"]
        if not isinstance(supplied, str) or not _HASH.fullmatch(supplied) or supplied != _fingerprint(unsigned):
            raise ValueError("repair review intent fingerprint")
        for field in ("operation_id", "deployment_id", "forge_instance_id",
                      "engineering_platform_instance_id", "installed_composition_identity"):
            if not isinstance(value[field], str) or not _ID.fullmatch(value[field]):
                raise ValueError("repair review target")
        if (not isinstance(value["installed_manifest_sha256"], str)
                or not _DIGEST.fullmatch(value["installed_manifest_sha256"])):
            raise ValueError("repair review digest")
        release = value["installer_release"]
        if not isinstance(release, dict) or frozenset(release) != _RELEASE_FIELDS:
            raise ValueError("repair review release")
        NativeInstallerReleaseBinding(**release)
        return value
    except (TypeError, ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleasedPairingRepairReviewError("repair review intent is invalid") from error


def prepare_repair_review(
    canonical_intent: bytes, *, registry: ManagedDeploymentRegistry,
    installed_manifest: CompositionManifest,
    current_installer_release: NativeInstallerReleaseBinding,
    routes: Mapping[str, ReleasedManagedProductRouteConfiguration],
) -> bytes:
    """Derive public review evidence; no product, registry or credential mutation."""
    try:
        intent = decode_repair_review_intent(canonical_intent)
        if (not isinstance(registry, ManagedDeploymentRegistry)
                or not isinstance(installed_manifest, CompositionManifest)
                or not isinstance(current_installer_release, NativeInstallerReleaseBinding)
                or intent["installer_release"] != asdict(current_installer_release)
                or intent["installed_composition_identity"] != installed_manifest.composition_id
                or intent["installed_manifest_sha256"] != installed_manifest.manifest_digest):
            raise ValueError("repair review release authority")
        current = registry.load(intent["deployment_id"])
        route = routes.get(intent["deployment_id"])
        if (current is None or not isinstance(route, ReleasedManagedProductRouteConfiguration)
                or current.composition_binding is None
                or current.composition_binding.composition_id != installed_manifest.composition_id
                or current.composition_binding.manifest_digest != installed_manifest.manifest_digest
                or route.forge_target.instance_id != intent["forge_instance_id"]
                or route.engineering_platform_target.instance_id != intent["engineering_platform_instance_id"]):
            raise ValueError("repair review deployment authority")
        selection = ReleasedPairingRepairSelection.derive(
            operation_id=intent["operation_id"], reviewed_current=current, route=route,
        )
        proposal = {
            "schema": PROPOSAL_SCHEMA,
            "intent_fingerprint": intent["intent_fingerprint"],
            "operation_id": selection.operation_id,
            "deployment_id": selection.deployment_id,
            "reviewed_revision": current.revision,
            "reviewed_deployment_sha256": _fingerprint(asdict(current)),
            "reviewed_plan_fingerprint": selection.reviewed_plan_fingerprint,
            "deployment_action": selection.plan.deployment_action,
            "component_diffs": [asdict(item) for item in selection.plan.component_diffs],
            "confirmation_required": True,
        }
        raw = _canonical(proposal)
        if len(raw) > 8192:
            raise ValueError("repair proposal size")
        return raw
    except Exception as error:
        raise ReleasedPairingRepairReviewError("repair review proposal is unavailable") from error
