"""Human-authentication fan-out to isolated provider target contexts.

The coordinator deduplicates only the human authentication ceremony. It never
copies provider credential files, persists secret material, or treats one
successful login as proof that any target context is ready. Provider-specific
strategies own the supported bootstrap mechanism; each product target installs
and verifies its own runtime/config/auth state independently.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Protocol, Sequence

from .universal_installer import ProviderReadback, ProviderRequirement


class ProviderFanoutError(RuntimeError):
    """Authentication or one exact target failed closed."""


@dataclass(frozen=True)
class ProviderBootstrapHandle:
    """Ephemeral provider-owned bootstrap capability.

    The opaque object itself is intentionally not serializable and is never
    included in terminal receipts. Strategies may wrap provider-specific
    in-memory authorization state without exposing its bytes to Forge Platform.
    """

    provider: str
    ceremony_id: str
    mechanism: str
    opaque: object

    def __post_init__(self) -> None:
        if not self.provider or not self.ceremony_id or not self.mechanism:
            raise ValueError("provider bootstrap metadata is incomplete")


@dataclass(frozen=True)
class ProviderTargetReceipt:
    target_key: str
    provider: str
    ceremony_id: str
    evidence_reference: str
    executable_identity: str
    version: str

    def __post_init__(self) -> None:
        for value in (
            self.target_key, self.provider, self.ceremony_id,
            self.evidence_reference, self.executable_identity, self.version,
        ):
            if not isinstance(value, str) or not value:
                raise ValueError("provider target receipt is incomplete")


@dataclass(frozen=True)
class ProviderFanoutReceipt:
    provider: str
    ceremony_id: str
    mechanism: str
    targets: tuple[ProviderTargetReceipt, ...]

    def __post_init__(self) -> None:
        if not self.targets:
            raise ValueError("provider fan-out receipt requires target evidence")
        if len({target.target_key for target in self.targets}) != len(self.targets):
            raise ValueError("provider fan-out receipt contains duplicate targets")
        if any(
            target.provider != self.provider or target.ceremony_id != self.ceremony_id
            for target in self.targets
        ):
            raise ValueError("provider fan-out receipt target correlation is invalid")


class ProviderHumanAuthenticator(Protocol):
    def authenticate(
        self,
        provider: str,
        requirements: Sequence[ProviderRequirement],
    ) -> ProviderBootstrapHandle:
        """Perform one provider-supported human ceremony and return an ephemeral handle."""


class ProviderTargetProvisioner(Protocol):
    def provision_and_verify(
        self,
        requirement: ProviderRequirement,
        bootstrap: ProviderBootstrapHandle,
    ) -> ProviderReadback:
        """Install/bootstrap/verify exactly one owning component context."""


class ProviderFanoutCoordinator:
    def __init__(
        self,
        *,
        authenticators: Mapping[str, ProviderHumanAuthenticator],
        targets: Mapping[str, ProviderTargetProvisioner],
    ) -> None:
        self.authenticators = dict(authenticators)
        self.targets = dict(targets)

    def execute(
        self,
        requirements: Sequence[ProviderRequirement],
    ) -> tuple[ProviderFanoutReceipt, ...]:
        if not requirements:
            return ()
        by_provider: dict[str, list[ProviderRequirement]] = {}
        observed_keys: set[str] = set()
        for requirement in requirements:
            if not isinstance(requirement, ProviderRequirement):
                raise ValueError("provider fan-out requirement is invalid")
            if requirement.owner_component is None or requirement.target_identity is None:
                raise ProviderFanoutError(
                    "provider fan-out requires an exact owning component target"
                )
            if requirement.key in observed_keys:
                raise ProviderFanoutError("provider fan-out contains a duplicate target")
            observed_keys.add(requirement.key)
            by_provider.setdefault(requirement.identity, []).append(requirement)

        receipts: list[ProviderFanoutReceipt] = []
        for provider in sorted(by_provider):
            group = tuple(sorted(by_provider[provider], key=lambda item: item.key))
            authenticator = self.authenticators.get(provider)
            if authenticator is None:
                raise ProviderFanoutError(f"provider {provider} has no supported human authentication strategy")
            bootstrap = authenticator.authenticate(provider, group)
            if not isinstance(bootstrap, ProviderBootstrapHandle) or bootstrap.provider != provider:
                raise ProviderFanoutError("provider authenticator returned an invalid bootstrap handle")

            target_receipts: list[ProviderTargetReceipt] = []
            for requirement in group:
                provisioner = self.targets.get(requirement.key)
                if provisioner is None:
                    raise ProviderFanoutError(f"provider target {requirement.key} has no provisioner")
                readback = provisioner.provision_and_verify(requirement, bootstrap)
                if not isinstance(readback, ProviderReadback) or readback.key != requirement.key:
                    raise ProviderFanoutError("provider target returned mismatched readback")
                if readback.state != "VERIFIED" or readback.version is None or readback.executable_identity is None:
                    raise ProviderFanoutError(f"provider target {requirement.key} did not independently verify")
                target_receipts.append(ProviderTargetReceipt(
                    requirement.key,
                    provider,
                    bootstrap.ceremony_id,
                    readback.evidence_reference,
                    readback.executable_identity,
                    str(readback.version),
                ))
            receipts.append(ProviderFanoutReceipt(
                provider,
                bootstrap.ceremony_id,
                bootstrap.mechanism,
                tuple(target_receipts),
            ))
        return tuple(receipts)
