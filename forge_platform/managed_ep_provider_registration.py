"""Sealed EP provider registration after helper-owned physical authentication.

The native helper supplies only a non-secret, fresh physical observation bound
to its reviewed operation. This worker selects runtime and product authority
from its pinned composition and exact deployment route, then uses EP's owning
provider-register boundary. No caller path, account, or credential is accepted.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from hashlib import sha256
import json
import re

from .engineering_platform_provider_target import (
    EPProviderHumanAuthEvidenceBundle,
    EPProviderTargetAuthenticationEvidence,
    EngineeringPlatformProviderTargetProvisioner,
)
from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .provider_fanout import ProviderBootstrapHandle, ProviderFanoutCoordinator
from .universal_installer import CompositionManifest


SCHEMA = "forge-platform.ep-provider-registration/v1"
RECEIPT_SCHEMA = "forge-platform.ep-provider-registration-receipt/v1"
SELECTED_DEPLOYMENT_TARGET = "selected-deployment"
MAXIMUM_BYTES = 4 * 1024
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
_OBSERVATION = re.compile(r"receipt:provider-observation-[0-9a-f]{64}")


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def _unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate EP provider request field")
        result[key] = value
    return result


@dataclass(frozen=True)
class EPProviderRegistrationRequest:
    operation_id: str
    stable_plan_fingerprint: str
    composition_id: str
    manifest_digest: str
    deployment_id: str
    ep_instance_id: str
    provider: str
    physical_evidence_reference: str

    def __post_init__(self) -> None:
        if any(not isinstance(value, str) or _ID.fullmatch(value) is None for value in (
            self.operation_id, self.composition_id, self.deployment_id,
            self.ep_instance_id,
        )) or any(not isinstance(value, str) or _DIGEST.fullmatch(value) is None for value in (
            self.stable_plan_fingerprint, self.manifest_digest,
        )) or self.provider not in {"codex", "github-cli"} or (
            not isinstance(self.physical_evidence_reference, str)
            or _OBSERVATION.fullmatch(self.physical_evidence_reference) is None
        ):
            raise ValueError("EP provider registration identity is invalid")

    def payload(self) -> dict[str, str]:
        return {"schema": SCHEMA, **self.__dict__}

    def canonical_bytes(self) -> bytes:
        return _canonical(self.payload())

    @classmethod
    def decode(cls, raw: bytes) -> EPProviderRegistrationRequest:
        if not isinstance(raw, bytes) or not raw or len(raw) > MAXIMUM_BYTES:
            raise ValueError("EP provider request is unavailable")
        value = json.loads(raw, object_pairs_hook=_unique)
        if not isinstance(value, dict) or set(value) != {
            "schema", *cls.__dataclass_fields__
        } or value.get("schema") != SCHEMA:
            raise ValueError("EP provider request fields are invalid")
        request = cls(**{key: value[key] for key in cls.__dataclass_fields__})
        if request.canonical_bytes() != raw:
            raise ValueError("EP provider request is not canonical")
        return request


def register_ep_provider(
    request: EPProviderRegistrationRequest,
    *, manifest: CompositionManifest,
    adapter: EngineeringPlatformSystemProvisionerAdapter,
) -> bytes:
    if (
        not isinstance(request, EPProviderRegistrationRequest)
        or not isinstance(manifest, CompositionManifest)
        or not isinstance(adapter, EngineeringPlatformSystemProvisionerAdapter)
        or manifest.composition_id != request.composition_id
        or manifest.manifest_digest != request.manifest_digest
        or adapter.target.instance_id != request.ep_instance_id
    ):
        raise ValueError("EP provider released authority is unavailable")
    matching = [provider for provider in manifest.providers if (
        provider.identity == request.provider
        and provider.owner_component == "engineering-platform-server"
        and provider.target_identity in {request.deployment_id, SELECTED_DEPLOYMENT_TARGET}
        and provider.credential_scope == "component"
        and provider.required
        and provider.runtime is not None
    )]
    if len(matching) != 1:
        raise ValueError("EP provider manifest target is unavailable")
    # A signed v3 template is bound to the exact helper-reviewed deployment;
    # the pinned product route independently binds its EP instance.
    requirement = replace(matching[0], target_identity=request.ep_instance_id)
    runtime = requirement.runtime
    if runtime is None:
        raise ValueError("EP provider runtime authority is unavailable")
    correlation = sha256(request.canonical_bytes()).hexdigest()
    ceremony = "fpi-ceremony-" + correlation
    evidence = EPProviderTargetAuthenticationEvidence(
        requirement.key, request.provider, ceremony, runtime.version,
        runtime.executable_digest,
        "fpi-auth-" + correlation,
        "fpi-bootstrap-" + correlation,
    )
    bootstrap = ProviderBootstrapHandle(
        request.provider, ceremony, "helper-physical-device-auth/v1",
        EPProviderHumanAuthEvidenceBundle(request.provider, ceremony, (evidence,)),
    )

    class Authenticator:
        def authenticate(self, provider, requirements):
            if provider != request.provider or tuple(requirements) != (requirement,):
                raise ValueError("EP provider fan-out target changed")
            return bootstrap

    receipt = ProviderFanoutCoordinator(
        authenticators={request.provider: Authenticator()},
        targets={requirement.key: EngineeringPlatformProviderTargetProvisioner(adapter)},
    ).execute((requirement,))[0]
    target = receipt.targets[0]
    return _canonical({
        "schema": RECEIPT_SCHEMA,
        "operation_id": request.operation_id,
        "stable_plan_fingerprint": request.stable_plan_fingerprint,
        "deployment_id": request.deployment_id,
        "ep_instance_id": request.ep_instance_id,
        "provider": request.provider,
        "provider_target": target.target_key,
        "runtime_digest": target.executable_digest,
        "product_evidence_reference": target.evidence_reference,
        "physical_evidence_reference": request.physical_evidence_reference,
        "state": "VERIFIED",
    })
