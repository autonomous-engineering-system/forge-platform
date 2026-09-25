"""Closed helper service composing native request admission and product dispatch.

The XPC-facing helper supplies canonical request bytes only.  This service asks
one injected helper-owned authority resolver for the exact manifests and current
installer release, independently admits the request against the dispatcher's
same durable registry, and only then invokes the durable Forge+EP dispatcher.
No path, command, adapter, environment value, credential, or service selector is
accepted from the native caller.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .managed_product_operation_admission import (
    NativeInstallerReleaseBinding,
    NativeProductOperationRequest,
    admit_native_product_operation,
    decode_native_product_operation_request,
)
from .managed_product_operation_dispatch import (
    ManagedProductOperationDispatcher,
)
from .universal_installer import CompositionManifest


MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES = 128 * 1_024


class ManagedProductOperationServiceError(RuntimeError):
    """The helper could not authorize and complete the closed native request."""


@dataclass(frozen=True)
class ManagedProductOperationAuthorities:
    """Helper-owned authority selected for one decoded request.

    The installed manifest is absent for a fresh deployment or for a legacy
    deployment that has no durable composition provenance.  This value carries
    no adapter, executable, filesystem path, command, environment, or secret.
    """

    candidate_manifest: CompositionManifest
    current_installer_release: NativeInstallerReleaseBinding
    installed_manifest: CompositionManifest | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.candidate_manifest, CompositionManifest):
            raise TypeError("candidate composition manifest authority is required")
        if not isinstance(self.current_installer_release, NativeInstallerReleaseBinding):
            raise TypeError("current installer release authority is required")
        if self.installed_manifest is not None and not isinstance(
            self.installed_manifest, CompositionManifest
        ):
            raise TypeError("installed composition manifest authority is invalid")


class ManagedProductOperationAuthorityResolving(Protocol):
    """Resolve only helper-owned public authority for one decoded request."""

    def resolve(
        self, request: NativeProductOperationRequest
    ) -> ManagedProductOperationAuthorities: ...


class ManagedProductOperationHelperService:
    """Decode, authorize and dispatch one native product operation atomically.

    Admission and dispatch use the exact same registry object.  The dispatcher
    performs a second registry read after route resolution, closing the race
    between helper admission and the first possible product mutation.
    """

    def __init__(
        self,
        *,
        authority_resolver: ManagedProductOperationAuthorityResolving,
        dispatcher: ManagedProductOperationDispatcher,
    ) -> None:
        if not callable(getattr(authority_resolver, "resolve", None)):
            raise TypeError("helper-owned authority resolver is required")
        if not isinstance(dispatcher, ManagedProductOperationDispatcher):
            raise TypeError("managed product operation dispatcher is required")
        self.authority_resolver = authority_resolver
        self.dispatcher = dispatcher

    def execute(self, canonical_request: bytes) -> bytes:
        """Return one bounded canonical receipt or raise a generic failure."""

        try:
            request = decode_native_product_operation_request(canonical_request)
            authorities = self.authority_resolver.resolve(request)
            if not isinstance(authorities, ManagedProductOperationAuthorities):
                raise TypeError("helper authority resolver returned an invalid result")
            admitted = admit_native_product_operation(
                request,
                manifest=authorities.candidate_manifest,
                installed_manifest=authorities.installed_manifest,
                registry=self.dispatcher.coordinator.registry,
                current_installer_release=authorities.current_installer_release,
            )
            receipt = self.dispatcher.dispatch(admitted)
            response = receipt.canonical_json_bytes()
            if not response or len(response) > MAXIMUM_NATIVE_PRODUCT_OPERATION_RECEIPT_BYTES:
                raise ValueError(
                    "native product operation receipt exceeded its bound"
                )
            return response
        except Exception as error:
            raise ManagedProductOperationServiceError(
                "native product operation was rejected"
            ) from error
