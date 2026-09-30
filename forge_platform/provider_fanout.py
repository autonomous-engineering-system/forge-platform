"""Human-authentication fan-out to isolated provider target contexts.

The coordinator deduplicates only the human authentication ceremony. It never
copies provider credential files, persists secret material, or treats one
successful login as proof that any target context is ready. Provider-specific
strategies own the supported bootstrap mechanism; each product target installs
and verifies its own runtime/config/auth state independently.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
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
    executable_digest: str | None = None

    def __post_init__(self) -> None:
        for value in (
            self.target_key, self.provider, self.ceremony_id,
            self.evidence_reference, self.executable_identity, self.version,
        ):
            if not isinstance(value, str) or not value:
                raise ValueError("provider target receipt is incomplete")
        if self.executable_digest is not None and re.fullmatch(
            r"sha256:[0-9a-f]{64}", self.executable_digest
        ) is None:
            raise ValueError("provider target receipt executable digest is invalid")


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

        # Check the complete selected topology before any human ceremony or
        # target provisioning can begin. A missing later target must not leave
        # an earlier provider partially bootstrapped.
        for provider in sorted(by_provider):
            if not callable(getattr(self.authenticators.get(provider), "authenticate", None)):
                raise ProviderFanoutError(
                    f"provider {provider} has no supported human authentication strategy"
                )
            for requirement in by_provider[provider]:
                if not callable(getattr(
                    self.targets.get(requirement.key), "provision_and_verify", None
                )):
                    raise ProviderFanoutError(
                        f"provider target {requirement.key} has no provisioner"
                    )

        receipts: list[ProviderFanoutReceipt] = []
        for provider in sorted(by_provider):
            group = tuple(sorted(by_provider[provider], key=lambda item: item.key))
            authenticator = self.authenticators[provider]
            bootstrap = authenticator.authenticate(provider, group)
            if not isinstance(bootstrap, ProviderBootstrapHandle) or bootstrap.provider != provider:
                raise ProviderFanoutError("provider authenticator returned an invalid bootstrap handle")

            target_receipts: list[ProviderTargetReceipt] = []
            for requirement in group:
                provisioner = self.targets[requirement.key]
                readback = provisioner.provision_and_verify(requirement, bootstrap)
                if not isinstance(readback, ProviderReadback) or readback.key != requirement.key:
                    raise ProviderFanoutError("provider target returned mismatched readback")
                if readback.state != "VERIFIED" or readback.version is None or readback.executable_identity is None:
                    raise ProviderFanoutError(f"provider target {requirement.key} did not independently verify")
                if (
                    requirement.minimum_version is not None
                    and readback.version < requirement.minimum_version
                ):
                    raise ProviderFanoutError(
                        f"provider target {requirement.key} is below the required version"
                    )
                if requirement.runtime is not None and (
                    readback.version != requirement.runtime.version
                    or readback.executable_digest != requirement.runtime.executable_digest
                ):
                    raise ProviderFanoutError(
                        f"provider target {requirement.key} differs from the selected runtime"
                    )
                target_receipts.append(ProviderTargetReceipt(
                    requirement.key,
                    provider,
                    bootstrap.ceremony_id,
                    readback.evidence_reference,
                    readback.executable_identity,
                    str(readback.version),
                    readback.executable_digest,
                ))
            receipts.append(ProviderFanoutReceipt(
                provider,
                bootstrap.ceremony_id,
                bootstrap.mechanism,
                tuple(target_receipts),
            ))
        return tuple(receipts)
