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
from types import MappingProxyType
from typing import Iterable, Mapping, Protocol

from .managed_product_operation_admission import (
    NativeInstallerReleaseBinding,
    NativeProductOperationRequest,
    admit_native_product_operation,
    decode_native_product_operation_request,
)
from .managed_product_operation_dispatch import (
    ManagedProductOperationDispatcher,
    PinnedManagedProductRouteResolver,
    ResolvedManagedProductRoute,
)
from .managed_install_flow import ManagedForgeEPInstallationCoordinator
from .universal_installer import (
    CompositionManifest,
    VerifiedCompositionSelection,
    VerifiedInstallerContext,
)


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


class PinnedManagedProductOperationAuthorityResolver:
    """Immutable helper authority for exact already-verified manifests.

    The builder must supply typed manifests previously verified through the
    signed catalog boundary and the exact running installer release.  Native
    request values can select only an exact `(composition_id, digest)` already
    present in this snapshot; they can never introduce bytes or a locator.
    """

    def __init__(
        self,
        *,
        current_installer_release: NativeInstallerReleaseBinding,
        manifests: Iterable[CompositionManifest],
        installed_manifests: Iterable[CompositionManifest] = (),
    ) -> None:
        if not isinstance(current_installer_release, NativeInstallerReleaseBinding):
            raise TypeError("current installer release authority is required")
        values = tuple(manifests)
        if not values or any(not isinstance(value, CompositionManifest) for value in values):
            raise TypeError("verified composition manifest authorities are required")
        identities = [value.composition_id for value in values]
        digests = [value.manifest_digest for value in values]
        if len(set(identities)) != len(identities):
            raise ValueError("composition authority identities are ambiguous")
        if len(set(digests)) != len(digests):
            raise ValueError("composition authority digests are ambiguous")
        installed_values = tuple(installed_manifests)
        if any(not isinstance(value, CompositionManifest) for value in installed_values):
            raise TypeError("installed composition manifest authorities are invalid")
        all_values = tuple(dict.fromkeys(values + installed_values))
        all_identities = [value.composition_id for value in all_values]
        all_digests = [value.manifest_digest for value in all_values]
        if len(set(all_identities)) != len(all_identities):
            raise ValueError("composition authority identities are ambiguous")
        if len(set(all_digests)) != len(all_digests):
            raise ValueError("composition authority digests are ambiguous")
        self.current_installer_release = current_installer_release
        self._candidate_manifests = MappingProxyType({
            (value.composition_id, value.manifest_digest): value for value in values
        })
        self._installed_manifests = MappingProxyType({
            (value.composition_id, value.manifest_digest): value for value in all_values
        })

    def resolve(
        self, request: NativeProductOperationRequest
    ) -> ManagedProductOperationAuthorities:
        if not isinstance(request, NativeProductOperationRequest):
            raise TypeError("decoded native product request is required")
        candidate = self._candidate_manifests.get(
            (request.composition_identity, request.manifest_sha256)
        )
        if candidate is None:
            raise ManagedProductOperationServiceError(
                "candidate composition authority is unavailable"
            )
        installed: CompositionManifest | None = None
        if request.installed_composition_identity is not None:
            installed = self._installed_manifests.get((
                request.installed_composition_identity,
                request.installed_composition_manifest_sha256,
            ))
            if installed is None:
                raise ManagedProductOperationServiceError(
                    "installed composition authority is unavailable"
                )
        return ManagedProductOperationAuthorities(
            candidate,
            self.current_installer_release,
            installed,
        )


class ReleasedManagedProductOperationAuthorityLoader:
    """Load one helper snapshot only from verified released selections.

    Candidate selections must all belong to one exact current signed catalog
    under the same in-process verified installer context. Historical selections
    may authorize only an installed-manifest lookup; they never become candidate
    authority. No path, URL, bytes, request value or trust adapter enters this
    boundary.
    """

    @staticmethod
    def load(
        *,
        current_installer_context: VerifiedInstallerContext,
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
    ) -> PinnedManagedProductOperationAuthorityResolver:
        if not isinstance(current_installer_context, VerifiedInstallerContext):
            raise TypeError("verified current installer context is required")
        candidates = tuple(candidate_selections)
        installed = tuple(installed_selections)
        if not candidates or any(
            not isinstance(value, VerifiedCompositionSelection) for value in candidates
        ):
            raise TypeError("verified candidate composition selections are required")
        if any(not isinstance(value, VerifiedCompositionSelection) for value in installed):
            raise TypeError("verified installed composition selections are invalid")
        if any(
            value.installer_context is not current_installer_context
            for value in candidates + installed
        ):
            raise ValueError(
                "composition authority does not share the exact verified installer context"
            )
        current_catalog_identity = candidates[0].catalog_identity
        if any(
            value.catalog_identity != current_catalog_identity
            or value.catalog != candidates[0].catalog
            for value in candidates[1:]
        ):
            raise ValueError(
                "candidate composition authorities do not share one verified current catalog"
            )
        for value in installed:
            identity = value.catalog_identity
            if identity.scope != current_catalog_identity.scope:
                raise ValueError(
                    "installed composition authority does not share the current catalog scope"
                )
            if (
                identity.sequence > current_catalog_identity.sequence
                or (
                    identity.sequence == current_catalog_identity.sequence
                    and identity.catalog_digest != current_catalog_identity.catalog_digest
                )
            ):
                raise ValueError(
                    "installed composition authority is newer than the current catalog"
                )

        release = current_installer_context.release
        asset = release.asset_for("arm64")
        if asset is None:
            raise ValueError("verified current installer has no arm64 release asset")
        signing_key_ids = tuple(sorted(signature.key_id for signature in release.signatures))
        if not signing_key_ids:
            raise ValueError("verified current installer has no signing key identity")
        native_release = NativeInstallerReleaseBinding(
            str(release.version),
            (
                f"https://github.com/{release.github_release.repository}/releases/tag/"
                f"{release.github_release.tag}"
            ),
            asset.asset_name,
            asset.archive_digest,
            signing_key_ids[0],
        )
        return PinnedManagedProductOperationAuthorityResolver(
            current_installer_release=native_release,
            manifests=(value.manifest for value in candidates),
            installed_manifests=(value.manifest for value in installed),
        )


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


class ManagedProductOperationHelperBuilder:
    """Compose the closed helper service from already typed helper authority.

    One builder creates the release/catalog authority resolver, immutable
    product-route resolver and dispatcher around the exact supplied coordinator.
    This prevents released wiring from accidentally giving admission and
    dispatch different registries or from substituting a caller-owned resolver.
    """

    @staticmethod
    def build(
        *,
        current_installer_context: VerifiedInstallerContext,
        candidate_selections: Iterable[VerifiedCompositionSelection],
        installed_selections: Iterable[VerifiedCompositionSelection] = (),
        coordinator: ManagedForgeEPInstallationCoordinator,
        routes: Mapping[str, ResolvedManagedProductRoute],
    ) -> ManagedProductOperationHelperService:
        if not isinstance(coordinator, ManagedForgeEPInstallationCoordinator):
            raise TypeError("managed Forge+EP coordinator is required")
        authority_resolver = ReleasedManagedProductOperationAuthorityLoader.load(
            current_installer_context=current_installer_context,
            candidate_selections=candidate_selections,
            installed_selections=installed_selections,
        )
        route_resolver = PinnedManagedProductRouteResolver(routes)
        dispatcher = ManagedProductOperationDispatcher(
            coordinator=coordinator,
            resolver=route_resolver,
        )
        return ManagedProductOperationHelperService(
            authority_resolver=authority_resolver,
            dispatcher=dispatcher,
        )
