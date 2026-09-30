"""Bind one EP provider fan-out target to the frozen product-owned register/readback.

The helper supplies a trusted, ephemeral human-auth bootstrap bundle. This
module neither performs a login nor installs CLI bytes: the executable must
already exist at EP's component-owned path, where the product verifies it.
"""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
import re

from .engineering_platform_system_adapter import EngineeringPlatformSystemProvisionerAdapter
from .provider_fanout import (
    ProviderBootstrapHandle,
    ProviderFanoutError,
    ProviderTargetProvisioner,
)
from .universal_installer import ProviderReadback, ProviderRequirement, SemanticVersion


_REFERENCE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{7,255}")
_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


@dataclass(frozen=True)
class EPProviderTargetAuthenticationEvidence:
    target_key: str
    provider: str
    ceremony_id: str
    version: SemanticVersion
    executable_digest: str
    auth_reference: str
    bootstrap_receipt: str

    def __post_init__(self) -> None:
        if (
            not isinstance(self.target_key, str)
            or _REFERENCE.fullmatch(self.target_key) is None
            or self.provider not in {"codex", "github-cli"}
            or not isinstance(self.ceremony_id, str)
            or _REFERENCE.fullmatch(self.ceremony_id) is None
            or not isinstance(self.version, SemanticVersion)
            or not isinstance(self.executable_digest, str)
            or _DIGEST.fullmatch(self.executable_digest) is None
            or any(
                not isinstance(value, str) or _REFERENCE.fullmatch(value) is None
                for value in (self.auth_reference, self.bootstrap_receipt)
            )
        ):
            raise ValueError("EP provider target authentication evidence is invalid")


@dataclass(frozen=True)
class EPProviderHumanAuthEvidenceBundle:
    provider: str
    ceremony_id: str
    targets: tuple[EPProviderTargetAuthenticationEvidence, ...]

    def __post_init__(self) -> None:
        if (
            self.provider not in {"codex", "github-cli"}
            or not isinstance(self.ceremony_id, str)
            or _REFERENCE.fullmatch(self.ceremony_id) is None
            or not self.targets
            or any(
                not isinstance(target, EPProviderTargetAuthenticationEvidence)
                or target.provider != self.provider
                or target.ceremony_id != self.ceremony_id
                for target in self.targets
            )
            or len({target.target_key for target in self.targets}) != len(self.targets)
        ):
            raise ValueError("EP provider human-auth bundle is invalid")


class EngineeringPlatformProviderTargetProvisioner(ProviderTargetProvisioner):
    """Consume one exact EP instance's product-owned provider register boundary."""

    def __init__(self, adapter: EngineeringPlatformSystemProvisionerAdapter) -> None:
        if not isinstance(adapter, EngineeringPlatformSystemProvisionerAdapter):
            raise TypeError("EP provider target requires the concrete product adapter")
        self.adapter = adapter

    def provision_and_verify(
        self,
        requirement: ProviderRequirement,
        bootstrap: ProviderBootstrapHandle,
    ) -> ProviderReadback:
        if (
            not isinstance(requirement, ProviderRequirement)
            or requirement.owner_component != "engineering-platform-server"
            or requirement.target_identity != self.adapter.target.instance_id
            or requirement.credential_scope != "component"
            or requirement.identity not in {"codex", "github-cli"}
            or requirement.runtime is None
            or not isinstance(bootstrap, ProviderBootstrapHandle)
            or bootstrap.provider != requirement.identity
            or not isinstance(bootstrap.opaque, EPProviderHumanAuthEvidenceBundle)
            or bootstrap.opaque.provider != requirement.identity
            or bootstrap.opaque.ceremony_id != bootstrap.ceremony_id
        ):
            raise ProviderFanoutError("EP provider target authority is unavailable")
        matching = tuple(
            target for target in bootstrap.opaque.targets
            if target.target_key == requirement.key
        )
        if len(matching) != 1:
            raise ProviderFanoutError("EP provider target has no exact human-auth evidence")
        evidence = matching[0]
        runtime = requirement.runtime
        if (
            evidence.version != runtime.version
            or evidence.executable_digest != runtime.executable_digest
        ):
            raise ProviderFanoutError("EP provider target runtime changed after authentication")
        product_provider = "codex" if requirement.identity == "codex" else "github"
        observed = self.adapter.register_provider(
            provider=product_provider,
            executable_digest=runtime.executable_digest,
            version=str(runtime.version),
            auth_reference=evidence.auth_reference,
            auth_bootstrap_receipt=evidence.bootstrap_receipt,
        )
        encoded = json.dumps(
            observed, sort_keys=True, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
        digest = "sha256:" + sha256(encoded).hexdigest()
        return ProviderReadback(
            requirement.identity,
            "VERIFIED",
            runtime.version,
            "ep-provider-executable:" + sha256(json.dumps({
                "instance_id": observed["instance_id"],
                "provider": observed["provider"],
                "executable": observed["executable"],
                "digest": observed["executable_sha256"],
            }, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest(),
            "ep-provider-readback:" + digest,
            requirement.owner_component,
            requirement.target_identity,
            runtime.executable_digest,
        )
